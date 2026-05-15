-- ============================================================
-- Trust & Safety Tests: trust score computation, auto-ban, moderation
-- Run with: psql $DATABASE_URL -f tests/functions/test_trust_safety.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(14);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('trust001-0000-4000-t000-000000000001', 'trusting@test.trombl.com', now(), now(), '{}'),
    ('trust001-0000-4000-t000-000000000002', 'reporter@test.trombl.com', now(), now(), '{}'),
    ('trust001-0000-4000-t000-000000000003', 'reporter2@test.trombl.com', now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- ─── Trust score default ─────────────────────────────────────────────────────

SELECT ok(
  (SELECT score FROM drift_trust_scores WHERE user_id = 'trust001-0000-4000-t000-000000000001') = 75,
  'Default trust score is 75'
);

-- ─── Report impact on trust score ────────────────────────────────────────────

INSERT INTO drift_reports (reporter_id, reported_id, reason)
VALUES ('trust001-0000-4000-t000-000000000002', 'trust001-0000-4000-t000-000000000001', 'spam');

SELECT ok(
  (SELECT score FROM drift_trust_scores WHERE user_id = 'trust001-0000-4000-t000-000000000001') = 70,
  'Trust score drops by 5 after first report'
);

SELECT ok(
  (SELECT report_count FROM drift_trust_scores WHERE user_id = 'trust001-0000-4000-t000-000000000001') = 1,
  'Report count incremented after report'
);

-- ─── Moderation queue entry ───────────────────────────────────────────────────

SELECT ok(
  EXISTS(
    SELECT 1 FROM drift_moderation_queue mq
    JOIN drift_reports r ON r.id = mq.report_id
    WHERE r.reported_id = 'trust001-0000-4000-t000-000000000001'
  ),
  'Report triggers moderation queue entry'
);

-- Spam report should be priority 3
SELECT ok(
  (
    SELECT mq.priority FROM drift_moderation_queue mq
    JOIN drift_reports r ON r.id = mq.report_id
    WHERE r.reported_id = 'trust001-0000-4000-t000-000000000001'
    ORDER BY mq.created_at DESC LIMIT 1
  ) = 3,
  'Spam report gets priority 3 (low)'
);

-- Safety report gets priority 1
INSERT INTO drift_reports (reporter_id, reported_id, reason)
VALUES ('trust001-0000-4000-t000-000000000003', 'trust001-0000-4000-t000-000000000001', 'made_me_feel_unsafe');

SELECT ok(
  EXISTS(
    SELECT 1 FROM drift_moderation_queue mq
    JOIN drift_reports r ON r.id = mq.report_id
    WHERE r.reported_id = 'trust001-0000-4000-t000-000000000001'
      AND r.reason = 'made_me_feel_unsafe'
      AND mq.priority = 1
  ),
  'Safety report gets priority 1 (high)'
);

-- ─── recompute_trust_score ────────────────────────────────────────────────────

-- Create some successful drifts for user
INSERT INTO drift_matches (id, initiator_id, target_id, status)
VALUES
  (gen_random_uuid(), 'trust001-0000-4000-t000-000000000001', 'trust001-0000-4000-t000-000000000002', 'completed'),
  (gen_random_uuid(), 'trust001-0000-4000-t000-000000000001', 'trust001-0000-4000-t000-000000000003', 'completed'),
  (gen_random_uuid(), 'trust001-0000-4000-t000-000000000002', 'trust001-0000-4000-t000-000000000001', 'completed');

SELECT public.recompute_trust_score('trust001-0000-4000-t000-000000000001');

-- 3 successful drifts = +6 positive signals
-- 2 reports (1 spam, 1 safety) — neither resolved_actioned yet so report_count = 0 in recompute
-- positive: 3 * 2 = 6, negative: 0, score: 75 + 6 - 0 = 81
SELECT ok(
  (SELECT score FROM drift_trust_scores WHERE user_id = 'trust001-0000-4000-t000-000000000001') = 81,
  'recompute_trust_score correctly incorporates successful drifts'
);

SELECT ok(
  (SELECT successful_drifts FROM drift_trust_scores WHERE user_id = 'trust001-0000-4000-t000-000000000001') = 3,
  'successful_drifts counter is correct'
);

-- ─── Auto-ban when score hits 0 ──────────────────────────────────────────────

-- Manually set score to 5 (near zero)
UPDATE drift_trust_scores SET score = 5 WHERE user_id = 'trust001-0000-4000-t000-000000000001';

-- Insert enough reports to drop score to 0
INSERT INTO drift_reports (reporter_id, reported_id, reason)
VALUES ('trust001-0000-4000-t000-000000000002', 'trust001-0000-4000-t000-000000000001', 'harassment');

SELECT ok(
  (SELECT score FROM drift_trust_scores WHERE user_id = 'trust001-0000-4000-t000-000000000001') = 0,
  'Trust score reaches 0 after critical report'
);

SELECT ok(
  (SELECT is_banned FROM trombl_profiles WHERE id = 'trust001-0000-4000-t000-000000000001') = true,
  'User is auto-banned when trust score reaches 0'
);

SELECT ok(
  (SELECT ban_reason FROM trombl_profiles WHERE id = 'trust001-0000-4000-t000-000000000001') LIKE 'Automated%',
  'Auto-ban reason is set correctly'
);

-- ─── is_blocked function ─────────────────────────────────────────────────────

INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
VALUES ('trust001-0000-4000-t000-000000000002', 'trust001-0000-4000-t000-000000000003', false)
ON CONFLICT DO NOTHING;

SELECT ok(
  public.is_blocked('trust001-0000-4000-t000-000000000002', 'trust001-0000-4000-t000-000000000003'),
  'is_blocked returns true for blocked pair (blocker → blocked)'
);

SELECT ok(
  public.is_blocked('trust001-0000-4000-t000-000000000003', 'trust001-0000-4000-t000-000000000002'),
  'is_blocked returns true for blocked pair (blocked → blocker, bidirectional)'
);

SELECT ok(
  NOT public.is_blocked('trust001-0000-4000-t000-000000000002', 'trust001-0000-4000-t000-000000000001'),
  'is_blocked returns false for non-blocked pair'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;
