# Trombl Backend — Local Testing Guide

**Stack:** Live Supabase project (`&lt;your-project-id&gt;.supabase.co`)  
**No Docker required** — all tests run against the real remote Supabase instance via `DATABASE_URL` and REST API.

---

## Quick Start (2 minutes)

```bash
# 1. Load env variables
source backend/.env.local

# 2. Verify DB connection
psql "$DATABASE_URL" -c "SELECT version();"
# Expected: PostgreSQL 17.x

# 3. Mint JWT tokens for test users
eval "$(python3 tests/auth/mint_jwt.py --export)"
# Sets TOK_ALICE, TOK_BOB, TOK_CAROL, TOK_DAVE, TOK_EVE, TOK_MALLORY

# 4. Run all automated tests
bash tests/geo/test_geo_queries.sh
bash tests/rls/test_rls_live.sh
bash tests/realtime/test_realtime_ws.sh
bash tests/scenarios/test_contact_exchange.sh
bash tests/scenarios/test_story_moderation.sh
bash tests/scenarios/test_expiry_systems.sh
```

---

## Test Users

Pre-seeded in `auth.users` and `trombl_profiles`:

| Name | UUID | Email | Role |
|------|------|-------|------|
| Alice | `aaaaaaaa-0001-4000-a000-000000000001` | alice@trombl-qa.dev | Session host, match initiator |
| Bob | `aaaaaaaa-0002-4000-a000-000000000002` | bob@trombl-qa.dev | Match target |
| Carol | `aaaaaaaa-0003-4000-a000-000000000003` | carol@trombl-qa.dev | Expired session host |
| Dave | `aaaaaaaa-0004-4000-a000-000000000004` | dave@trombl-qa.dev | Match target |
| Eve | `aaaaaaaa-0005-4000-a000-000000000005` | eve@trombl-qa.dev | Out-of-radius user |
| Mallory | `aaaaaaaa-0006-4000-a000-000000000006` | mallory@trombl-qa.dev | Adversarial / flagged content |

**Mint fresh tokens at any time:**
```bash
# All users (24h tokens)
eval "$(python3 tests/auth/mint_jwt.py --export)"

# Single user with custom TTL
python3 tests/auth/mint_jwt.py alice --hours 1 --export

# Print raw tokens (not export)
python3 tests/auth/mint_jwt.py
```

---

## Test Data Reference

| Resource | ID | Description |
|----------|----|-------------|
| Alice's session | `a1000001-0000-4000-a000-000000000001` | Active coffee session, Central London |
| Bob's session | `a1000002-0000-4000-a000-000000000002` | Active walk session, Soho |
| Carol's session | `a1000003-0000-4000-a000-000000000003` | Expired reading session |
| Alice-Bob match | `a2000001-0000-4000-a000-000000000001` | Accepted, mutual consent |
| Carol-Dave match | `a2000002-0000-4000-a000-000000000002` | Pending |
| Alice-Bob exchange | `a3000001-0000-4000-a000-000000000001` | Both consented, instagram |
| Alice's story | `a4000001-0000-4000-a000-000000000001` | Coffee story, 2 reactions |
| Bob's story | `a4000002-0000-4000-a000-000000000002` | Photo story, 2 reactions |
| Mallory's story | `a4000005-0000-4000-a000-000000000006` | Flagged (threatening content) |

---

## Test Locations (London area)

| User | Lat | Lon | Distance from Alice |
|------|-----|-----|---------------------|
| Alice | 51.5080 | -0.1276 | — (British Museum) |
| Bob | 51.5074 | -0.1241 | ~0.25 km |
| Carol | 51.5074 | -0.1204 | ~0.55 km |
| Dave | 51.5082 | -0.1167 | ~0.85 km |
| Eve | 51.5220 | -0.0786 | ~3.74 km (outside 2km radius) |
| Mallory | 51.5000 | -0.1100 | ~0.90 km |

---

## Automated Test Suite

### Geo Tests
```bash
set -a && source backend/.env.local && set +a
bash tests/geo/test_geo_queries.sh
# Expected: 9 passed, 0 failed
# Tests: PostGIS distances, find_nearby_users RPC, location TTL, boundary conditions
```

### RLS Live Tests
```bash
source backend/.env.local
eval "$(python3 tests/auth/mint_jwt.py --export)"
bash tests/rls/test_rls_live.sh
# Expected: 21 passed, 0 failed
# Tests: Profile/session/match/story/notification/presence RLS via REST API
```

### Realtime Tests
```bash
source backend/.env.local
eval "$(python3 tests/auth/mint_jwt.py --export)"
bash tests/realtime/test_realtime_ws.sh
# Expected: 15 passed, 0 failed
# Tests: Publication membership, API reachability, trigger → event flow
```

### Contact Exchange Scenarios
```bash
source backend/.env.local
eval "$(python3 tests/auth/mint_jwt.py --export)"
bash tests/scenarios/test_contact_exchange.sh
# Expected: 9 passed, 0 failed
# Tests: Consent state, RLS isolation, expiry, unique constraint
```

### Story Moderation Scenarios
```bash
source backend/.env.local
eval "$(python3 tests/auth/mint_jwt.py --export)"
bash tests/scenarios/test_story_moderation.sh
# Expected: 12 passed, 0 failed
# Tests: Flagging, removal, self-mod blocks, reaction triggers, constraints
```

### Expiry System Tests
```bash
source backend/.env.local
bash tests/scenarios/test_expiry_systems.sh
# Expected: 16 passed, 0 failed
# Tests: expire_pending_matches, expire_contact_exchanges, cleanup_stale_presence,
#         cleanup_old_stories, run_scheduled_cleanup orchestrator
```

### Edge Function HTTP Tests
```bash
source backend/.env.local
eval "$(python3 tests/auth/mint_jwt.py --export)"
SUPABASE_URL="$SUPABASE_URL" ANON_KEY="$SUPABASE_ANON_KEY" \
  USER_A_TOKEN="$TOK_ALICE" USER_B_TOKEN="$TOK_BOB" \
  bash tests/http/test_edge_functions.sh
# Requires edge functions deployed to Supabase
```

### pgTAP SQL Tests (require psql + pgtap extension)
```bash
source backend/.env.local
psql "$DATABASE_URL" -f tests/pgTAP/test_rematch_after_expiry.sql
psql "$DATABASE_URL" -f tests/pgTAP/test_contact_exchange.sql
psql "$DATABASE_URL" -f tests/pgTAP/test_rls_attacks.sql
psql "$DATABASE_URL" -f tests/pgTAP/test_edge_cases.sql
psql "$DATABASE_URL" -f tests/rls/test_rls_drift.sql
psql "$DATABASE_URL" -f tests/rls/test_rls_platform.sql
psql "$DATABASE_URL" -f tests/geo/test_geo_functions.sql
psql "$DATABASE_URL" -f tests/functions/test_trust_safety.sql
```

---

## Realtime Browser Testing

1. Open `tests/realtime/test_realtime.html` in Chrome/Firefox
2. Fill in:
   - **Supabase URL:** `https://&lt;your-project-id&gt;.supabase.co`
   - **Anon Key:** value of `$SUPABASE_ANON_KEY`
   - **JWT Token:** output of `python3 tests/auth/mint_jwt.py alice`
3. Click **Connect**, then subscribe to desired channels
4. Trigger events by running test scripts in a terminal:

```bash
# Trigger presence event
psql "$DATABASE_URL" -c "UPDATE drift_presence SET last_seen_at = now() WHERE user_id = 'aaaaaaaa-0001-4000-a000-000000000001';"

# Trigger story reaction event (reaction_count UPDATE on drift_stories)
psql "$DATABASE_URL" -c "
  INSERT INTO drift_story_reactions (story_id, user_id, reaction_type)
  VALUES ('a4000001-0000-4000-a000-000000000001', 'aaaaaaaa-0005-4000-a000-000000000005', 'wave')
  ON CONFLICT DO NOTHING;
"

# Trigger match status event
psql "$DATABASE_URL" -c "UPDATE drift_matches SET updated_at = now() WHERE id = 'a2000001-0000-4000-a000-000000000001';"
```

---

## Running Specific RLS Checks Manually

```bash
source backend/.env.local
eval "$(python3 tests/auth/mint_jwt.py --export)"

BASE="$SUPABASE_URL/rest/v1"
APIKEY="$SUPABASE_ANON_KEY"

# Read Bob's profile as Alice (should succeed — public read)
curl -s -H "Authorization: Bearer $TOK_ALICE" -H "apikey: $APIKEY" \
  "$BASE/trombl_profiles?id=eq.aaaaaaaa-0002-4000-a000-000000000002" | python3 -m json.tool

# Try to flag Alice's story as Alice (should fail — 403)
curl -s -X PATCH \
  -H "Authorization: Bearer $TOK_ALICE" -H "apikey: $APIKEY" \
  -H "Content-Type: application/json" \
  "$BASE/drift_stories?id=eq.a4000001-0000-4000-a000-000000000001" \
  -d '{"is_flagged": true}'
# Expected: {"code":"42501","message":"new row violates row-level security..."}

# Read Alice-Bob match as Carol (should return empty — 0 rows)
curl -s -H "Authorization: Bearer $TOK_CAROL" -H "apikey: $APIKEY" \
  "$BASE/drift_matches?id=eq.a2000001-0000-4000-a000-000000000001"
# Expected: []
```

---

## Reseed Test Data

If test data gets corrupted or cleaned up:

```bash
source backend/.env.local

# Re-run seed SQL (idempotent — uses ON CONFLICT DO NOTHING)
psql "$DATABASE_URL" << 'EOF'
-- Sessions
INSERT INTO drift_sessions (id, host_user_id, activity_type_id, openness, timeframe, vibe_note, vibe_tags, status, radius_km, location_snapshot, city, country_code, participant_count, started_at, expires_at)
VALUES
  ('a1000001-0000-4000-a000-000000000001', 'aaaaaaaa-0001-4000-a000-000000000001', '74a86e09-1d87-45da-bb47-8d2d73bf0955', 'open', 'right_now', 'Reading in the courtyard', ARRAY['coffee','chill'], 'active', 2.0, ST_SetSRID(ST_MakePoint(-0.1276, 51.5199), 4326), 'London', 'GB', 2, now() - interval '30 minutes', now() + interval '90 minutes'),
  ('a1000002-0000-4000-a000-000000000002', 'aaaaaaaa-0002-4000-a000-000000000002', '9e85541c-7ec9-4beb-a373-d7b1c80a4566', 'maybe', 'in_30_min', 'Taking photos', ARRAY['walk','photography'], 'active', 2.0, ST_SetSRID(ST_MakePoint(-0.1337, 51.5133), 4326), 'London', 'GB', 1, now() - interval '45 minutes', now() + interval '75 minutes'),
  ('a1000003-0000-4000-a000-000000000003', 'aaaaaaaa-0003-4000-a000-000000000003', '15db21bd-ad95-4f60-9dd9-72dd87b71f03', 'open', 'right_now', NULL, ARRAY['reading'], 'expired', 2.0, ST_SetSRID(ST_MakePoint(-0.1184, 51.5074), 4326), 'London', 'GB', 1, now() - interval '3 hours', now() - interval '1 hour')
ON CONFLICT (id) DO NOTHING;

-- Matches
INSERT INTO drift_matches (id, session_id, initiator_id, target_id, status, initiated_at, accepted_at, expires_at)
VALUES
  ('a2000001-0000-4000-a000-000000000001', 'a1000001-0000-4000-a000-000000000001', 'aaaaaaaa-0001-4000-a000-000000000001', 'aaaaaaaa-0002-4000-a000-000000000002', 'accepted', now() - interval '20 minutes', now() - interval '18 minutes', now() + interval '23 hours 40 minutes'),
  ('a2000002-0000-4000-a000-000000000002', NULL, 'aaaaaaaa-0003-4000-a000-000000000003', 'aaaaaaaa-0004-4000-a000-000000000004', 'pending', now() - interval '5 minutes', NULL, now() + interval '5 minutes')
ON CONFLICT (id) DO NOTHING;

-- Contact Exchange
INSERT INTO drift_contact_exchange (id, match_id, initiator_consented, target_consented, initiator_contact_type, target_contact_type, reveal_at, expires_at, is_expired)
VALUES ('a3000001-0000-4000-a000-000000000001', 'a2000001-0000-4000-a000-000000000001', true, true, 'instagram', 'instagram', now() - interval '15 minutes', now() + interval '5 minutes', false)
ON CONFLICT (id) DO NOTHING;

-- Stories
INSERT INTO drift_stories (id, user_id, emoji, text, city, country_code, activity_tag, vibe_tags, is_flagged, is_removed, published_at)
VALUES
  ('a4000001-0000-4000-a000-000000000001', 'aaaaaaaa-0001-4000-a000-000000000001', '☕', 'Found the best espresso in Bloomsbury — the light through the glass roof is perfect right now', 'London', 'GB', 'Coffee', ARRAY['cozy','spontaneous'], false, false, now() - interval '25 minutes'),
  ('a4000002-0000-4000-a000-000000000002', 'aaaaaaaa-0002-4000-a000-000000000002', '📷', 'Soho at golden hour is something else. Anyone else out shooting?', 'London', 'GB', 'Walk', ARRAY['creative','golden_hour'], false, false, now() - interval '40 minutes'),
  ('a4000003-0000-4000-a000-000000000003', 'aaaaaaaa-0003-4000-a000-000000000003', '📖', 'Halfway through my book, really getting into it', 'London', 'GB', 'Reading', ARRAY['quiet','focused'], false, false, now() - interval '2 hours'),
  ('a4000004-0000-4000-a000-000000000004', 'aaaaaaaa-0004-4000-a000-000000000004', '🎵', 'Jazz bar just opened up near me, free entry till 7', 'London', 'GB', NULL, ARRAY['music','chill'], false, false, now() - interval '10 minutes'),
  ('a4000005-0000-4000-a000-000000000006', 'aaaaaaaa-0006-4000-a000-000000000006', '😡', 'Meet me alone I know where you live', 'London', 'GB', NULL, ARRAY[]::text[], true, false, now() - interval '5 minutes')
ON CONFLICT (id) DO NOTHING;

-- Story Reactions
INSERT INTO drift_story_reactions (story_id, user_id, reaction_type) VALUES
  ('a4000001-0000-4000-a000-000000000001', 'aaaaaaaa-0002-4000-a000-000000000002', 'heart'),
  ('a4000001-0000-4000-a000-000000000001', 'aaaaaaaa-0003-4000-a000-000000000003', 'spark'),
  ('a4000002-0000-4000-a000-000000000002', 'aaaaaaaa-0001-4000-a000-000000000001', 'heart'),
  ('a4000002-0000-4000-a000-000000000002', 'aaaaaaaa-0004-4000-a000-000000000004', 'wave'),
  ('a4000004-0000-4000-a000-000000000004', 'aaaaaaaa-0001-4000-a000-000000000001', 'spark'),
  ('a4000004-0000-4000-a000-000000000004', 'aaaaaaaa-0002-4000-a000-000000000002', 'heart')
ON CONFLICT DO NOTHING;

-- Locations
INSERT INTO drift_user_locations (user_id, location, latitude, longitude, accuracy_meters, city, country_code, expires_at)
VALUES
  ('aaaaaaaa-0001-4000-a000-000000000001', ST_SetSRID(ST_MakePoint(-0.1276, 51.508), 4326),  51.508,  -0.1276, 15, 'London', 'GB', now() + interval '15 minutes'),
  ('aaaaaaaa-0002-4000-a000-000000000002', ST_SetSRID(ST_MakePoint(-0.1241, 51.5074), 4326), 51.5074, -0.1241, 20, 'London', 'GB', now() + interval '15 minutes'),
  ('aaaaaaaa-0003-4000-a000-000000000003', ST_SetSRID(ST_MakePoint(-0.1204, 51.5074), 4326), 51.5074, -0.1204, 10, 'London', 'GB', now() + interval '15 minutes'),
  ('aaaaaaaa-0004-4000-a000-000000000004', ST_SetSRID(ST_MakePoint(-0.1167, 51.5082), 4326), 51.5082, -0.1167, 25, 'London', 'GB', now() + interval '15 minutes'),
  ('aaaaaaaa-0005-4000-a000-000000000005', ST_SetSRID(ST_MakePoint(-0.0786, 51.522), 4326),  51.522,  -0.0786, 30, 'London', 'GB', now() + interval '15 minutes'),
  ('aaaaaaaa-0006-4000-a000-000000000006', ST_SetSRID(ST_MakePoint(-0.1100, 51.5000), 4326), 51.5000, -0.1100, 18, 'London', 'GB', now() + interval '15 minutes')
ON CONFLICT (user_id) DO UPDATE SET location = EXCLUDED.location, latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude, expires_at = now() + interval '15 minutes';

-- Presence
INSERT INTO drift_presence (user_id, session_id, is_online, last_seen_at)
VALUES
  ('aaaaaaaa-0001-4000-a000-000000000001', 'a1000001-0000-4000-a000-000000000001', true, now() - interval '1 minute'),
  ('aaaaaaaa-0002-4000-a000-000000000002', 'a1000002-0000-4000-a000-000000000002', true, now() - interval '3 minutes'),
  ('aaaaaaaa-0003-4000-a000-000000000003', NULL, false, now() - interval '2 hours'),
  ('aaaaaaaa-0004-4000-a000-000000000004', NULL, true, now() - interval '30 seconds')
ON CONFLICT (user_id) DO UPDATE SET session_id = EXCLUDED.session_id, is_online = EXCLUDED.is_online, last_seen_at = EXCLUDED.last_seen_at;
EOF
```

---

## Key Debugging Queries

```sql
-- Check all test data
SELECT 'sessions', count(*) FROM drift_sessions WHERE id LIKE 'a1%'
UNION ALL SELECT 'matches', count(*) FROM drift_matches WHERE id LIKE 'a2%'
UNION ALL SELECT 'exchanges', count(*) FROM drift_contact_exchange WHERE id LIKE 'a3%'
UNION ALL SELECT 'stories', count(*) FROM drift_stories WHERE id LIKE 'a4%'
UNION ALL SELECT 'locations', count(*) FROM drift_user_locations;

-- Verify location expiry
SELECT user_id, expires_at, expires_at > now() AS is_fresh
FROM drift_user_locations ORDER BY user_id;

-- Check trust scores
SELECT user_id, score FROM drift_trust_scores
WHERE user_id IN ('aaaaaaaa-0001-4000-a000-000000000001', 'aaaaaaaa-0002-4000-a000-000000000002');

-- Find all active sessions with participant counts
SELECT s.id, p.display_name as host, s.status, s.participant_count, s.expires_at
FROM drift_sessions s JOIN trombl_profiles p ON p.id = s.host_user_id
ORDER BY s.created_at DESC LIMIT 10;

-- Check RLS policy definitions on a table
SELECT policyname, cmd, qual, with_check
FROM pg_policies WHERE tablename = 'drift_stories';
```

---

## Trigger-Bypass Pattern (for tests only)

When a BEFORE trigger blocks direct manipulation (like `refresh_location_expiry`):

```sql
SET session_replication_role = 'replica';  -- disable triggers
-- your INSERT/UPDATE here
SET session_replication_role = 'origin';   -- re-enable
```

Used in: `tests/geo/test_geo_queries.sh` to test `cleanup_expired_locations()`.

---

## Bugs Found During Live Testing

| Bug | File | Description | Status |
|-----|------|-------------|--------|
| BUG-001 | 00007 | `unique_active_match` blocked re-matches | Fixed in 00014 |
| BUG-002 | 00013 | `broadcast_contact_exchange_update` refs non-existent column | Fixed in 00014 |
| BUG-003 | 00007 | `get_revealed_contact` declared STABLE but writes | Fixed in 00014 |
| BUG-004 | 00013 | `expire_contact_exchanges()` not called in cleanup | Fixed in 00014 |
| BUG-005 | 00011 | Notifications RLS too permissive | Fixed in 00014 |
| BUG-006 | contact-reveal/index.ts | `contact_type` column doesn't exist | Fixed |
| BUG-007 | notifications.ts | `drift_match_received` not in enum | Fixed |
| BUG-008 | drift-report-user | `impersonation` not in enum | Fixed |
| BUG-011 | 00014 | Stories UPDATE RLS infinite recursion | Fixed in 00015 |
| FIND-001 | 00012 | Flagged stories still visible | Open (document) |
| BUG-010 | 00012 | Session host can set arbitrary `participant_count` | Open |

---

## Environment Variables Reference

| Variable | Tier | Purpose |
|----------|------|---------|
| `SUPABASE_URL` | Client-safe | REST/Realtime base URL |
| `SUPABASE_ANON_KEY` | Client-safe | Public key for JWT + RLS |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-only | Bypasses RLS |
| `DATABASE_URL` | Server-only | Direct PostgreSQL connection |
| `SUPABASE_JWT_SECRET` | Server-only | Signs/verifies auth tokens |
| `CRON_SECRET` | Cron-only | Authorizes cleanup cron |
| `FCM_SERVICE_ACCOUNT_JSON` | Server-only | Push notifications |
