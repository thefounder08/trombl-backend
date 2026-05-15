-- ============================================================
-- Geo Function Tests: PostGIS queries and spatial accuracy
-- Run with: psql $DATABASE_URL -f tests/geo/test_geo_functions.sql
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(12);

-- ─── Setup ───────────────────────────────────────────────────────────────────

DO $$
BEGIN
  INSERT INTO auth.users (id, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    ('geo00001-0000-4000-g000-000000000001', 'geo_alice@test.trombl.com', now(), now(), '{}'),
    ('geo00001-0000-4000-g000-000000000002', 'geo_bob@test.trombl.com',   now(), now(), '{}'),
    ('geo00001-0000-4000-g000-000000000003', 'geo_carol@test.trombl.com', now(), now(), '{}')
  ON CONFLICT (id) DO NOTHING;
END
$$;

-- Alice: London (51.5074° N, 0.1278° W)
PERFORM public.upsert_user_location('geo00001-0000-4000-g000-000000000001', 51.5074, -0.1278);

-- Bob: 1 km from Alice (approx 51.5164° N, same longitude)
PERFORM public.upsert_user_location('geo00001-0000-4000-g000-000000000002', 51.5164, -0.1278);

-- Carol: 5 km from Alice (approx 51.5524° N)
PERFORM public.upsert_user_location('geo00001-0000-4000-g000-000000000003', 51.5524, -0.1278);

-- Update openness so they appear in nearby searches
UPDATE trombl_profiles SET drift_openness = 'open' WHERE id IN (
  'geo00001-0000-4000-g000-000000000001',
  'geo00001-0000-4000-g000-000000000002',
  'geo00001-0000-4000-g000-000000000003'
);

-- ─── upsert_user_location ────────────────────────────────────────────────────

SELECT ok(
  EXISTS(
    SELECT 1 FROM drift_user_locations
    WHERE user_id = 'geo00001-0000-4000-g000-000000000001'
      AND expires_at > now()
  ),
  'upsert_user_location creates record with TTL'
);

SELECT ok(
  (
    SELECT expires_at - now() > interval '14 minutes'
    FROM drift_user_locations
    WHERE user_id = 'geo00001-0000-4000-g000-000000000001'
  ),
  'Location TTL is approximately 15 minutes'
);

-- ─── distance_km accuracy ────────────────────────────────────────────────────

-- Alice to Bob (~1 km)
SELECT ok(
  ABS(public.distance_km(51.5074, -0.1278, 51.5164, -0.1278) - 1.0) < 0.15,
  'distance_km: Alice to Bob is approximately 1 km'
);

-- Alice to Carol (~5 km)
SELECT ok(
  ABS(public.distance_km(51.5074, -0.1278, 51.5524, -0.1278) - 5.0) < 0.4,
  'distance_km: Alice to Carol is approximately 5 km'
);

-- ─── find_nearby_users: radius filtering ─────────────────────────────────────

-- Alice searches within 2 km: should find Bob but NOT Carol
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.find_nearby_users(
      'geo00001-0000-4000-g000-000000000001',
      51.5074, -0.1278, 2.0, NULL, 50
    ) WHERE user_id = 'geo00001-0000-4000-g000-000000000002'
  ),
  'find_nearby_users: Bob (1 km) found in 2 km radius'
);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.find_nearby_users(
      'geo00001-0000-4000-g000-000000000001',
      51.5074, -0.1278, 2.0, NULL, 50
    ) WHERE user_id = 'geo00001-0000-4000-g000-000000000003'
  ),
  'find_nearby_users: Carol (5 km) excluded from 2 km radius'
);

-- Alice searches within 10 km: should find both
SELECT ok(
  (
    SELECT COUNT(*) FROM public.find_nearby_users(
      'geo00001-0000-4000-g000-000000000001',
      51.5074, -0.1278, 10.0, NULL, 50
    ) WHERE user_id IN (
      'geo00001-0000-4000-g000-000000000002',
      'geo00001-0000-4000-g000-000000000003'
    )
  ) = 2,
  'find_nearby_users: Bob and Carol found in 10 km radius'
);

-- Self is never returned
SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.find_nearby_users(
      'geo00001-0000-4000-g000-000000000001',
      51.5074, -0.1278, 10.0, NULL, 50
    ) WHERE user_id = 'geo00001-0000-4000-g000-000000000001'
  ),
  'find_nearby_users: self is never returned'
);

-- ─── find_nearby_users: block filtering ──────────────────────────────────────

INSERT INTO trombl_blocked_users (blocker_id, blocked_id, is_system_block)
VALUES ('geo00001-0000-4000-g000-000000000001', 'geo00001-0000-4000-g000-000000000002', false)
ON CONFLICT DO NOTHING;

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.find_nearby_users(
      'geo00001-0000-4000-g000-000000000001',
      51.5074, -0.1278, 10.0, NULL, 50
    ) WHERE user_id = 'geo00001-0000-4000-g000-000000000002'
  ),
  'find_nearby_users: blocked users are excluded'
);

DELETE FROM trombl_blocked_users
WHERE blocker_id = 'geo00001-0000-4000-g000-000000000001'
  AND blocked_id = 'geo00001-0000-4000-g000-000000000002';

-- ─── find_nearby_users: solo mode filtering ───────────────────────────────────

UPDATE trombl_profiles SET drift_openness = 'solo'
WHERE id = 'geo00001-0000-4000-g000-000000000002';

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.find_nearby_users(
      'geo00001-0000-4000-g000-000000000001',
      51.5074, -0.1278, 10.0, NULL, 50
    ) WHERE user_id = 'geo00001-0000-4000-g000-000000000002'
  ),
  'find_nearby_users: solo-mode users are excluded'
);

UPDATE trombl_profiles SET drift_openness = 'open'
WHERE id = 'geo00001-0000-4000-g000-000000000002';

-- ─── cleanup_expired_locations ───────────────────────────────────────────────

UPDATE drift_user_locations
SET expires_at = now() - interval '1 minute'
WHERE user_id = 'geo00001-0000-4000-g000-000000000003';

PERFORM public.cleanup_expired_locations();

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM drift_user_locations
    WHERE user_id = 'geo00001-0000-4000-g000-000000000003'
  ),
  'cleanup_expired_locations removes expired location records'
);

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;
