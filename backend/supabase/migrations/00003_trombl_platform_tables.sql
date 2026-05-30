-- ============================================================
-- Migration: 00003_trombl_platform_tables
-- Description: Core Trombl platform tables (cross-feature)
-- ============================================================

-- ─── trombl_profiles ─────────────────────────────────────────────────────────
-- Central user profile table. Extended by all feature modules.
-- References auth.users for identity.

CREATE TABLE public.trombl_profiles (
  id                        uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username                  text UNIQUE,
  display_name              text,
  avatar_url                text,
  bio                       text CHECK (char_length(bio) <= 300),
  instagram_handle          text,
  whatsapp_number           text,
  phone_number              text,

  -- Drift-specific profile fields (owned by drift module but stored on profile for denormalization)
  drift_vibe_tags           text[] DEFAULT '{}',
  drift_openness            public.drift_openness DEFAULT 'open',

  -- Privacy & Permissions
  location_sharing_enabled  boolean NOT NULL DEFAULT true,
  notifications_enabled     boolean NOT NULL DEFAULT true,

  -- Moderation
  is_banned                 boolean NOT NULL DEFAULT false,
  banned_at                 timestamptz,
  ban_reason                text,

  -- Audit
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,

  CONSTRAINT username_format CHECK (
    username IS NULL OR (
      char_length(username) BETWEEN 3 AND 30
      AND username ~ '^[a-z0-9_\.]+$'
    )
  )
);

-- Index for username lookup
CREATE UNIQUE INDEX trombl_profiles_username_lower_idx
  ON trombl_profiles (lower(username))
  WHERE username IS NOT NULL AND deleted_at IS NULL;

-- Index for soft-delete filtering
CREATE INDEX trombl_profiles_active_idx
  ON trombl_profiles (id)
  WHERE deleted_at IS NULL AND is_banned = false;

-- Auto-update updated_at
CREATE TRIGGER trombl_profiles_updated_at
  BEFORE UPDATE ON trombl_profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Auto-create profile on auth.users insert
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.trombl_profiles (id, display_name, avatar_url)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'display_name', 'wanderer'),
    NEW.raw_user_meta_data->>'avatar_url'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

COMMENT ON TABLE trombl_profiles IS 'Core user profile. Extended by all Trombl feature modules.';
COMMENT ON COLUMN trombl_profiles.instagram_handle IS 'Used in Drift contact exchange. Never stored in exchange table.';
COMMENT ON COLUMN trombl_profiles.whatsapp_number IS 'Used in Drift contact exchange. Never stored in exchange table.';
COMMENT ON COLUMN trombl_profiles.phone_number IS 'Used in Drift contact exchange. Never stored in exchange table.';

-- ─── trombl_blocked_users ────────────────────────────────────────────────────
-- Bidirectional block graph. Used across all modules.

CREATE TABLE public.trombl_blocked_users (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  blocker_id      uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  blocked_id      uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  is_system_block boolean NOT NULL DEFAULT false, -- true = moderator-created block
  reason          text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT no_self_block CHECK (blocker_id != blocked_id),
  CONSTRAINT unique_block UNIQUE (blocker_id, blocked_id)
);

CREATE INDEX trombl_blocked_users_blocker_idx ON trombl_blocked_users (blocker_id);
CREATE INDEX trombl_blocked_users_blocked_idx ON trombl_blocked_users (blocked_id);

COMMENT ON TABLE trombl_blocked_users IS 'Bidirectional block graph. System blocks are created by moderators.';

-- ─── trombl_push_tokens ──────────────────────────────────────────────────────
-- Push notification tokens per device.

CREATE TABLE public.trombl_push_tokens (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  token         text NOT NULL,
  platform      public.trombl_platform NOT NULL,
  is_active     boolean NOT NULL DEFAULT true,
  last_used_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unique_push_token UNIQUE (token)
);

CREATE INDEX trombl_push_tokens_user_idx ON trombl_push_tokens (user_id) WHERE is_active = true;

CREATE TRIGGER trombl_push_tokens_updated_at
  BEFORE UPDATE ON trombl_push_tokens
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE trombl_push_tokens IS 'Push notification tokens. One row per device per user.';

-- ─── trombl_notifications ────────────────────────────────────────────────────
-- Persisted notifications for in-app notification center.

CREATE TABLE public.trombl_notifications (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  type        public.trombl_notification_type NOT NULL,
  title       text NOT NULL,
  body        text NOT NULL,
  data        jsonb NOT NULL DEFAULT '{}',
  is_read     boolean NOT NULL DEFAULT false,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz
);

-- Hot query: fetch unread notifications for a user
CREATE INDEX trombl_notifications_user_unread_idx
  ON trombl_notifications (user_id, created_at DESC)
  WHERE is_read = false;

-- Hot query: all notifications for a user (for notification center)
CREATE INDEX trombl_notifications_user_idx
  ON trombl_notifications (user_id, created_at DESC);

-- Cleanup expired notifications
CREATE INDEX trombl_notifications_expires_idx
  ON trombl_notifications (expires_at)
  WHERE expires_at IS NOT NULL;

COMMENT ON TABLE trombl_notifications IS 'Persisted notifications for the in-app notification center. Realtime via Supabase Realtime.';

-- Mark notification as read (helper function)
CREATE OR REPLACE FUNCTION public.mark_notification_read(notification_id uuid)
RETURNS void AS $$
  UPDATE trombl_notifications
  SET is_read = true, read_at = now()
  WHERE id = notification_id
    AND user_id = auth.uid()
    AND is_read = false;
$$ LANGUAGE sql SECURITY DEFINER;

-- Mark all notifications as read for current user
CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS void AS $$
  UPDATE trombl_notifications
  SET is_read = true, read_at = now()
  WHERE user_id = auth.uid()
    AND is_read = false;
$$ LANGUAGE sql SECURITY DEFINER;
