-- ============================================================
-- pgTAP: Contact exchange schema correctness + lifecycle
-- Validates: BUG-002 (broadcast trigger), BUG-003 (VOLATILE),
--            BUG-004 (cleanup scheduler), consent flow, expiry
-- Run with: psql $DATABASE_URL -f tests/pgTAP/test_contact_exchange.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(16);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('cex00001-0000-4000-c000-000000000001', 'cex_alice@test.trombl.com', now(), now(), '{"display_name":"Alice"}'),
    ('cex00001-0000-4000-c000-000000000002', 'cex_bob@test.trombl.com',   now(), now(), '{"display_name":"Bob"}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- Give Alice contact info
UPDATE trombl_profiles
SET instagram_handle = 'alice_drift', whatsapp_number = '+441234567890'
WHERE id = 'cex00001-0000-4000-c000-000000000001';

-- Give Bob contact info
UPDATE trombl_profiles
SET instagram_handle = 'bob_drift'
WHERE id = 'cex00001-0000-4000-c000-000000000002';

-- Create accepted match
INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
VALUES (
  'cex_mtch-0000-4000-c000-000000000001',
  'cex00001-0000-4000-c000-000000000001',
  'cex00001-0000-4000-c000-000000000002',
  'accepted',
  now() + interval '24 hours'
);

-- ─── Schema: correct column names ────────────────────────────────────────────

SELECT has_column('drift_contact_exchange', 'initiator_contact_type',
  'drift_contact_exchange has initiator_contact_type column');

SELECT has_column('drift_contact_exchange', 'target_contact_type',
  'drift_contact_exchange has target_contact_type column');

SELECT hasnt_column('drift_contact_exchange', 'contact_type',
  'drift_contact_exchange does NOT have a generic contact_type column (BUG-002 validation)');

-- ─── Consent: initiator consents first ───────────────────────────────────────

INSERT INTO drift_contact_exchange (match_id, initiator_contact_type, initiator_consented)
VALUES (
  'cex_mtch-0000-4000-c000-000000000001',
  'instagram',
  true
);

SELECT ok(
  (SELECT initiator_consented FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') = true,
  'Initiator consent recorded correctly'
);

SELECT ok(
  (SELECT target_consented FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') = false,
  'Target consent still false after initiator-only consent'
);

SELECT ok(
  (SELECT reveal_at FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') IS NULL,
  'reveal_at not set when only one party consents'
);

-- ─── Consent: target consents → mutual consent triggers reveal window ─────────

UPDATE drift_contact_exchange
SET target_consented = true, target_contact_type = 'instagram'
WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001';

SELECT ok(
  (SELECT reveal_at FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') IS NOT NULL,
  'reveal_at set when both parties consent'
);

SELECT ok(
  (SELECT expires_at FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') IS NOT NULL,
  'expires_at set when both parties consent'
);

SELECT ok(
  (SELECT expires_at FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001')
  BETWEEN now() + interval '4 minutes' AND now() + interval '6 minutes',
  'Contact reveal window is approximately 5 minutes'
);

SELECT ok(
  (SELECT is_expired FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') = false,
  'Exchange not expired immediately after mutual consent'
);

-- ─── get_revealed_contact returns correct data during active window ───────────

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.get_revealed_contact(
      'cex_mtch-0000-4000-c000-000000000001',
      'cex00001-0000-4000-c000-000000000001'  -- Alice requests Bob's contact
    )
    WHERE revealed_contact_type = 'instagram'
      AND revealed_contact_value = 'bob_drift'
  ),
  'Alice can retrieve Bob''s instagram handle via get_revealed_contact'
);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.get_revealed_contact(
      'cex_mtch-0000-4000-c000-000000000001',
      'cex00001-0000-4000-c000-000000000002'  -- Bob requests Alice's contact
    )
    WHERE revealed_contact_type = 'instagram'
      AND revealed_contact_value = 'alice_drift'
  ),
  'Bob can retrieve Alice''s instagram handle via get_revealed_contact'
);

-- Third party gets nothing
SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.get_revealed_contact(
      'cex_mtch-0000-4000-c000-000000000001',
      gen_random_uuid()  -- random non-participant
    )
  ),
  'Non-participant gets no contact data from get_revealed_contact'
);

-- ─── Expiry: get_revealed_contact returns nothing after window ────────────────

UPDATE drift_contact_exchange
SET expires_at = now() - interval '1 second'
WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001';

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.get_revealed_contact(
      'cex_mtch-0000-4000-c000-000000000001',
      'cex00001-0000-4000-c000-000000000001'
    )
  ),
  'get_revealed_contact returns nothing when expires_at has passed'
);

SELECT ok(
  (SELECT is_expired FROM drift_contact_exchange
   WHERE match_id = 'cex_mtch-0000-4000-c000-000000000001') = true,
  'get_revealed_contact auto-marks is_expired=true when window passes (VOLATILE write)'
);

-- ─── expire_contact_exchanges() is callable (part of cleanup scheduler) ───────

SELECT ok(
  public.expire_contact_exchanges() >= 0,
  'expire_contact_exchanges() executes without error and returns a count'
);

-- ─── run_scheduled_cleanup() now includes exchange expiry (BUG-004 fix) ───────

SELECT ok(
  (SELECT public.run_scheduled_cleanup()) ? 'exchanges_expired',
  'run_scheduled_cleanup() result includes exchanges_expired key (BUG-004 regression)'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;
