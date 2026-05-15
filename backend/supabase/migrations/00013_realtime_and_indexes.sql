-- ============================================================
-- Migration: 00013_realtime_and_indexes
-- Description: Realtime publication config, broadcast triggers,
--              and composite performance indexes
-- ============================================================

-- ─── Supabase Realtime Publication ───────────────────────────────────────────
-- Supabase uses a special publication called "supabase_realtime".
-- We configure which tables and columns are replicated.

-- Enable realtime on platform tables
ALTER PUBLICATION supabase_realtime ADD TABLE trombl_notifications;

-- Enable realtime on drift feature tables
ALTER PUBLICATION supabase_realtime ADD TABLE drift_sessions;
ALTER PUBLICATION supabase_realtime ADD TABLE drift_session_participants;
ALTER PUBLICATION supabase_realtime ADD TABLE drift_matches;
ALTER PUBLICATION supabase_realtime ADD TABLE drift_contact_exchange;
ALTER PUBLICATION supabase_realtime ADD TABLE drift_stories;
ALTER PUBLICATION supabase_realtime ADD TABLE drift_story_reactions;
ALTER PUBLICATION supabase_realtime ADD TABLE drift_presence;

-- NOTE: drift_user_locations is NOT added to realtime — location updates are
-- privacy-sensitive and handled via Edge Function + explicit SECURITY DEFINER
-- queries only. Realtime broadcast for nearby users uses the broadcast channel
-- (drift:nearby) via Edge Functions, not table replication.

-- NOTE: drift_trust_scores, drift_reports, drift_moderation_queue are NOT
-- added to realtime — these are service-role-only operational tables.

-- ─── Realtime Broadcast Trigger: Notify on Match Update ──────────────────────
-- When a match changes status, we notify both participants via their
-- user-specific channels so the client can refresh.

CREATE OR REPLACE FUNCTION public.broadcast_match_update()
RETURNS TRIGGER AS $$
BEGIN
  -- Broadcast to initiator's channel
  PERFORM pg_notify(
    'drift:matches',
    json_build_object(
      'event',        'match_updated',
      'match_id',     NEW.id,
      'status',       NEW.status,
      'initiator_id', NEW.initiator_id,
      'target_id',    NEW.target_id,
      'updated_at',   NEW.updated_at
    )::text
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_matches_broadcast
  AFTER UPDATE ON drift_matches
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.broadcast_match_update();

-- ─── Realtime Broadcast Trigger: Notify on Contact Exchange Update ────────────

CREATE OR REPLACE FUNCTION public.broadcast_contact_exchange_update()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify(
    'drift:contact_exchange',
    json_build_object(
      'event',              'exchange_updated',
      'match_id',           NEW.match_id,
      'initiator_consented', NEW.initiator_consented,
      'target_consented',   NEW.target_consented,
      'contact_type',       NEW.contact_type,
      'reveal_at',          NEW.reveal_at,
      'expires_at',         NEW.expires_at,
      'updated_at',         NEW.updated_at
    )::text
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_contact_exchange_broadcast
  AFTER INSERT OR UPDATE ON drift_contact_exchange
  FOR EACH ROW
  EXECUTE FUNCTION public.broadcast_contact_exchange_update();

-- ─── Realtime Broadcast Trigger: Session Participant Count ───────────────────

CREATE OR REPLACE FUNCTION public.broadcast_session_update()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify(
    'drift:sessions',
    json_build_object(
      'event',             'session_updated',
      'session_id',        NEW.id,
      'status',            NEW.status,
      'participant_count', NEW.participant_count,
      'updated_at',        NEW.updated_at
    )::text
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_sessions_broadcast
  AFTER UPDATE ON drift_sessions
  FOR EACH ROW
  WHEN (
    OLD.status IS DISTINCT FROM NEW.status
    OR OLD.participant_count IS DISTINCT FROM NEW.participant_count
  )
  EXECUTE FUNCTION public.broadcast_session_update();

-- ─── Performance Indexes (Phase 14) ─────────────────────────────────────────
-- These augment the base indexes in earlier migrations with composite and
-- covering indexes optimized for the primary API read patterns.

-- ── trombl_profiles ──────────────────────────────────────────────────────────

-- Username lookup (case-insensitive search via pg_trgm)
CREATE INDEX IF NOT EXISTS trombl_profiles_username_trgm_idx
  ON trombl_profiles USING GIN (username gin_trgm_ops)
  WHERE deleted_at IS NULL AND is_banned = false;

-- Active profiles (discovery queries)
CREATE INDEX IF NOT EXISTS trombl_profiles_active_idx
  ON trombl_profiles (id)
  WHERE deleted_at IS NULL AND is_banned = false;

-- ── trombl_notifications ─────────────────────────────────────────────────────

-- Unread count badge queries
CREATE INDEX IF NOT EXISTS trombl_notifications_unread_idx
  ON trombl_notifications (user_id, created_at DESC)
  WHERE is_read = false AND (expires_at IS NULL OR expires_at > now());

-- ── drift_user_locations ─────────────────────────────────────────────────────

-- Active (non-expired) location lookup by user
CREATE INDEX IF NOT EXISTS drift_user_locations_active_user_idx
  ON drift_user_locations (user_id, expires_at)
  WHERE expires_at > now();

-- ── drift_sessions ────────────────────────────────────────────────────────────

-- City-based session discovery (most common read pattern for Drift)
CREATE INDEX IF NOT EXISTS drift_sessions_city_active_idx
  ON drift_sessions (city, expires_at DESC)
  WHERE status = 'active' AND expires_at > now();

-- Activity type filter on active sessions
CREATE INDEX IF NOT EXISTS drift_sessions_activity_active_idx
  ON drift_sessions (activity_type_id, expires_at DESC)
  WHERE status = 'active' AND expires_at > now();

-- Host lookup (dashboard queries)
CREATE INDEX IF NOT EXISTS drift_sessions_host_status_idx
  ON drift_sessions (host_user_id, status, created_at DESC);

-- ── drift_session_participants ────────────────────────────────────────────────

-- Active participants in a session (co-presence, count queries)
CREATE INDEX IF NOT EXISTS drift_session_participants_active_idx
  ON drift_session_participants (session_id)
  WHERE left_at IS NULL;

-- User's active session memberships
CREATE INDEX IF NOT EXISTS drift_session_participants_user_active_idx
  ON drift_session_participants (user_id, joined_at DESC)
  WHERE left_at IS NULL;

-- ── drift_matches ─────────────────────────────────────────────────────────────

-- Pending match lookup (expiry queue processing)
CREATE INDEX IF NOT EXISTS drift_matches_pending_expiry_idx
  ON drift_matches (expires_at)
  WHERE status = 'pending';

-- Active matches between two users (get_active_match function)
CREATE INDEX IF NOT EXISTS drift_matches_pair_active_idx
  ON drift_matches (initiator_id, target_id, status)
  WHERE status IN ('pending', 'accepted');

-- User's match history (notifications, history tab)
CREATE INDEX IF NOT EXISTS drift_matches_initiator_created_idx
  ON drift_matches (initiator_id, created_at DESC);

CREATE INDEX IF NOT EXISTS drift_matches_target_created_idx
  ON drift_matches (target_id, created_at DESC);

-- ── drift_contact_exchange ────────────────────────────────────────────────────

-- Reveal window cleanup (expired exchange GC)
CREATE INDEX IF NOT EXISTS drift_contact_exchange_expiry_idx
  ON drift_contact_exchange (expires_at)
  WHERE expires_at IS NOT NULL AND initiator_consented = true AND target_consented = true;

-- ── drift_stories ─────────────────────────────────────────────────────────────

-- Vibe tag filter on city feed (GIN for array containment queries)
CREATE INDEX IF NOT EXISTS drift_stories_vibe_tags_gin_idx
  ON drift_stories USING GIN (vibe_tags)
  WHERE is_removed = false AND deleted_at IS NULL;

-- Reaction count for trending sort (descending)
CREATE INDEX IF NOT EXISTS drift_stories_city_trending_idx
  ON drift_stories (city, reaction_count DESC, published_at DESC)
  WHERE is_removed = false AND deleted_at IS NULL;

-- ── drift_presence ────────────────────────────────────────────────────────────

-- Session co-presence queries
CREATE INDEX IF NOT EXISTS drift_presence_session_online_idx
  ON drift_presence (session_id, last_seen_at DESC)
  WHERE is_online = true AND session_id IS NOT NULL;

-- ── drift_reports ─────────────────────────────────────────────────────────────

-- Moderation dashboard: open reports by severity/type
CREATE INDEX IF NOT EXISTS drift_reports_open_reason_idx
  ON drift_reports (reason, created_at DESC)
  WHERE status = 'open';

-- User's received reports (trust score computation)
CREATE INDEX IF NOT EXISTS drift_reports_reported_resolved_idx
  ON drift_reports (reported_id, status, created_at DESC)
  WHERE status = 'resolved_actioned';

-- ── drift_trust_scores ────────────────────────────────────────────────────────

-- Low-trust users (eligibility filtering in match/session joins)
CREATE INDEX IF NOT EXISTS drift_trust_scores_low_score_idx
  ON drift_trust_scores (user_id, score)
  WHERE score < 50;

-- ─── Scheduled Cleanup Orchestrator ─────────────────────────────────────────
-- Single function to run all TTL-based cleanup jobs.
-- Called by Supabase pg_cron or an Edge Function cron trigger.

CREATE OR REPLACE FUNCTION public.run_scheduled_cleanup()
RETURNS jsonb AS $$
DECLARE
  v_locations_cleaned  int;
  v_sessions_expired   int;
  v_matches_expired    int;
  v_stories_soft_del   int;
  v_presence_cleared   int;
BEGIN
  SELECT public.cleanup_expired_locations()   INTO v_locations_cleaned;
  SELECT public.expire_pending_matches()      INTO v_matches_expired;
  SELECT public.cleanup_old_stories()         INTO v_stories_soft_del;
  SELECT public.cleanup_stale_presence()      INTO v_presence_cleared;

  -- Expire active drift sessions that have passed their expires_at
  UPDATE drift_sessions
  SET status = 'expired', updated_at = now()
  WHERE status = 'active' AND expires_at < now();
  GET DIAGNOSTICS v_sessions_expired = ROW_COUNT;

  RETURN jsonb_build_object(
    'ran_at',            now(),
    'locations_cleaned', v_locations_cleaned,
    'sessions_expired',  v_sessions_expired,
    'matches_expired',   v_matches_expired,
    'stories_soft_del',  v_stories_soft_del,
    'presence_cleared',  v_presence_cleared
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.run_scheduled_cleanup() IS
  'Orchestrates all TTL-based cleanup jobs. Run every 5 minutes via pg_cron or Edge Function cron trigger.';
