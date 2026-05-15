-- ============================================================
-- RLS Tests: drift feature tables
-- Run with: psql $DATABASE_URL -f tests/rls/test_rls_drift.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(28);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('bbbbbbbb-0000-4000-b000-000000000001', 'carol@test.trombl.com', now(), now(), '{}'),
    ('bbbbbbbb-0000-4000-b000-000000000002', 'dave@test.trombl.com',  now(), now(), '{}'),
    ('bbbbbbbb-0000-4000-b000-000000000003', 'eve@test.trombl.com',   now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- Insert activity type and vibe tag for tests
INSERT INTO drift_activity_types (id, emoji, label, sort_order)
VALUES ('cccccccc-0000-4000-c000-000000000001', '☕', 'TestCoffee', 99)
ON CONFLICT (label) DO NOTHING;

-- ─── drift_activity_types: public catalog read ────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

SELECT ok(
  EXISTS(SELECT 1 FROM drift_activity_types WHERE label = 'TestCoffee'),
  'Authenticated user can read active activity types'
);

-- Cannot insert activity types
SELECT throws_ok(
  $$INSERT INTO drift_activity_types (emoji, label, sort_order) VALUES ('🎸', 'Guitar', 100)$$,
  NULL,
  'Authenticated user cannot insert activity types'
);

-- ─── drift_user_locations: own only ──────────────────────────────────────────

RESET ROLE;
-- Service role inserts Carol's location
INSERT INTO drift_user_locations (user_id, location, expires_at)
VALUES (
  'bbbbbbbb-0000-4000-b000-000000000001',
  ST_SetSRID(ST_MakePoint(-0.1278, 51.5074), 4326),
  now() + interval '15 minutes'
) ON CONFLICT (user_id) DO UPDATE SET location = EXCLUDED.location;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

SELECT ok(
  EXISTS(SELECT 1 FROM drift_user_locations WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  'Carol can read her own location'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_user_locations WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  'Dave cannot read Carol''s location directly'
);

-- ─── drift_sessions ──────────────────────────────────────────────────────────

RESET ROLE;

-- Carol creates a session (via service role to bypass RLS in setup)
INSERT INTO drift_sessions (id, host_user_id, activity_type_id, openness, timeframe, status, radius_km, city, location_snapshot)
VALUES (
  'dddddddd-0000-4000-d000-000000000001',
  'bbbbbbbb-0000-4000-b000-000000000001',
  'cccccccc-0000-4000-c000-000000000001',
  'open', 'now', 'active', 2.0, 'London',
  ST_SetSRID(ST_MakePoint(-0.1278, 51.5074), 4326)
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

-- Dave can see Carol's active session
SELECT ok(
  EXISTS(SELECT 1 FROM drift_sessions WHERE id = 'dddddddd-0000-4000-d000-000000000001'),
  'Dave can see Carol''s active session'
);

-- Dave cannot create a session as Carol
SELECT throws_ok(
  $$INSERT INTO drift_sessions (host_user_id, activity_type_id, openness, timeframe, status, radius_km, city, location_snapshot)
    VALUES ('bbbbbbbb-0000-4000-b000-000000000001', 'cccccccc-0000-4000-c000-000000000001', 'open', 'now', 'active', 2.0, 'London', ST_SetSRID(ST_MakePoint(0,0), 4326))$$,
  'new row violates row-level security policy',
  'Dave cannot create a session impersonating Carol'
);

-- ─── drift_session_participants ───────────────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

INSERT INTO drift_session_participants (session_id, user_id)
VALUES ('dddddddd-0000-4000-d000-000000000001', 'bbbbbbbb-0000-4000-b000-000000000002');

SELECT ok(
  EXISTS(SELECT 1 FROM drift_session_participants WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000002'),
  'Dave can join a session'
);

SELECT throws_ok(
  $$INSERT INTO drift_session_participants (session_id, user_id)
    VALUES ('dddddddd-0000-4000-d000-000000000001', 'bbbbbbbb-0000-4000-b000-000000000001')$$,
  'new row violates row-level security policy',
  'Dave cannot join as Carol'
);

-- ─── drift_matches ────────────────────────────────────────────────────────────

RESET ROLE;
INSERT INTO drift_matches (id, initiator_id, target_id, status)
VALUES (
  'eeeeeeee-0000-4000-e000-000000000001',
  'bbbbbbbb-0000-4000-b000-000000000001',
  'bbbbbbbb-0000-4000-b000-000000000002',
  'pending'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

SELECT ok(
  EXISTS(SELECT 1 FROM drift_matches WHERE id = 'eeeeeeee-0000-4000-e000-000000000001'),
  'Carol can see her own match'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

SELECT ok(
  EXISTS(SELECT 1 FROM drift_matches WHERE id = 'eeeeeeee-0000-4000-e000-000000000001'),
  'Dave (target) can see the match too'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000003"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_matches WHERE id = 'eeeeeeee-0000-4000-e000-000000000001'),
  'Eve (third party) cannot see Carol and Dave''s match'
);

-- ─── drift_stories ────────────────────────────────────────────────────────────

RESET ROLE;
INSERT INTO drift_stories (id, user_id, emoji, text, city)
VALUES (
  'ffffffff-0000-4000-f000-000000000001',
  'bbbbbbbb-0000-4000-b000-000000000001',
  '☕', 'Just drifting around London', 'London'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

-- Dave can read the story but user_id should be readable (RLS doesn't column-mask, but API strips it)
SELECT ok(
  EXISTS(SELECT 1 FROM drift_stories WHERE id = 'ffffffff-0000-4000-f000-000000000001'),
  'Dave can see Carol''s story (public feed)'
);

-- ─── story blocked user filter ────────────────────────────────────────────────

RESET ROLE;
INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
VALUES ('bbbbbbbb-0000-4000-b000-000000000002', 'bbbbbbbb-0000-4000-b000-000000000001', false)
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_stories WHERE id = 'ffffffff-0000-4000-f000-000000000001'),
  'Dave cannot see Carol''s story after blocking her'
);

RESET ROLE;
DELETE FROM trombl_blocked_users
WHERE blocker_id = 'bbbbbbbb-0000-4000-b000-000000000002'
  AND blocked_id = 'bbbbbbbb-0000-4000-b000-000000000001';

-- ─── drift_stories: cannot unflag/unremove ────────────────────────────────────

RESET ROLE;
UPDATE drift_stories SET is_flagged = true WHERE id = 'ffffffff-0000-4000-f000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

SELECT throws_ok(
  $$UPDATE drift_stories SET is_flagged = false WHERE id = 'ffffffff-0000-4000-f000-000000000001'$$,
  'new row violates row-level security policy',
  'Carol cannot unflag her own story'
);

-- ─── drift_trust_scores ───────────────────────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

SELECT ok(
  EXISTS(SELECT 1 FROM drift_trust_scores WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  'Carol can read her own trust score'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_trust_scores WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  'Dave cannot read Carol''s trust score'
);

-- Cannot manually update trust score
SELECT throws_ok(
  $$UPDATE drift_trust_scores SET score = 100 WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000002'$$,
  NULL,
  'Dave cannot manually update trust scores'
);

-- ─── drift_moderation_queue: deny all ────────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_moderation_queue),
  'Carol cannot read drift_moderation_queue (deny-all policy)'
);

-- ─── drift_reports: own only ──────────────────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000001"}';

INSERT INTO drift_reports (reporter_id, reported_id, reason)
VALUES ('bbbbbbbb-0000-4000-b000-000000000001', 'bbbbbbbb-0000-4000-b000-000000000002', 'spam');

SELECT ok(
  EXISTS(SELECT 1 FROM drift_reports WHERE reporter_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  'Carol can see her own report'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_reports WHERE reporter_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  'Dave cannot see Carol''s reports against him'
);

-- Self-report prevention
SELECT throws_ok(
  $$INSERT INTO drift_reports (reporter_id, reported_id, reason)
    VALUES ('bbbbbbbb-0000-4000-b000-000000000002', 'bbbbbbbb-0000-4000-b000-000000000002', 'spam')$$,
  NULL,
  'Dave cannot report himself'
);

-- ─── drift_presence ──────────────────────────────────────────────────────────

RESET ROLE;
INSERT INTO drift_presence (user_id, is_online, last_seen_at)
VALUES ('bbbbbbbb-0000-4000-b000-000000000001', true, now())
ON CONFLICT (user_id) DO UPDATE SET is_online = true;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "bbbbbbbb-0000-4000-b000-000000000002"}';

SELECT ok(
  EXISTS(SELECT 1 FROM drift_presence WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000001' AND is_online = true),
  'Dave can see Carol''s online presence'
);

-- Cannot update someone else's presence
SELECT throws_ok(
  $$UPDATE drift_presence SET is_online = false WHERE user_id = 'bbbbbbbb-0000-4000-b000-000000000001'$$,
  'new row violates row-level security policy',
  'Dave cannot update Carol''s presence'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
