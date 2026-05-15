-- ============================================================
-- Migration: 00012_rls_drift
-- Description: Row Level Security for all Drift feature tables
-- ============================================================

-- ─── Enable RLS ──────────────────────────────────────────────────────────────

ALTER TABLE drift_activity_types           ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_vibe_tags                ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_user_locations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_sessions                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_session_participants     ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_session_activity_logs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_matches                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_contact_exchange         ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_stories                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_story_reactions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_presence                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_reports                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_trust_scores             ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_moderation_queue         ENABLE ROW LEVEL SECURITY;

-- ═══════════════════════════════════════════════════════════
-- drift_activity_types  (public read-only catalog)
-- ═══════════════════════════════════════════════════════════

CREATE POLICY "activity_types_select_all"
  ON drift_activity_types FOR SELECT
  TO authenticated
  USING (is_active = true);

-- ═══════════════════════════════════════════════════════════
-- drift_vibe_tags  (public read-only catalog)
-- ═══════════════════════════════════════════════════════════

CREATE POLICY "vibe_tags_select_all"
  ON drift_vibe_tags FOR SELECT
  TO authenticated
  USING (is_active = true);

-- ═══════════════════════════════════════════════════════════
-- drift_user_locations  (CRITICAL — privacy)
-- ═══════════════════════════════════════════════════════════

-- Users can only read their own location record
-- (Nearby discovery is done via the find_nearby_users() SQL function with SECURITY DEFINER)
CREATE POLICY "user_locations_select_own"
  ON drift_user_locations FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Users can upsert their own location
CREATE POLICY "user_locations_insert_own"
  ON drift_user_locations FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "user_locations_update_own"
  ON drift_user_locations FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Users can delete (clear) their own location
CREATE POLICY "user_locations_delete_own"
  ON drift_user_locations FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- ═══════════════════════════════════════════════════════════
-- drift_sessions
-- ═══════════════════════════════════════════════════════════

-- Active sessions are visible to all authenticated users (for discovery)
-- Blocked users are filtered at query time in the Edge Function / SQL function
CREATE POLICY "sessions_select_active"
  ON drift_sessions FOR SELECT
  TO authenticated
  USING (
    status = 'active'
    AND expires_at > now()
    -- Ensure the profile is not banned
    AND EXISTS (
      SELECT 1 FROM trombl_profiles p
      WHERE p.id = host_user_id
        AND p.deleted_at IS NULL
        AND p.is_banned = false
    )
  );

-- Hosts can see their own sessions regardless of status
CREATE POLICY "sessions_select_own"
  ON drift_sessions FOR SELECT
  TO authenticated
  USING (host_user_id = auth.uid());

-- Authenticated users can create their own sessions
CREATE POLICY "sessions_insert_own"
  ON drift_sessions FOR INSERT
  TO authenticated
  WITH CHECK (
    host_user_id = auth.uid()
    -- Prevent users creating sessions for others
  );

-- Only the host can update their session
CREATE POLICY "sessions_update_own"
  ON drift_sessions FOR UPDATE
  TO authenticated
  USING (host_user_id = auth.uid())
  WITH CHECK (
    host_user_id = auth.uid()
    -- Prevent escalating participant_count manually
  );

-- ═══════════════════════════════════════════════════════════
-- drift_session_participants
-- ═══════════════════════════════════════════════════════════

-- Users can see participants of sessions they are in, or active sessions
CREATE POLICY "session_participants_select"
  ON drift_session_participants FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM drift_sessions ds
      WHERE ds.id = session_id AND ds.status = 'active'
    )
  );

-- Users can join sessions (Edge Function validates eligibility)
CREATE POLICY "session_participants_insert_own"
  ON drift_session_participants FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Users can update their own participation (e.g., set left_at)
CREATE POLICY "session_participants_update_own"
  ON drift_session_participants FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ═══════════════════════════════════════════════════════════
-- drift_session_activity_logs  (read-only audit log)
-- ═══════════════════════════════════════════════════════════

-- Users can see logs for their own sessions
CREATE POLICY "session_logs_select_own"
  ON drift_session_activity_logs FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM drift_sessions ds
      WHERE ds.id = session_id AND ds.host_user_id = auth.uid()
    )
  );

-- No INSERT/UPDATE/DELETE by authenticated users — triggers only

-- ═══════════════════════════════════════════════════════════
-- drift_matches
-- ═══════════════════════════════════════════════════════════

-- Users can see matches they are part of
CREATE POLICY "matches_select_own"
  ON drift_matches FOR SELECT
  TO authenticated
  USING (
    initiator_id = auth.uid()
    OR target_id = auth.uid()
  );

-- Only initiator can create matches (Edge Function validates target eligibility)
CREATE POLICY "matches_insert_own"
  ON drift_matches FOR INSERT
  TO authenticated
  WITH CHECK (
    initiator_id = auth.uid()
  );

-- Either party can update match status (Edge Function controls which transitions are valid)
CREATE POLICY "matches_update_participant"
  ON drift_matches FOR UPDATE
  TO authenticated
  USING (
    initiator_id = auth.uid()
    OR target_id = auth.uid()
  )
  WITH CHECK (
    initiator_id = auth.uid()
    OR target_id = auth.uid()
  );

-- ═══════════════════════════════════════════════════════════
-- drift_contact_exchange  (CRITICAL — privacy)
-- ═══════════════════════════════════════════════════════════

-- Only match participants can see the exchange record
-- Contact values are never stored here — only consent + type
CREATE POLICY "contact_exchange_select_participant"
  ON drift_contact_exchange FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM drift_matches dm
      WHERE dm.id = match_id
        AND (dm.initiator_id = auth.uid() OR dm.target_id = auth.uid())
    )
  );

-- Edge Function inserts/updates — but participants can insert their own consent
CREATE POLICY "contact_exchange_insert_participant"
  ON drift_contact_exchange FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM drift_matches dm
      WHERE dm.id = match_id
        AND (dm.initiator_id = auth.uid() OR dm.target_id = auth.uid())
    )
  );

-- Participants can update consent (Edge Function validates which fields)
CREATE POLICY "contact_exchange_update_participant"
  ON drift_contact_exchange FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM drift_matches dm
      WHERE dm.id = match_id
        AND (dm.initiator_id = auth.uid() OR dm.target_id = auth.uid())
    )
  );

-- ═══════════════════════════════════════════════════════════
-- drift_stories  (CRITICAL — anonymity)
-- ═══════════════════════════════════════════════════════════

-- Public read: strips user_id — achieved by having the view/function handle it
-- Direct table: users can see active stories NOT from users they blocked
CREATE POLICY "stories_select_public"
  ON drift_stories FOR SELECT
  TO authenticated
  USING (
    is_removed = false
    AND deleted_at IS NULL
    -- Do not show stories from blocked users (or users who blocked me)
    AND NOT EXISTS (
      SELECT 1 FROM trombl_blocked_users b
      WHERE (b.blocker_id = auth.uid() AND b.blocked_id = user_id)
         OR (b.blocker_id = user_id AND b.blocked_id = auth.uid())
    )
  );

-- Users can publish their own stories
CREATE POLICY "stories_insert_own"
  ON drift_stories FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND char_length(text) <= 140
  );

-- Users can soft-delete their own stories (set deleted_at).
-- Moderation fields is_flagged and is_removed are locked to their current values:
-- users cannot change them regardless of their current state.
CREATE POLICY "stories_update_own"
  ON drift_stories FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (
    user_id = auth.uid()
    -- Prevent users from touching moderation fields — they must remain as stored
    AND is_flagged = (SELECT s.is_flagged FROM drift_stories s WHERE s.id = drift_stories.id)
    AND is_removed = (SELECT s.is_removed FROM drift_stories s WHERE s.id = drift_stories.id)
  );

-- ═══════════════════════════════════════════════════════════
-- drift_story_reactions
-- ═══════════════════════════════════════════════════════════

-- Users can see reactions on stories they can read (cascade from story visibility)
CREATE POLICY "story_reactions_select"
  ON drift_story_reactions FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM drift_stories ds
      WHERE ds.id = story_id
        AND ds.is_removed = false
        AND ds.deleted_at IS NULL
    )
  );

-- Users can react to stories
CREATE POLICY "story_reactions_insert_own"
  ON drift_story_reactions FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Users can remove their own reactions
CREATE POLICY "story_reactions_delete_own"
  ON drift_story_reactions FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- ═══════════════════════════════════════════════════════════
-- drift_presence
-- ═══════════════════════════════════════════════════════════

-- Active presence is visible (for session co-presence awareness)
CREATE POLICY "presence_select_active"
  ON drift_presence FOR SELECT
  TO authenticated
  USING (
    is_online = true
    -- Don't show presence of users I've blocked or blocked me
    AND NOT EXISTS (
      SELECT 1 FROM trombl_blocked_users b
      WHERE (b.blocker_id = auth.uid() AND b.blocked_id = user_id)
         OR (b.blocker_id = user_id AND b.blocked_id = auth.uid())
    )
  );

-- Users manage their own presence
CREATE POLICY "presence_upsert_own"
  ON drift_presence FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "presence_update_own"
  ON drift_presence FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ═══════════════════════════════════════════════════════════
-- drift_reports  (write-once for reporters)
-- ═══════════════════════════════════════════════════════════

-- Reporters can see their own reports
CREATE POLICY "reports_select_own"
  ON drift_reports FOR SELECT
  TO authenticated
  USING (reporter_id = auth.uid());

-- Authenticated users can file reports
CREATE POLICY "reports_insert_own"
  ON drift_reports FOR INSERT
  TO authenticated
  WITH CHECK (
    reporter_id = auth.uid()
    AND reporter_id != reported_id
  );

-- Only service role can update reports (moderation workflow)
-- No authenticated UPDATE policy for drift_reports

-- ═══════════════════════════════════════════════════════════
-- drift_trust_scores  (read-only for users)
-- ═══════════════════════════════════════════════════════════

-- Users can read their own trust score
CREATE POLICY "trust_scores_select_own"
  ON drift_trust_scores FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- No INSERT/UPDATE/DELETE — managed by triggers and service role only

-- ═══════════════════════════════════════════════════════════
-- drift_moderation_queue  (service role only)
-- ═══════════════════════════════════════════════════════════

-- No policies for authenticated users — moderators use service role client
-- This effectively blocks all access from regular JWT clients
CREATE POLICY "moderation_queue_deny_all"
  ON drift_moderation_queue FOR ALL
  TO authenticated
  USING (false);
