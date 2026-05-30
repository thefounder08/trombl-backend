-- ============================================================
-- Migration: 00011_rls_platform
-- Description: Row Level Security for all Trombl platform tables
-- ============================================================

-- ─── Enable RLS on all platform tables ───────────────────────────────────────

ALTER TABLE trombl_profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE trombl_blocked_users  ENABLE ROW LEVEL SECURITY;
ALTER TABLE trombl_push_tokens    ENABLE ROW LEVEL SECURITY;
ALTER TABLE trombl_notifications  ENABLE ROW LEVEL SECURITY;

-- ═══════════════════════════════════════════════════════════
-- trombl_profiles
-- ═══════════════════════════════════════════════════════════

-- Anyone authenticated can read non-deleted, non-banned profiles (for discovery)
-- user_id is intentionally NOT included in public reads — it flows from auth context
CREATE POLICY "profiles_select_public"
  ON trombl_profiles FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND is_banned = false
  );

-- Users can only update their own profile
CREATE POLICY "profiles_update_own"
  ON trombl_profiles FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (
    id = auth.uid()
    -- Prevent self-ban (moderation only via service role)
    AND is_banned = false
    AND ban_reason IS NULL
    AND banned_at IS NULL
  );

-- Profile is created by trigger (handle_new_user) via service role
-- No INSERT policy needed for authenticated users

-- Service role can do everything (no explicit policy needed — service role bypasses RLS)

-- ═══════════════════════════════════════════════════════════
-- trombl_blocked_users
-- ═══════════════════════════════════════════════════════════

-- Users can see their own block relationships (both directions)
CREATE POLICY "blocked_users_select_own"
  ON trombl_blocked_users FOR SELECT
  TO authenticated
  USING (
    blocker_id = auth.uid()
    OR blocked_id = auth.uid()
  );

-- Users can block others (non-system blocks only)
CREATE POLICY "blocked_users_insert_own"
  ON trombl_blocked_users FOR INSERT
  TO authenticated
  WITH CHECK (
    blocker_id = auth.uid()
    AND is_system_block = false
  );

-- Users can only delete their own non-system blocks
CREATE POLICY "blocked_users_delete_own"
  ON trombl_blocked_users FOR DELETE
  TO authenticated
  USING (
    blocker_id = auth.uid()
    AND is_system_block = false
  );

-- ═══════════════════════════════════════════════════════════
-- trombl_push_tokens
-- ═══════════════════════════════════════════════════════════

-- Users can only see their own tokens
CREATE POLICY "push_tokens_select_own"
  ON trombl_push_tokens FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Users can register tokens for themselves
CREATE POLICY "push_tokens_insert_own"
  ON trombl_push_tokens FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Users can update their own tokens (e.g., mark inactive)
CREATE POLICY "push_tokens_update_own"
  ON trombl_push_tokens FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Users can delete their own tokens
CREATE POLICY "push_tokens_delete_own"
  ON trombl_push_tokens FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- ═══════════════════════════════════════════════════════════
-- trombl_notifications
-- ═══════════════════════════════════════════════════════════

-- Users can only see their own notifications
CREATE POLICY "notifications_select_own"
  ON trombl_notifications FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    AND (expires_at IS NULL OR expires_at > now())
  );

-- No direct insert by authenticated users — only via Edge Functions / service role
-- (notifications are created by the system on behalf of events)

-- Users can mark their own notifications as read
CREATE POLICY "notifications_update_own"
  ON trombl_notifications FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (
    user_id = auth.uid()
    -- Can only update is_read and read_at (not content)
  );

-- Users can delete their own notifications
CREATE POLICY "notifications_delete_own"
  ON trombl_notifications FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());
