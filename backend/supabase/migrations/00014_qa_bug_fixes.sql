-- ============================================================
-- Migration: 00014_qa_bug_fixes
-- Description: Critical bug fixes identified by QA static analysis
--
-- BUG-001  unique_active_match allows only ONE match ever per pair
-- BUG-002  broadcast_contact_exchange_update refs non-existent contact_type column
-- BUG-003  get_revealed_contact declared STABLE but performs a write
-- BUG-004  expire_contact_exchanges() omitted from run_scheduled_cleanup()
-- BUG-005  notifications_update_own RLS too permissive (all fields writable)
-- ============================================================

-- ─── BUG-001: Replace hard UNIQUE with partial unique index ──────────────────
-- The original UNIQUE (initiator_id, target_id) on drift_matches prevents a
-- second match between the same pair even after the first expires/declines.
-- Fix: scope uniqueness only to active (pending|accepted) states.

ALTER TABLE drift_matches DROP CONSTRAINT IF EXISTS unique_active_match;

CREATE UNIQUE INDEX drift_matches_unique_active_idx
  ON drift_matches (initiator_id, target_id)
  WHERE status IN ('pending', 'accepted');

-- ─── BUG-002: Fix broadcast_contact_exchange_update trigger ──────────────────
-- The trigger referenced NEW.contact_type which does not exist on the table.
-- The actual columns are initiator_contact_type and target_contact_type.

CREATE OR REPLACE FUNCTION public.broadcast_contact_exchange_update()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify(
    'drift:contact_exchange',
    json_build_object(
      'event',                  'exchange_updated',
      'match_id',               NEW.match_id,
      'initiator_consented',    NEW.initiator_consented,
      'target_consented',       NEW.target_consented,
      'initiator_contact_type', NEW.initiator_contact_type,
      'target_contact_type',    NEW.target_contact_type,
      'reveal_at',              NEW.reveal_at,
      'expires_at',             NEW.expires_at,
      'updated_at',             NEW.updated_at
    )::text
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─── BUG-003: Change get_revealed_contact from STABLE to VOLATILE ────────────
-- STABLE functions must not modify data. This function does an UPDATE to mark
-- is_expired = true, making it semantically VOLATILE.

CREATE OR REPLACE FUNCTION public.get_revealed_contact(
  p_match_id            uuid,
  p_requesting_user_id  uuid
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
  SELECT * INTO v_exchange FROM drift_contact_exchange WHERE match_id = p_match_id;
  IF NOT FOUND THEN RETURN; END IF;

  IF v_exchange.reveal_at IS NULL OR v_exchange.is_expired THEN RETURN; END IF;

  IF v_exchange.expires_at < now() THEN
    UPDATE drift_contact_exchange SET is_expired = true WHERE id = v_exchange.id;
    RETURN;
  END IF;

  SELECT * INTO v_match FROM drift_matches WHERE id = p_match_id;
  IF NOT FOUND THEN RETURN; END IF;

  IF v_match.initiator_id = p_requesting_user_id THEN
    v_other_user_id := v_match.target_id;
    v_contact_type  := v_exchange.target_contact_type;
  ELSIF v_match.target_id = p_requesting_user_id THEN
    v_other_user_id := v_match.initiator_id;
    v_contact_type  := v_exchange.initiator_contact_type;
  ELSE
    RETURN;
  END IF;

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
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER;

-- ─── BUG-004: Add expire_contact_exchanges() to the cleanup orchestrator ──────

CREATE OR REPLACE FUNCTION public.run_scheduled_cleanup()
RETURNS jsonb AS $$
DECLARE
  v_locations_cleaned  int;
  v_sessions_expired   int;
  v_matches_expired    int;
  v_exchanges_expired  int;
  v_stories_soft_del   int;
  v_presence_cleared   int;
BEGIN
  SELECT public.cleanup_expired_locations()  INTO v_locations_cleaned;
  SELECT public.expire_pending_matches()     INTO v_matches_expired;
  SELECT public.expire_contact_exchanges()   INTO v_exchanges_expired;
  SELECT public.cleanup_old_stories()        INTO v_stories_soft_del;
  SELECT public.cleanup_stale_presence()     INTO v_presence_cleared;

  UPDATE drift_sessions
  SET status = 'expired', updated_at = now()
  WHERE status = 'active' AND expires_at < now();
  GET DIAGNOSTICS v_sessions_expired = ROW_COUNT;

  RETURN jsonb_build_object(
    'ran_at',            now(),
    'locations_cleaned', v_locations_cleaned,
    'sessions_expired',  v_sessions_expired,
    'matches_expired',   v_matches_expired,
    'exchanges_expired', v_exchanges_expired,
    'stories_soft_del',  v_stories_soft_del,
    'presence_cleared',  v_presence_cleared
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.run_scheduled_cleanup() IS
  'Orchestrates all TTL-based cleanup jobs. Run every 5 minutes via pg_cron or Edge Function cron trigger.';

-- ─── BUG-005: Tighten notifications UPDATE RLS ───────────────────────────────
-- The original WITH CHECK only verified user_id = auth.uid(), allowing users
-- to overwrite title, body, type, and data on their own notifications.
-- Restrict to is_read and read_at only by rejecting mutations to other fields.

DROP POLICY IF EXISTS "notifications_update_own" ON trombl_notifications;

CREATE POLICY "notifications_update_own"
  ON trombl_notifications FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (
    user_id = auth.uid()
    -- Immutable fields must match current stored values
    AND type       = (SELECT n.type       FROM trombl_notifications n WHERE n.id = trombl_notifications.id)
    AND title      = (SELECT n.title      FROM trombl_notifications n WHERE n.id = trombl_notifications.id)
    AND body       = (SELECT n.body       FROM trombl_notifications n WHERE n.id = trombl_notifications.id)
    AND data       = (SELECT n.data       FROM trombl_notifications n WHERE n.id = trombl_notifications.id)
    AND created_at = (SELECT n.created_at FROM trombl_notifications n WHERE n.id = trombl_notifications.id)
  );
