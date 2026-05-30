-- ============================================================
-- Session Lifecycle Tests: creation, joining, expiry, participant count
-- Run with: psql $DATABASE_URL -f tests/functions/test_session_lifecycle.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(13);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('sess0001-0000-4000-s000-000000000001', 'host@test.trombl.com',   now(), now(), '{}'),
    ('sess0001-0000-4000-s000-000000000002', 'guest1@test.trombl.com', now(), now(), '{}'),
    ('sess0001-0000-4000-s000-000000000003', 'guest2@test.trombl.com', now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

INSERT INTO drift_activity_types (id, emoji, label, sort_order)
VALUES ('sessact1-0000-4000-s000-000000000001', '🚶', 'TestWalk', 98)
ON CONFLICT (label) DO NOTHING;

-- ─── Session creation ────────────────────────────────────────────────────────

INSERT INTO drift_sessions (
  id, host_user_id, activity_type_id, openness, timeframe,
  status, radius_km, city, location_snapshot
) VALUES (
  'sessid01-0000-4000-s000-000000000001',
  'sess0001-0000-4000-s000-000000000001',
  'sessact1-0000-4000-s000-000000000001',
  'open', 'now', 'active', 2.0, 'London',
  ST_SetSRID(ST_MakePoint(-0.1278, 51.5074), 4326)
);

SELECT ok(
  EXISTS(SELECT 1 FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001'),
  'Session created successfully'
);

SELECT ok(
  (
    SELECT expires_at - now() > interval '1 hour 55 minutes'
    FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001'
  ),
  'Session expires ~2 hours from creation'
);

-- Participant count starts at 0
SELECT ok(
  (SELECT participant_count FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001') = 0,
  'New session has 0 participants'
);

-- ─── Joining participants ─────────────────────────────────────────────────────

INSERT INTO drift_session_participants (session_id, user_id)
VALUES ('sessid01-0000-4000-s000-000000000001', 'sess0001-0000-4000-s000-000000000002');

SELECT ok(
  (SELECT participant_count FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001') = 1,
  'participant_count incremented to 1 after first join'
);

INSERT INTO drift_session_participants (session_id, user_id)
VALUES ('sessid01-0000-4000-s000-000000000001', 'sess0001-0000-4000-s000-000000000003');

SELECT ok(
  (SELECT participant_count FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001') = 2,
  'participant_count incremented to 2 after second join'
);

-- ─── Leaving participants ─────────────────────────────────────────────────────

UPDATE drift_session_participants
SET left_at = now()
WHERE session_id = 'sessid01-0000-4000-s000-000000000001'
  AND user_id = 'sess0001-0000-4000-s000-000000000002';

SELECT ok(
  (SELECT participant_count FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001') = 1,
  'participant_count decremented when participant leaves'
);

-- ─── Duplicate join prevention ────────────────────────────────────────────────

SELECT throws_ok(
  $$INSERT INTO drift_session_participants (session_id, user_id)
    VALUES ('sessid01-0000-4000-s000-000000000001', 'sess0001-0000-4000-s000-000000000003')$$,
  NULL,
  'Cannot join same session twice (UNIQUE constraint)'
);

-- ─── Activity log ────────────────────────────────────────────────────────────

SELECT ok(
  EXISTS(
    SELECT 1 FROM drift_session_activity_logs
    WHERE session_id = 'sessid01-0000-4000-s000-000000000001'
      AND event_type = 'participant_joined'
  ),
  'Activity log records participant_joined event'
);

-- ─── Session expiry ───────────────────────────────────────────────────────────

-- Manually expire the session
UPDATE drift_sessions
SET expires_at = now() - interval '1 minute'
WHERE id = 'sessid01-0000-4000-s000-000000000001';

-- Run cleanup
PERFORM public.run_scheduled_cleanup();

SELECT ok(
  (SELECT status FROM drift_sessions WHERE id = 'sessid01-0000-4000-s000-000000000001') = 'expired',
  'Session status set to expired after cleanup'
);

-- ─── Match expiry ────────────────────────────────────────────────────────────

INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'matchex01-0000-4000-m000-000000000001',
  'sess0001-0000-4000-s000-000000000001',
  'sess0001-0000-4000-s000-000000000002',
  'pending',
  now() - interval '1 minute'
);

PERFORM public.expire_pending_matches();

SELECT ok(
  (SELECT status FROM drift_matches WHERE id = 'matchex01-0000-4000-m000-000000000001') = 'expired',
  'Pending match marked expired after TTL'
);

-- ─── Match acceptance extends TTL ─────────────────────────────────────────────

INSERT INTO drift_matches (id, initiator_id, target_id, status)
VALUES (
  'matchacc1-0000-4000-m000-000000000001',
  'sess0001-0000-4000-s000-000000000001',
  'sess0001-0000-4000-s000-000000000003',
  'pending'
);

UPDATE drift_matches
SET status = 'accepted'
WHERE id = 'matchacc1-0000-4000-m000-000000000001';

SELECT ok(
  (
    SELECT expires_at > now() + interval '23 hours'
    FROM drift_matches WHERE id = 'matchacc1-0000-4000-m000-000000000001'
  ),
  'Accepted match TTL extended to 24 hours'
);

SELECT ok(
  (SELECT accepted_at IS NOT NULL FROM drift_matches WHERE id = 'matchacc1-0000-4000-m000-000000000001'),
  'accepted_at timestamp set on match acceptance'
);

-- ─── Contact exchange: mutual consent triggers reveal window ──────────────────

INSERT INTO drift_contact_exchange (match_id, contact_type, initiator_consented)
VALUES ('matchacc1-0000-4000-m000-000000000001', 'instagram', true);

-- No reveal_at yet (only one side consented)
SELECT ok(
  (SELECT reveal_at IS NULL FROM drift_contact_exchange WHERE match_id = 'matchacc1-0000-4000-m000-000000000001'),
  'No reveal_at set with only one consent'
);

UPDATE drift_contact_exchange
SET target_consented = true
WHERE match_id = 'matchacc1-0000-4000-m000-000000000001';

SELECT ok(
  (SELECT reveal_at IS NOT NULL FROM drift_contact_exchange WHERE match_id = 'matchacc1-0000-4000-m000-000000000001'),
  'reveal_at set after mutual consent'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;
