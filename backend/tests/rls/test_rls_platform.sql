-- ============================================================
-- RLS Tests: trombl platform tables
-- Run with: psql $DATABASE_URL -f tests/rls/test_rls_platform.sql
-- ============================================================

BEGIN;

-- ─── Setup ───────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(22);

-- Create two test user IDs
DO $$
BEGIN
  -- Insert test auth users (bypasses RLS via service role in test env)
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('aaaaaaaa-0000-4000-a000-000000000001', 'alice@test.trombl.com', now(), now(), '{}'),
    ('aaaaaaaa-0000-4000-a000-000000000002', 'bob@test.trombl.com',   now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- Profiles are auto-created by trigger; ensure they exist
SELECT ok(
  EXISTS(SELECT 1 FROM trombl_profiles WHERE id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Alice profile auto-created on auth.users insert'
);

SELECT ok(
  EXISTS(SELECT 1 FROM trombl_profiles WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002'),
  'Bob profile auto-created on auth.users insert'
);

-- Trust scores auto-created
SELECT ok(
  EXISTS(SELECT 1 FROM drift_trust_scores WHERE user_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Alice trust score auto-created'
);

-- ─── trombl_profiles: SELECT public ──────────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000001"}';

SELECT ok(
  EXISTS(SELECT 1 FROM trombl_profiles WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002'),
  'Alice can see Bob''s public profile'
);

-- Ban Bob and confirm Alice cannot see him
RESET ROLE;
UPDATE trombl_profiles SET is_banned = true WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000001"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM trombl_profiles WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002'),
  'Banned user is hidden from public profile SELECT'
);

RESET ROLE;
UPDATE trombl_profiles SET is_banned = false WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002';

-- ─── trombl_profiles: UPDATE (own only) ──────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000001"}';

-- Alice can update her own display_name
UPDATE trombl_profiles SET display_name = 'Alice Test' WHERE id = 'aaaaaaaa-0000-4000-a000-000000000001';
SELECT ok(
  (SELECT display_name FROM trombl_profiles WHERE id = 'aaaaaaaa-0000-4000-a000-000000000001') = 'Alice Test',
  'Alice can update her own profile'
);

-- Alice cannot update Bob's profile
UPDATE trombl_profiles SET display_name = 'Hijacked' WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002';
SELECT ok(
  (SELECT display_name FROM trombl_profiles WHERE id = 'aaaaaaaa-0000-4000-a000-000000000002') IS DISTINCT FROM 'Hijacked',
  'Alice cannot update Bob''s profile'
);

-- Alice cannot self-ban
SELECT throws_ok(
  $$UPDATE trombl_profiles SET is_banned = true WHERE id = 'aaaaaaaa-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Alice cannot set is_banned on herself'
);

-- ─── trombl_blocked_users ────────────────────────────────────────────────────

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000001"}';

-- Alice blocks Bob
INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
VALUES ('aaaaaaaa-0000-4000-a000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000002', false);

SELECT ok(
  EXISTS(SELECT 1 FROM trombl_blocked_users WHERE blocker_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Alice can insert her own block'
);

-- Alice cannot insert a system block
SELECT throws_ok(
  $$INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
    VALUES ('aaaaaaaa-0000-4000-a000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000002', true)$$,
  'new row violates row-level security policy',
  'Alice cannot insert a system block'
);

-- Alice cannot block as Bob
SELECT throws_ok(
  $$INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
    VALUES ('aaaaaaaa-0000-4000-a000-000000000002', 'aaaaaaaa-0000-4000-a000-000000000001', false)$$,
  'new row violates row-level security policy',
  'Alice cannot insert block with Bob as blocker'
);

-- Alice can see block (both directions because she is party)
SELECT ok(
  EXISTS(SELECT 1 FROM trombl_blocked_users
         WHERE blocker_id = 'aaaaaaaa-0000-4000-a000-000000000001'
           AND blocked_id = 'aaaaaaaa-0000-4000-a000-000000000002'),
  'Alice can see her own block record'
);

-- Alice can unblock Bob
DELETE FROM trombl_blocked_users
WHERE blocker_id = 'aaaaaaaa-0000-4000-a000-000000000001'
  AND blocked_id = 'aaaaaaaa-0000-4000-a000-000000000002';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM trombl_blocked_users
             WHERE blocker_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Alice can delete her own non-system block'
);

-- ─── trombl_notifications ────────────────────────────────────────────────────

RESET ROLE;
-- Service role inserts a notification for Alice
INSERT INTO trombl_notifications (user_id, type, title, body)
VALUES ('aaaaaaaa-0000-4000-a000-000000000001', 'trombl_system', 'Test', 'Hello Alice');

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000001"}';

SELECT ok(
  EXISTS(SELECT 1 FROM trombl_notifications WHERE user_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Alice can see her own notification'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000002"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM trombl_notifications WHERE user_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Bob cannot see Alice''s notifications'
);

-- ─── trombl_push_tokens ──────────────────────────────────────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000001"}';

INSERT INTO trombl_push_tokens (user_id, token, platform)
VALUES ('aaaaaaaa-0000-4000-a000-000000000001', 'ExponentPushToken[test-alice]', 'ios');

SELECT ok(
  EXISTS(SELECT 1 FROM trombl_push_tokens WHERE user_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Alice can insert and read her own push token'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "aaaaaaaa-0000-4000-a000-000000000002"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM trombl_push_tokens WHERE user_id = 'aaaaaaaa-0000-4000-a000-000000000001'),
  'Bob cannot read Alice''s push tokens'
);

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
