-- ============================================================
-- Migration: 00007_drift_matching_tables
-- Description: Drift matching system — matches and contact exchange
-- ============================================================

-- ─── drift_matches ───────────────────────────────────────────────────────────

CREATE TABLE public.drift_matches (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id      uuid REFERENCES drift_sessions(id) ON DELETE SET NULL,
  initiator_id    uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  target_id       uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  status          public.drift_match_status NOT NULL DEFAULT 'pending',

  -- Timestamps
  initiated_at    timestamptz NOT NULL DEFAULT now(),
  responded_at    timestamptz,
  accepted_at     timestamptz,
  expires_at      timestamptz NOT NULL DEFAULT (now() + interval '10 minutes'),
  ended_at        timestamptz,
  end_reason      text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT no_self_match CHECK (initiator_id != target_id),
  -- Prevent duplicate pending matches between same pair
  CONSTRAINT unique_active_match UNIQUE (initiator_id, target_id)
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────

-- Find matches for a user (both sides)
CREATE INDEX drift_matches_initiator_idx
  ON drift_matches (initiator_id, status, created_at DESC);

CREATE INDEX drift_matches_target_idx
  ON drift_matches (target_id, status, created_at DESC);

-- Expiry cleanup
CREATE INDEX drift_matches_expires_idx
  ON drift_matches (expires_at)
  WHERE status IN ('pending', 'accepted');

-- Session-level match lookup
CREATE INDEX drift_matches_session_idx
  ON drift_matches (session_id)
  WHERE session_id IS NOT NULL;

-- ─── Triggers ────────────────────────────────────────────────────────────────

CREATE TRIGGER drift_matches_updated_at
  BEFORE UPDATE ON drift_matches
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Set accepted_at when status transitions to accepted
CREATE OR REPLACE FUNCTION public.handle_match_acceptance()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'accepted' AND OLD.status = 'pending' THEN
    NEW.accepted_at  := now();
    NEW.responded_at := now();
    -- Extend expiry to 24 hours from acceptance (live session window)
    NEW.expires_at   := now() + interval '24 hours';
  ELSIF NEW.status IN ('declined', 'cancelled', 'expired', 'completed') THEN
    NEW.responded_at := COALESCE(NEW.responded_at, now());
    NEW.ended_at     := COALESCE(NEW.ended_at, now());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER drift_matches_handle_acceptance
  BEFORE UPDATE ON drift_matches
  FOR EACH ROW EXECUTE FUNCTION public.handle_match_acceptance();

-- Expire pending matches (called by scheduler)
CREATE OR REPLACE FUNCTION public.expire_pending_matches()
RETURNS int AS $$
DECLARE
  expired_count int;
BEGIN
  UPDATE drift_matches
  SET
    status     = 'expired',
    ended_at   = now(),
    end_reason = 'auto_expired',
    updated_at = now()
  WHERE
    status = 'pending'
    AND expires_at < now();
  GET DIAGNOSTICS expired_count = ROW_COUNT;
  RETURN expired_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Check if two users have an active (non-expired) match
CREATE OR REPLACE FUNCTION public.get_active_match(p_user_a uuid, p_user_b uuid)
RETURNS uuid AS $$
  SELECT id FROM drift_matches
  WHERE
    status IN ('pending', 'accepted')
    AND expires_at > now()
    AND (
      (initiator_id = p_user_a AND target_id = p_user_b)
      OR (initiator_id = p_user_b AND target_id = p_user_a)
    )
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

COMMENT ON TABLE drift_matches IS
  'Ephemeral 1:1 drift matches. Pending expires in 10 min. Accepted extends to 24h.';

-- ─── drift_contact_exchange ───────────────────────────────────────────────────

CREATE TABLE public.drift_contact_exchange (
  id                      uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  match_id                uuid NOT NULL REFERENCES drift_matches(id) ON DELETE CASCADE,

  -- Consent tracking (no contact info stored here — read from trombl_profiles at reveal time)
  initiator_consented     boolean NOT NULL DEFAULT false,
  target_consented        boolean NOT NULL DEFAULT false,
  initiator_contact_type  public.drift_contact_type,
  target_contact_type     public.drift_contact_type,

  -- Reveal window (set when both consent)
  reveal_at               timestamptz,
  expires_at              timestamptz,
  is_expired              boolean NOT NULL DEFAULT false,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unique_exchange_per_match UNIQUE (match_id)
);

CREATE INDEX drift_contact_exchange_match_idx
  ON drift_contact_exchange (match_id);

CREATE INDEX drift_contact_exchange_expires_idx
  ON drift_contact_exchange (expires_at)
  WHERE is_expired = false AND expires_at IS NOT NULL;

CREATE TRIGGER drift_contact_exchange_updated_at
  BEFORE UPDATE ON drift_contact_exchange
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Auto-set reveal_at when both consent; auto-expire after 5 minutes
CREATE OR REPLACE FUNCTION public.handle_contact_exchange_consent()
RETURNS TRIGGER AS $$
BEGIN
  -- Both parties have consented → set reveal window
  IF NEW.initiator_consented AND NEW.target_consented
     AND OLD.reveal_at IS NULL
  THEN
    NEW.reveal_at  := now();
    NEW.expires_at := now() + interval '5 minutes';
  END IF;

  -- Auto-mark expired
  IF NEW.expires_at IS NOT NULL AND NEW.expires_at < now() THEN
    NEW.is_expired := true;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER drift_contact_exchange_consent
  BEFORE UPDATE ON drift_contact_exchange
  FOR EACH ROW EXECUTE FUNCTION public.handle_contact_exchange_consent();

-- Expire contact exchange windows (called by scheduler)
CREATE OR REPLACE FUNCTION public.expire_contact_exchanges()
RETURNS int AS $$
DECLARE
  expired_count int;
BEGIN
  UPDATE drift_contact_exchange
  SET is_expired = true, updated_at = now()
  WHERE
    is_expired = false
    AND expires_at IS NOT NULL
    AND expires_at < now();
  GET DIAGNOSTICS expired_count = ROW_COUNT;
  RETURN expired_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Safely retrieve contact info for a revealed exchange (returns null if expired or not revealed)
CREATE OR REPLACE FUNCTION public.get_revealed_contact(
  p_match_id    uuid,
  p_requesting_user_id uuid
)
RETURNS TABLE (
  revealed_display_name  text,
  revealed_contact_type  public.drift_contact_type,
  revealed_contact_value text
) AS $$
DECLARE
  v_exchange drift_contact_exchange;
  v_match    drift_matches;
  v_other_user_id uuid;
  v_contact_type  public.drift_contact_type;
BEGIN
  -- Load exchange
  SELECT * INTO v_exchange FROM drift_contact_exchange WHERE match_id = p_match_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- Must be revealed and not expired
  IF v_exchange.reveal_at IS NULL OR v_exchange.is_expired THEN RETURN; END IF;
  IF v_exchange.expires_at < now() THEN
    UPDATE drift_contact_exchange SET is_expired = true WHERE id = v_exchange.id;
    RETURN;
  END IF;

  -- Load match to determine which side the requester is on
  SELECT * INTO v_match FROM drift_matches WHERE id = p_match_id;
  IF NOT FOUND THEN RETURN; END IF;

  IF v_match.initiator_id = p_requesting_user_id THEN
    -- Requester is initiator → get target's contact
    v_other_user_id := v_match.target_id;
    v_contact_type  := v_exchange.target_contact_type;
  ELSIF v_match.target_id = p_requesting_user_id THEN
    -- Requester is target → get initiator's contact
    v_other_user_id := v_match.initiator_id;
    v_contact_type  := v_exchange.initiator_contact_type;
  ELSE
    -- Not a participant
    RETURN;
  END IF;

  -- Return the other user's contact info from their profile (never stored in exchange)
  RETURN QUERY
  SELECT
    p.display_name,
    v_contact_type,
    CASE v_contact_type
      WHEN 'instagram' THEN p.instagram_handle
      WHEN 'whatsapp'  THEN p.whatsapp_number
      WHEN 'phone'     THEN p.phone_number
    END
  FROM trombl_profiles p
  WHERE p.id = v_other_user_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON TABLE drift_contact_exchange IS
  'Mutual contact consent tracking. Contact info is NEVER stored here — read from profiles at reveal time. Reveal expires 5 min.';
