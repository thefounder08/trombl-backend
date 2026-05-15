-- ============================================================
-- Migration: 00006_drift_session_tables
-- Description: Drift session engine — sessions and participants
-- ============================================================

-- ─── drift_sessions ──────────────────────────────────────────────────────────

CREATE TABLE public.drift_sessions (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  host_user_id      uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  activity_type_id  uuid NOT NULL REFERENCES drift_activity_types(id),
  openness          public.drift_openness NOT NULL DEFAULT 'open',
  timeframe         public.drift_timeframe NOT NULL DEFAULT 'right_now',
  vibe_note         text CHECK (char_length(vibe_note) <= 200),
  vibe_tags         text[] NOT NULL DEFAULT '{}',
  status            public.drift_session_status NOT NULL DEFAULT 'active',
  radius_km         double precision NOT NULL DEFAULT 2.0
                    CHECK (radius_km BETWEEN 0.5 AND 10.0),

  -- Snapshot of location at session creation (for city discovery / history)
  location_snapshot geometry(Point, 4326),
  city              text,
  country_code      char(2),

  participant_count int NOT NULL DEFAULT 1 CHECK (participant_count >= 0),

  started_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz NOT NULL DEFAULT (now() + interval '2 hours'),
  ended_at          timestamptz,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────

-- Primary discovery queries: active sessions by host
CREATE INDEX drift_sessions_host_active_idx
  ON drift_sessions (host_user_id, status)
  WHERE status = 'active';

-- City-level discovery
CREATE INDEX drift_sessions_city_active_idx
  ON drift_sessions (city, started_at DESC)
  WHERE status = 'active' AND expires_at > now();

-- Expiry cleanup
CREATE INDEX drift_sessions_expires_idx
  ON drift_sessions (expires_at)
  WHERE status = 'active';

-- Activity filter
CREATE INDEX drift_sessions_activity_idx
  ON drift_sessions (activity_type_id)
  WHERE status = 'active';

-- Spatial index for session location (regional/global discovery)
CREATE INDEX drift_sessions_location_gist_idx
  ON drift_sessions USING GIST (location_snapshot)
  WHERE location_snapshot IS NOT NULL AND status = 'active';

-- ─── Triggers ────────────────────────────────────────────────────────────────

CREATE TRIGGER drift_sessions_updated_at
  BEFORE UPDATE ON drift_sessions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Log session lifecycle events
CREATE OR REPLACE FUNCTION public.log_session_event()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO drift_session_activity_logs (session_id, user_id, event_type, event_data)
    VALUES (NEW.id, NEW.host_user_id, 'session_created', jsonb_build_object(
      'activity_type_id', NEW.activity_type_id,
      'openness', NEW.openness,
      'timeframe', NEW.timeframe,
      'radius_km', NEW.radius_km
    ));
  ELSIF TG_OP = 'UPDATE' AND OLD.status != NEW.status THEN
    INSERT INTO drift_session_activity_logs (session_id, user_id, event_type, event_data)
    VALUES (NEW.id, NEW.host_user_id, 'session_status_changed', jsonb_build_object(
      'old_status', OLD.status,
      'new_status', NEW.status,
      'ended_at', NEW.ended_at
    ));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_sessions_log_events
  AFTER INSERT OR UPDATE ON drift_sessions
  FOR EACH ROW EXECUTE FUNCTION public.log_session_event();

-- Auto-expire sessions past their expiry time
CREATE OR REPLACE FUNCTION public.expire_drift_sessions()
RETURNS int AS $$
DECLARE
  expired_count int;
BEGIN
  UPDATE drift_sessions
  SET
    status   = 'expired',
    ended_at = now(),
    updated_at = now()
  WHERE
    status = 'active'
    AND expires_at < now();
  GET DIAGNOSTICS expired_count = ROW_COUNT;
  RETURN expired_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Cancel session (host only, called from Edge Function)
CREATE OR REPLACE FUNCTION public.cancel_drift_session(p_session_id uuid, p_user_id uuid)
RETURNS boolean AS $$
DECLARE
  updated_count int;
BEGIN
  UPDATE drift_sessions
  SET
    status     = 'cancelled',
    ended_at   = now(),
    updated_at = now()
  WHERE
    id = p_session_id
    AND host_user_id = p_user_id
    AND status = 'active';

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count > 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON TABLE drift_sessions IS
  'Ephemeral drift sessions. 2-hour TTL. Created when user opens a drift window.';

-- ─── drift_session_participants ───────────────────────────────────────────────

CREATE TABLE public.drift_session_participants (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id  uuid NOT NULL REFERENCES drift_sessions(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  is_host     boolean NOT NULL DEFAULT false,
  joined_at   timestamptz NOT NULL DEFAULT now(),
  left_at     timestamptz,

  CONSTRAINT unique_participant UNIQUE (session_id, user_id)
);

CREATE INDEX drift_session_participants_session_idx
  ON drift_session_participants (session_id);

CREATE INDEX drift_session_participants_user_idx
  ON drift_session_participants (user_id);

-- Maintain participant_count on sessions
CREATE OR REPLACE FUNCTION public.update_session_participant_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE drift_sessions
    SET participant_count = participant_count + 1
    WHERE id = NEW.session_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.left_at IS NULL AND NEW.left_at IS NOT NULL THEN
    UPDATE drift_sessions
    SET participant_count = GREATEST(0, participant_count - 1)
    WHERE id = NEW.session_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_session_participants_count
  AFTER INSERT OR UPDATE ON drift_session_participants
  FOR EACH ROW EXECUTE FUNCTION public.update_session_participant_count();

COMMENT ON TABLE drift_session_participants IS
  'Users participating in a drift session. Tracks host and joiners.';

-- ─── drift_session_activity_logs ─────────────────────────────────────────────

CREATE TABLE public.drift_session_activity_logs (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id  uuid NOT NULL REFERENCES drift_sessions(id) ON DELETE CASCADE,
  user_id     uuid REFERENCES trombl_profiles(id) ON DELETE SET NULL,
  event_type  text NOT NULL,
  event_data  jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX drift_session_activity_logs_session_idx
  ON drift_session_activity_logs (session_id, created_at DESC);

COMMENT ON TABLE drift_session_activity_logs IS
  'Immutable audit log for drift session lifecycle events. Never deleted.';
