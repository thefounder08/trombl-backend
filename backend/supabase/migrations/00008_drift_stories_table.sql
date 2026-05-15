-- ============================================================
-- Migration: 00008_drift_stories_table
-- Description: Anonymous drift stories and reactions
-- ============================================================

-- ─── drift_stories ───────────────────────────────────────────────────────────

CREATE TABLE public.drift_stories (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Stored for moderation only. NEVER exposed in public API reads.
  user_id         uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,

  emoji           text NOT NULL,
  text            text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 140),
  city            text NOT NULL CHECK (char_length(city) BETWEEN 1 AND 100),
  country_code    char(2),
  activity_tag    text,
  activity_emoji  text,
  vibe_tags       text[] NOT NULL DEFAULT '{}',

  -- Denormalized reaction count for fast feed queries
  reaction_count  int NOT NULL DEFAULT 0 CHECK (reaction_count >= 0),

  -- Moderation state
  is_flagged      boolean NOT NULL DEFAULT false,
  is_removed      boolean NOT NULL DEFAULT false,
  removed_reason  text,

  -- Lifecycle
  published_at    timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- Soft delete (90-day retention)
  deleted_at      timestamptz
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────

-- City feed: most recent stories per city (primary read pattern)
CREATE INDEX drift_stories_city_feed_idx
  ON drift_stories (city, published_at DESC)
  WHERE is_removed = false AND deleted_at IS NULL;

-- Global feed
CREATE INDEX drift_stories_global_feed_idx
  ON drift_stories (published_at DESC)
  WHERE is_removed = false AND deleted_at IS NULL;

-- Activity filter
CREATE INDEX drift_stories_activity_idx
  ON drift_stories (activity_tag, published_at DESC)
  WHERE is_removed = false AND deleted_at IS NULL AND activity_tag IS NOT NULL;

-- Moderation queue: flagged stories
CREATE INDEX drift_stories_flagged_idx
  ON drift_stories (is_flagged, published_at DESC)
  WHERE is_flagged = true AND is_removed = false;

-- User's own stories (for moderation lookup — not exposed in public API)
CREATE INDEX drift_stories_user_idx
  ON drift_stories (user_id, published_at DESC);

-- Soft-delete cleanup
CREATE INDEX drift_stories_deleted_idx
  ON drift_stories (deleted_at)
  WHERE deleted_at IS NOT NULL;

-- ─── Triggers ────────────────────────────────────────────────────────────────

CREATE TRIGGER drift_stories_updated_at
  BEFORE UPDATE ON drift_stories
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE drift_stories IS
  'Anonymous drift stories. user_id is stored for moderation only and never exposed in reads. 90-day retention.';
COMMENT ON COLUMN drift_stories.user_id IS
  'Stored for moderation and block filtering only. RLS ensures it is never exposed in public reads.';

-- ─── drift_story_reactions ───────────────────────────────────────────────────

CREATE TABLE public.drift_story_reactions (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  story_id      uuid NOT NULL REFERENCES drift_stories(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  reaction_type public.drift_story_reaction_type NOT NULL DEFAULT 'heart',
  created_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unique_reaction_per_user UNIQUE (story_id, user_id)
);

CREATE INDEX drift_story_reactions_story_idx
  ON drift_story_reactions (story_id);

CREATE INDEX drift_story_reactions_user_idx
  ON drift_story_reactions (user_id);

-- Increment/decrement reaction_count on drift_stories
CREATE OR REPLACE FUNCTION public.update_story_reaction_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE drift_stories
    SET reaction_count = reaction_count + 1
    WHERE id = NEW.story_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE drift_stories
    SET reaction_count = GREATEST(0, reaction_count - 1)
    WHERE id = OLD.story_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_story_reactions_count
  AFTER INSERT OR DELETE ON drift_story_reactions
  FOR EACH ROW EXECUTE FUNCTION public.update_story_reaction_count();

COMMENT ON TABLE drift_story_reactions IS
  'One reaction per user per story. Reaction type can be changed by DELETE + INSERT.';

-- ─── Scheduled cleanup: soft-delete stories older than 90 days ───────────────

CREATE OR REPLACE FUNCTION public.cleanup_old_stories()
RETURNS int AS $$
DECLARE
  deleted_count int;
BEGIN
  UPDATE drift_stories
  SET deleted_at = now(), updated_at = now()
  WHERE
    deleted_at IS NULL
    AND published_at < now() - interval '90 days';
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
