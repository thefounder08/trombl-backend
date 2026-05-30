-- ============================================================
-- pgTAP: RLS attack scenarios
-- Tests privilege escalation, cross-user data access, field injection,
-- moderation bypass, session count manipulation, and notification tampering.
-- Run with: psql $DATABASE_URL -f tests/pgTAP/test_rls_attacks.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(30);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('atk00001-0000-4000-a000-000000000001', 'attacker@test.trombl.com', now(), now(), '{}'),
    ('atk00001-0000-4000-a000-000000000002', 'victim@test.trombl.com',   now(), now(), '{}'),
    ('atk00001-0000-4000-a000-000000000003', 'third@test.trombl.com',    now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- Activity type for session creation
INSERT INTO drift_activity_types (id, emoji, label, sort_order)
VALUES ('atk_act1-0000-4000-a000-000000000001', '🎯', 'Attack Test', 99)
ON CONFLICT (label) DO NOTHING;

-- ─── ATTACK: Escalate own profile (attempt to un-ban self) ───────────────────

RESET ROLE;
UPDATE trombl_profiles SET is_banned = true, banned_at = now(), ban_reason = 'test'
WHERE id = 'atk00001-0000-4000-a000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT throws_ok(
  $$UPDATE trombl_profiles SET is_banned = false WHERE id = 'atk00001-0000-4000-a000-000000000001'$$,
  NULL,
  'Banned user cannot unban themselves via profile UPDATE'
);

-- Reset for rest of test
RESET ROLE;
UPDATE trombl_profiles SET is_banned = false, banned_at = null, ban_reason = null
WHERE id = 'atk00001-0000-4000-a000-000000000001';

-- ─── ATTACK: Write ban fields to another user's profile ──────────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT throws_ok(
  $$UPDATE trombl_profiles SET is_banned = true WHERE id = 'atk00001-0000-4000-a000-000000000002'$$,
  'new row violates row-level security policy',
  'Attacker cannot ban another user via direct profile UPDATE'
);

-- ─── ATTACK: Read another user's location ────────────────────────────────────

RESET ROLE;
INSERT INTO drift_user_locations (user_id, location, expires_at)
VALUES (
  'atk00001-0000-4000-a000-000000000002',
  ST_SetSRID(ST_MakePoint(-0.1278, 51.5074), 4326),
  now() + interval '15 minutes'
) ON CONFLICT (user_id) DO UPDATE SET location = EXCLUDED.location;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_user_locations WHERE user_id = 'atk00001-0000-4000-a000-000000000002'),
  'Attacker cannot read victim''s location record directly'
);

-- ─── ATTACK: Read another user's trust score ─────────────────────────────────

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_trust_scores WHERE user_id = 'atk00001-0000-4000-a000-000000000002'),
  'Attacker cannot read victim''s trust score'
);

-- ─── ATTACK: Manually inflate own trust score ────────────────────────────────

SELECT throws_ok(
  $$UPDATE drift_trust_scores SET score = 100 WHERE user_id = 'atk00001-0000-4000-a000-000000000001'$$,
  NULL,
  'Attacker cannot directly update their own trust score'
);

-- ─── ATTACK: Create a match impersonating the victim ─────────────────────────

SELECT throws_ok(
  $$INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
    VALUES (
      'atk00001-0000-4000-a000-000000000002',
      'atk00001-0000-4000-a000-000000000003',
      'pending',
      now() + interval '10 minutes'
    )$$,
  'new row violates row-level security policy',
  'Attacker cannot send match requests on behalf of victim'
);

-- ─── ATTACK: Accept a match not addressed to attacker ────────────────────────

RESET ROLE;
INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'atk_mtch-0000-4000-a000-000000000001',
  'atk00001-0000-4000-a000-000000000002',
  'atk00001-0000-4000-a000-000000000003',
  'pending',
  now() + interval '10 minutes'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT throws_ok(
  $$UPDATE drift_matches SET status = 'accepted'
    WHERE id = 'atk_mtch-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Attacker cannot accept a match they are not part of'
);

-- ─── ATTACK: Read another user's notification ────────────────────────────────

RESET ROLE;
INSERT INTO trombl_notifications (id, user_id, type, title, body)
VALUES (
  'atk_not1-0000-4000-a000-000000000001',
  'atk00001-0000-4000-a000-000000000002',
  'system',
  'Private notification for victim',
  'Secret content'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM trombl_notifications WHERE id = 'atk_not1-0000-4000-a000-000000000001'
  ),
  'Attacker cannot read victim''s notification'
);

-- ─── ATTACK: Tamper with own notification content ────────────────────────────

RESET ROLE;
INSERT INTO trombl_notifications (id, user_id, type, title, body)
VALUES (
  'atk_not2-0000-4000-a000-000000000001',
  'atk00001-0000-4000-a000-000000000001',
  'system',
  'Original title',
  'Original body'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

-- Valid update: mark as read
UPDATE trombl_notifications
SET is_read = true, read_at = now()
WHERE id = 'atk_not2-0000-4000-a000-000000000001';

SELECT ok(
  (SELECT is_read FROM trombl_notifications WHERE id = 'atk_not2-0000-4000-a000-000000000001'),
  'Attacker CAN mark their own notification as read (legitimate)'
);

-- Invalid update: change content (BUG-005 fix)
SELECT throws_ok(
  $$UPDATE trombl_notifications SET title = 'Hacked title' WHERE id = 'atk_not2-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Attacker cannot change notification title (BUG-005 regression)'
);

SELECT throws_ok(
  $$UPDATE trombl_notifications SET type = 'safety_alert' WHERE id = 'atk_not2-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Attacker cannot escalate notification type to safety_alert (BUG-005 regression)'
);

SELECT throws_ok(
  $$UPDATE trombl_notifications SET body = 'Phishing body' WHERE id = 'atk_not2-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Attacker cannot change notification body (BUG-005 regression)'
);

-- ─── ATTACK: Inflate session participant_count manually ───────────────────────

RESET ROLE;
INSERT INTO drift_sessions (id, host_user_id, activity_type_id, openness, timeframe,
                             status, radius_km, city, location_snapshot)
VALUES (
  'atk_ses1-0000-4000-a000-000000000001',
  'atk00001-0000-4000-a000-000000000002',  -- victim's session
  'atk_act1-0000-4000-a000-000000000001',
  'open', 'right_now', 'active', 2.0, 'London',
  ST_SetSRID(ST_MakePoint(-0.1278, 51.5074), 4326)
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

-- Attacker cannot update victim's session at all
SELECT throws_ok(
  $$UPDATE drift_sessions SET participant_count = 999
    WHERE id = 'atk_ses1-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Attacker cannot update participant_count on another user''s session'
);

-- ─── ATTACK: Session host attempts participant_count injection ────────────────

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000002"}';

-- Victim's own session — can they set arbitrary participant_count?
SELECT throws_ok(
  $$UPDATE drift_sessions SET participant_count = 9999
    WHERE id = 'atk_ses1-0000-4000-a000-000000000001'$$,
  NULL,
  'Session host cannot set arbitrary participant_count (CHECK constraint >= 0 allows high values — document this)'
);

-- ─── ATTACK: Report victim from blocked context (bypassing block via direct INSERT) ──

RESET ROLE;
INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
VALUES ('atk00001-0000-4000-a000-000000000001', 'atk00001-0000-4000-a000-000000000002', false)
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

-- Reporting is still possible even with a block (by design — reporters should still be able to report)
INSERT INTO drift_reports (reporter_id, reported_id, reason)
VALUES (
  'atk00001-0000-4000-a000-000000000001',
  'atk00001-0000-4000-a000-000000000002',
  'spam'
);

SELECT ok(
  EXISTS(
    SELECT 1 FROM drift_reports
    WHERE reporter_id = 'atk00001-0000-4000-a000-000000000001'
      AND reported_id = 'atk00001-0000-4000-a000-000000000002'
  ),
  'Blocked users can still file reports (by design — safety escape hatch)'
);

-- ─── ATTACK: System block creation by regular user ───────────────────────────

SELECT throws_ok(
  $$INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
    VALUES ('atk00001-0000-4000-a000-000000000001', 'atk00001-0000-4000-a000-000000000003', true)$$,
  'new row violates row-level security policy',
  'Regular user cannot create a system block'
);

-- ─── ATTACK: Read moderation queue ───────────────────────────────────────────

SELECT ok(
  NOT EXISTS(SELECT 1 FROM drift_moderation_queue),
  'Regular user sees empty moderation queue (deny-all policy)'
);

-- ─── ATTACK: Self-block ───────────────────────────────────────────────────────

SELECT throws_ok(
  $$INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
    VALUES ('atk00001-0000-4000-a000-000000000001', 'atk00001-0000-4000-a000-000000000001', false)$$,
  NULL,
  'User cannot block themselves (no_self_block CHECK)'
);

-- ─── ATTACK: Self-report ─────────────────────────────────────────────────────

SELECT throws_ok(
  $$INSERT INTO drift_reports (reporter_id, reported_id, reason)
    VALUES ('atk00001-0000-4000-a000-000000000001', 'atk00001-0000-4000-a000-000000000001', 'spam')$$,
  NULL,
  'User cannot report themselves (no_self_report CHECK)'
);

-- ─── ATTACK: Self-match ───────────────────────────────────────────────────────

SELECT throws_ok(
  $$INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
    VALUES (
      'atk00001-0000-4000-a000-000000000001',
      'atk00001-0000-4000-a000-000000000001',
      'pending',
      now() + interval '10 minutes'
    )$$,
  NULL,
  'User cannot match themselves (no_self_match CHECK)'
);

-- ─── ATTACK: Story unflag bypass ─────────────────────────────────────────────

RESET ROLE;
INSERT INTO drift_stories (id, user_id, emoji, text, city, is_flagged)
VALUES (
  'atk_str1-0000-4000-a000-000000000001',
  'atk00001-0000-4000-a000-000000000001',
  '⚡', 'Flagged story', 'London', true
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT throws_ok(
  $$UPDATE drift_stories SET is_flagged = false WHERE id = 'atk_str1-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Author cannot unflag their own story (RLS WITH CHECK subquery)'
);

-- ─── ATTACK: Story is_removed bypass ─────────────────────────────────────────

RESET ROLE;
UPDATE drift_stories SET is_removed = true WHERE id = 'atk_str1-0000-4000-a000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT throws_ok(
  $$UPDATE drift_stories SET is_removed = false WHERE id = 'atk_str1-0000-4000-a000-000000000001'$$,
  'new row violates row-level security policy',
  'Author cannot un-remove their own story'
);

-- ─── ATTACK: Reading contact exchange of a match you are not part of ──────────

RESET ROLE;
INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'atk_mtch-0000-4000-a000-000000000002',
  'atk00001-0000-4000-a000-000000000002',
  'atk00001-0000-4000-a000-000000000003',
  'accepted',
  now() + interval '24 hours'
);
INSERT INTO drift_contact_exchange (match_id, initiator_consented, initiator_contact_type)
VALUES ('atk_mtch-0000-4000-a000-000000000002', true, 'instagram');

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub": "atk00001-0000-4000-a000-000000000001"}';

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM drift_contact_exchange
    WHERE match_id = 'atk_mtch-0000-4000-a000-000000000002'
  ),
  'Attacker cannot read contact exchange of a match they are not part of'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
