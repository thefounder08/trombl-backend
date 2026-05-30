-- ============================================================
-- pgTAP: Edge cases — race conditions, timing, expiry, data integrity
-- Run with: psql $DATABASE_URL -f tests/pgTAP/test_edge_cases.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(22);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('edge0001-0000-4000-e000-000000000001', 'edge_alice@test.trombl.com', now(), now(), '{"display_name":"EdgeAlice"}'),
    ('edge0001-0000-4000-e000-000000000002', 'edge_bob@test.trombl.com',   now(), now(), '{"display_name":"EdgeBob"}'),
    ('edge0001-0000-4000-e000-000000000003', 'edge_carol@test.trombl.com', now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

INSERT INTO drift_activity_types (id, emoji, label, sort_order)
VALUES ('edgeact1-0000-4000-e000-000000000001', '🌀', 'Edge Test', 98)
ON CONFLICT (label) DO NOTHING;

-- ─── Trust score: default is 75 ──────────────────────────────────────────────

SELECT ok(
  (SELECT score FROM drift_trust_scores WHERE user_id = 'edge0001-0000-4000-e000-000000000001') = 75,
  'New user trust score defaults to 75'
);

-- ─── Trust score: auto-created on profile insert ──────────────────────────────

SELECT ok(
  EXISTS(SELECT 1 FROM drift_trust_scores WHERE user_id = 'edge0001-0000-4000-e000-000000000001'),
  'Trust score row auto-created by trigger on profile creation'
);

-- ─── Trust score: recompute handles zero reports correctly ────────────────────

SELECT public.recompute_trust_score('edge0001-0000-4000-e000-000000000001');

SELECT ok(
  (SELECT score FROM drift_trust_scores WHERE user_id = 'edge0001-0000-4000-e000-000000000001') = 75,
  'recompute with no reports or completions results in score 75'
);

-- ─── Match lifecycle: status transitions ─────────────────────────────────────

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'edge_mch-0000-4000-e000-000000000001',
  'edge0001-0000-4000-e000-000000000001',
  'edge0001-0000-4000-e000-000000000002',
  'pending',
  now() + interval '10 minutes'
);

-- Accept sets accepted_at and extends expires_at to 24h
UPDATE drift_matches SET status = 'accepted'
WHERE id = 'edge_mch-0000-4000-e000-000000000001';

SELECT ok(
  (SELECT accepted_at FROM drift_matches WHERE id = 'edge_mch-0000-4000-e000-000000000001') IS NOT NULL,
  'accepted_at set when match accepted'
);

SELECT ok(
  (SELECT expires_at FROM drift_matches WHERE id = 'edge_mch-0000-4000-e000-000000000001')
  BETWEEN now() + interval '23 hours' AND now() + interval '25 hours',
  'expires_at extended to ~24h when match accepted'
);

-- ─── Match: expire_pending_matches ignores accepted matches ───────────────────

-- Accepted match not expired by the cleanup function
UPDATE drift_matches
SET expires_at = now() - interval '5 minutes'
WHERE id = 'edge_mch-0000-4000-e000-000000000001';

SELECT public.expire_pending_matches();

SELECT ok(
  (SELECT status FROM drift_matches WHERE id = 'edge_mch-0000-4000-e000-000000000001') = 'accepted',
  'expire_pending_matches() does not expire accepted matches (only pending)'
);

-- ─── Expired pending match: expire_pending_matches picks it up ────────────────

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'edge_mch-0000-4000-e000-000000000002',
  'edge0001-0000-4000-e000-000000000001',
  'edge0001-0000-4000-e000-000000000003',
  'pending',
  now() - interval '1 minute'
);

SELECT public.expire_pending_matches();

SELECT ok(
  (SELECT status FROM drift_matches WHERE id = 'edge_mch-0000-4000-e000-000000000002') = 'expired',
  'expire_pending_matches() expires overdue pending matches'
);

SELECT ok(
  (SELECT end_reason FROM drift_matches WHERE id = 'edge_mch-0000-4000-e000-000000000002') = 'auto_expired',
  'Expired match has end_reason = auto_expired'
);

-- ─── Story: rate limit counter via reaction_count trigger ─────────────────────

INSERT INTO drift_stories (id, user_id, emoji, text, city, vibe_tags)
VALUES (
  'edge_str-0000-4000-e000-000000000001',
  'edge0001-0000-4000-e000-000000000001',
  '🌊', 'Edge test story', 'London', '{}'
);

SELECT ok(
  (SELECT reaction_count FROM drift_stories WHERE id = 'edge_str-0000-4000-e000-000000000001') = 0,
  'New story starts with reaction_count = 0'
);

INSERT INTO drift_story_reactions (story_id, user_id, reaction_type)
VALUES
  ('edge_str-0000-4000-e000-000000000001', 'edge0001-0000-4000-e000-000000000002', 'heart'),
  ('edge_str-0000-4000-e000-000000000001', 'edge0001-0000-4000-e000-000000000003', 'spark');

SELECT ok(
  (SELECT reaction_count FROM drift_stories WHERE id = 'edge_str-0000-4000-e000-000000000001') = 2,
  'reaction_count increments correctly on reaction inserts'
);

DELETE FROM drift_story_reactions
WHERE story_id = 'edge_str-0000-4000-e000-000000000001' AND user_id = 'edge0001-0000-4000-e000-000000000002';

SELECT ok(
  (SELECT reaction_count FROM drift_stories WHERE id = 'edge_str-0000-4000-e000-000000000001') = 1,
  'reaction_count decrements correctly on reaction delete'
);

-- Cannot react twice to same story
SELECT throws_ok(
  $$INSERT INTO drift_story_reactions (story_id, user_id, reaction_type)
    VALUES ('edge_str-0000-4000-e000-000000000001', 'edge0001-0000-4000-e000-000000000003', 'heart')$$,
  NULL,
  'Cannot react to same story twice (unique_reaction_per_user constraint)'
);

-- ─── Story: reaction_count cannot go negative ─────────────────────────────────

-- Manually set count to 0 then trigger a delete
UPDATE drift_stories SET reaction_count = 0 WHERE id = 'edge_str-0000-4000-e000-000000000001';

DELETE FROM drift_story_reactions
WHERE story_id = 'edge_str-0000-4000-e000-000000000001' AND user_id = 'edge0001-0000-4000-e000-000000000003';

SELECT ok(
  (SELECT reaction_count FROM drift_stories WHERE id = 'edge_str-0000-4000-e000-000000000001') = 0,
  'reaction_count cannot go below 0 (GREATEST guard in trigger)'
);

-- ─── Session: cleanup_stale_presence marks offline after 2min ─────────────────

INSERT INTO drift_presence (user_id, is_online, last_seen_at)
VALUES (
  'edge0001-0000-4000-e000-000000000001',
  true,
  now() - interval '3 minutes'  -- stale
) ON CONFLICT (user_id) DO UPDATE SET is_online = true, last_seen_at = now() - interval '3 minutes';

SELECT public.cleanup_stale_presence();

SELECT ok(
  (SELECT is_online FROM drift_presence WHERE user_id = 'edge0001-0000-4000-e000-000000000001') = false,
  'cleanup_stale_presence marks users offline after >2 minutes without heartbeat'
);

-- ─── Session: cleanup_expired_locations removes stale locations ───────────────

INSERT INTO drift_user_locations (user_id, location, expires_at)
VALUES (
  'edge0001-0000-4000-e000-000000000001',
  ST_SetSRID(ST_MakePoint(0, 0), 4326),
  now() - interval '1 minute'  -- expired
) ON CONFLICT (user_id) DO UPDATE
  SET location = EXCLUDED.location,
      expires_at = now() - interval '1 minute';

SELECT public.cleanup_expired_locations();

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM drift_user_locations
    WHERE user_id = 'edge0001-0000-4000-e000-000000000001'
  ),
  'cleanup_expired_locations deletes expired location records'
);

-- ─── Profile: username format validation ─────────────────────────────────────

SELECT throws_ok(
  $$UPDATE trombl_profiles SET username = 'AB' WHERE id = 'edge0001-0000-4000-e000-000000000001'$$,
  NULL,
  'Username shorter than 3 characters rejected (username_format CHECK)'
);

SELECT throws_ok(
  $$UPDATE trombl_profiles SET username = 'has spaces' WHERE id = 'edge0001-0000-4000-e000-000000000001'$$,
  NULL,
  'Username with spaces rejected (username_format CHECK)'
);

SELECT throws_ok(
  $$UPDATE trombl_profiles SET username = 'HAS_CAPS' WHERE id = 'edge0001-0000-4000-e000-000000000001'$$,
  NULL,
  'Uppercase username rejected (username_format CHECK — lowercase only)'
);

-- Valid username
UPDATE trombl_profiles SET username = 'edge_alice'
WHERE id = 'edge0001-0000-4000-e000-000000000001';

SELECT ok(
  (SELECT username FROM trombl_profiles WHERE id = 'edge0001-0000-4000-e000-000000000001') = 'edge_alice',
  'Valid lowercase username accepted'
);

-- ─── Story: text length limit ────────────────────────────────────────────────

SELECT throws_ok(
  $$INSERT INTO drift_stories (user_id, emoji, text, city)
    VALUES (
      'edge0001-0000-4000-e000-000000000001',
      '📝',
      repeat('x', 141),
      'London'
    )$$,
  NULL,
  'Story text > 140 characters rejected by CHECK constraint'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;
