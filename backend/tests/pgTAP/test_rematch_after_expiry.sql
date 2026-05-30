-- ============================================================
-- pgTAP: Re-match after expiry (BUG-001 regression)
-- Validates: unique_active_match partial index allows re-matching
-- Run with: psql $DATABASE_URL -f tests/pgTAP/test_rematch_after_expiry.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(8);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('rematch01-0000-4000-r000-000000000001', 'alice@test.trombl.com', now(), now(), '{}'),
    ('rematch01-0000-4000-r000-000000000002', 'bob@test.trombl.com',   now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- ─── Initial pending match ────────────────────────────────────────────────────

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'remtmatch-0000-4000-0000-000000000001',
  'rematch01-0000-4000-r000-000000000001',
  'rematch01-0000-4000-r000-000000000002',
  'pending',
  now() + interval '10 minutes'
);

SELECT ok(
  EXISTS(SELECT 1 FROM drift_matches WHERE id = 'remtmatch-0000-4000-0000-000000000001'),
  'First pending match between Alice→Bob created successfully'
);

-- Duplicate active match should be blocked
SELECT throws_ok(
  $$INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
    VALUES (
      'rematch01-0000-4000-r000-000000000001',
      'rematch01-0000-4000-r000-000000000002',
      'pending',
      now() + interval '10 minutes'
    )$$,
  NULL,
  'Cannot create duplicate pending match between same pair'
);

-- ─── Expire the first match ───────────────────────────────────────────────────

UPDATE drift_matches
SET status = 'expired', ended_at = now(), end_reason = 'auto_expired'
WHERE id = 'remtmatch-0000-4000-0000-000000000001';

SELECT ok(
  (SELECT status FROM drift_matches WHERE id = 'remtmatch-0000-4000-0000-000000000001') = 'expired',
  'First match successfully expired'
);

-- ─── Re-match after expiry (BUG-001 fix validates this works) ─────────────────

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'remtmatch-0000-4000-0000-000000000002',
  'rematch01-0000-4000-r000-000000000001',
  'rematch01-0000-4000-r000-000000000002',
  'pending',
  now() + interval '10 minutes'
);

SELECT ok(
  EXISTS(SELECT 1 FROM drift_matches WHERE id = 'remtmatch-0000-4000-0000-000000000002'),
  'Alice can rematch Bob after first match expired (BUG-001 regression)'
);

-- ─── Declined match also allows re-match ─────────────────────────────────────

UPDATE drift_matches SET status = 'declined', ended_at = now()
WHERE id = 'remtmatch-0000-4000-0000-000000000002';

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'remtmatch-0000-4000-0000-000000000003',
  'rematch01-0000-4000-r000-000000000002',
  'rematch01-0000-4000-r000-000000000001',
  'pending',
  now() + interval '10 minutes'
);

SELECT ok(
  EXISTS(SELECT 1 FROM drift_matches WHERE id = 'remtmatch-0000-4000-0000-000000000003'),
  'Bob can initiate a match with Alice after his was declined (direction swap + re-match)'
);

-- ─── Two active matches (same pair, different direction) must still be blocked ─

SELECT throws_ok(
  $$INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
    VALUES (
      'rematch01-0000-4000-r000-000000000001',
      'rematch01-0000-4000-r000-000000000002',
      'pending',
      now() + interval '10 minutes'
    )$$,
  NULL,
  'Alice cannot send another pending match to Bob while Bobs pending match to Alice is active'
);

-- ─── Accepted match also locked ──────────────────────────────────────────────

UPDATE drift_matches SET status = 'accepted'
WHERE id = 'remtmatch-0000-4000-0000-000000000003';

SELECT throws_ok(
  $$INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
    VALUES (
      'rematch01-0000-4000-r000-000000000002',
      'rematch01-0000-4000-r000-000000000001',
      'pending',
      now() + interval '10 minutes'
    )$$,
  NULL,
  'Cannot create a second pending match while an accepted match already exists'
);

-- ─── Completed match allows re-match ─────────────────────────────────────────

UPDATE drift_matches SET status = 'completed', ended_at = now()
WHERE id = 'remtmatch-0000-4000-0000-000000000003';

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'remtmatch-0000-4000-0000-000000000004',
  'rematch01-0000-4000-r000-000000000001',
  'rematch01-0000-4000-r000-000000000002',
  'pending',
  now() + interval '10 minutes'
);

SELECT ok(
  EXISTS(SELECT 1 FROM drift_matches WHERE id = 'remtmatch-0000-4000-0000-000000000004'),
  'Re-match allowed after completed match (good drift can repeat)'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;
