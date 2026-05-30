# Trombl Backend — Manual QA Checklist

**Last updated:** 2026-05-15  
**Tested against:** `<your-project-id>.supabase.co` (live project)

---

## Pre-Flight Setup

- [ ] `.env.local` is populated with all required values
- [ ] `psql "$DATABASE_URL" -c "SELECT version();"` returns PostgreSQL 17.x
- [ ] JWT tokens minted: `eval "$(python3 tests/auth/mint_jwt.py --export)"`
- [ ] All 6 test users exist in `auth.users` (Alice, Bob, Carol, Dave, Eve, Mallory)
- [ ] Test data seeded (sessions, matches, stories, presence, locations)

---

## 1. Auth & JWT

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 1.1 | `curl -H "apikey: $ANON_KEY" $URL/rest/v1/trombl_profiles` returns 0 rows | 0 rows (unauthenticated) | |
| 1.2 | `curl -H "Authorization: Bearer $TOK_ALICE" -H "apikey: $ANON_KEY" $URL/rest/v1/trombl_profiles?select=id&limit=1` | 200 with rows | |
| 1.3 | Expired JWT (modify exp field) returns 401 from REST | 401 | |
| 1.4 | JWT with wrong secret fails at REST | 401 | |
| 1.5 | `python3 tests/auth/mint_jwt.py alice --hours 0.001` creates very-short-lived token | Token valid initially | |

---

## 2. Profile Management

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 2.1 | Alice can read her own profile | 200 | |
| 2.2 | Alice can read Bob's profile (public read) | 200 | |
| 2.3 | Alice can update her own `bio`, `display_name`, `vibe_tags` | 204 | |
| 2.4 | Alice CANNOT update Bob's profile (0 rows affected) | 204, 0 affected rows | |
| 2.5 | Username `AB` rejected (too short) | CHECK violation | |
| 2.6 | Username `has spaces` rejected | CHECK violation | |
| 2.7 | Username `HAS_CAPS` rejected | CHECK violation | |
| 2.8 | Username `valid_user` accepted | 204 | |
| 2.9 | Soft-deleted user profile hidden (`deleted_at IS NOT NULL`) | 0 rows via REST | |

---

## 3. Drift Sessions

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 3.1 | Alice's active session visible to Bob (`drift_sessions?status=eq.active`) | 1+ rows | |
| 3.2 | Carol's expired session invisible to Alice (not owner) | 0 rows | |
| 3.3 | Carol can see her own expired session via `select_own` policy | 1 row | |
| 3.4 | Alice cannot update Carol's session (0 rows affected) | 0 affected | |
| 3.5 | Session with `radius_km < 0.5` rejected | CHECK violation | |
| 3.6 | Session with `radius_km > 10.0` rejected | CHECK violation | |
| 3.7 | `vibe_note` > 200 chars rejected | CHECK violation | |
| 3.8 | `expire_pending_matches()` does not expire accepted sessions | accepted stays accepted | |

---

## 4. Geo & Discovery

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 4.1 | `find_nearby_users(51.508, -0.1276, 2.0, 50, alice_id)` returns Bob | Bob in results | |
| 4.2 | Alice not in her own nearby results | Alice excluded | |
| 4.3 | Eve (3.9km) not in 2km radius results | Eve excluded | |
| 4.4 | Users without active sessions not discoverable | Not visible | |
| 4.5 | `cleanup_expired_locations()` removes stale locations | 0 expired rows remain | |
| 4.6 | `refresh_location_expiry` trigger resets expires_at on every INSERT/UPDATE | expires_at = now()+15min | |
| 4.7 | Banned user not discoverable | Not visible | |
| 4.8 | `is_blocked` relationship hides user from discovery | Not visible | |

---

## 5. Matching

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 5.1 | Alice can see her match with Bob | 1 row | |
| 5.2 | Bob (target) can also see the Alice-Bob match | 1 row | |
| 5.3 | Carol cannot see Alice-Bob match (non-participant) | 0 rows | |
| 5.4 | Self-match rejected by CHECK constraint | Error | |
| 5.5 | Second match between same pair (accepted one pending) blocked by partial index | Unique violation | |
| 5.6 | Re-match after expiry works (BUG-001 regression) | Succeeds | |
| 5.7 | Match acceptance sets `accepted_at` and extends `expires_at` to ~24h | verified | |
| 5.8 | `expire_pending_matches()` sets expired match to `status=expired, end_reason=auto_expired` | verified | |
| 5.9 | Accepted match not expired by cleanup | accepted stays | |
| 5.10 | Trust score below `DRIFT_MIN_TRUST_SCORE_TO_MATCH` blocks match (edge fn) | 400 | |

---

## 6. Contact Exchange

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 6.1 | Alice-Bob exchange: both consented, not expired | is_expired=false | |
| 6.2 | Carol cannot see Alice-Bob exchange via REST | 0 rows | |
| 6.3 | One exchange record per match enforced | UNIQUE violation on duplicate | |
| 6.4 | `expire_contact_exchanges()` marks windows as expired | is_expired=true | |
| 6.5 | `get_revealed_contact()` requires both consented (edge fn) | 403 if not both consented | |
| 6.6 | Invalid contact_type (e.g. telegram) rejected by edge fn | 400 | |
| 6.7 | Valid types: instagram, whatsapp, phone | 200 | |
| 6.8 | INFO-003: notification expires 6min, window is 5min (known inconsistency) | noted | |

---

## 7. Stories & Reactions

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 7.1 | Alice's story visible to Bob (public feed) | 1 row | |
| 7.2 | Removed story (`is_removed=true`) invisible to others | 0 rows | |
| 7.3 | Soft-deleted story (`deleted_at IS NOT NULL`) invisible to others | 0 rows | |
| 7.4 | FIND-001: Flagged story still visible (known issue — add filter to RLS) | 1 row (visible) | |
| 7.5 | Alice cannot set `is_flagged=true` on own story (BUG-011 fix) | 403 | |
| 7.6 | Alice cannot set `is_removed=true` on own story | 403 | |
| 7.7 | Alice CAN update `vibe_tags` (allowed field) | 204 | |
| 7.8 | Story text > 140 chars rejected | 400 / CHECK | |
| 7.9 | Empty story text rejected | CHECK | |
| 7.10 | Reaction INSERT increments `reaction_count` via trigger | count+1 | |
| 7.11 | Reaction DELETE decrements `reaction_count` via trigger | count-1 | |
| 7.12 | Duplicate reaction blocked by UNIQUE constraint | ignored / conflict | |
| 7.13 | `reaction_count` cannot go below 0 (GREATEST guard) | 0 min | |

---

## 8. Trust & Safety

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 8.1 | New user trust score defaults to 75 | score=75 | |
| 8.2 | Report decrements trust score | score-5 | |
| 8.3 | Auto-ban triggers when score reaches threshold | is_banned=true | |
| 8.4 | Banned user cannot authenticate to API (edge fn guard) | 403 | |
| 8.5 | `recompute_trust_score` with 0 events = 75 | score=75 | |
| 8.6 | `is_blocked` relationship hides user from feeds | 0 rows | |
| 8.7 | Blocked user's stories not visible to blocker | 0 rows | |
| 8.8 | Valid report reasons accepted: harassment, fake_profile, spam, etc. | 200 | |
| 8.9 | `impersonation` reason rejected (BUG-008 fix) | 400 | |
| 8.10 | `other` reason requires `custom_reason` field | 400 if missing | |
| 8.11 | `custom_reason` > 500 chars rejected | 400 | |

---

## 9. Notifications

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 9.1 | Alice can see only her own notifications | self-only | |
| 9.2 | Alice cannot see Bob's notifications (0 rows) | 0 rows | |
| 9.3 | Alice can mark notification as read (`is_read=true`) | 204 | |
| 9.4 | Alice cannot change `type`, `title`, `body`, `data` (BUG-005 fix) | 403 | |
| 9.5 | Notification type enum matches DB: drift_match_request (not drift_match_received) | correct enum | |

---

## 10. Realtime

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 10.1 | WebSocket connection established | channel: SUBSCRIBED | |
| 10.2 | Subscribe `drift_presence` — receive UPDATE on presence heartbeat | INSERT/UPDATE event | |
| 10.3 | Subscribe `drift_sessions` — receive UPDATE on session status change | UPDATE event | |
| 10.4 | Subscribe `drift_matches?id=eq.X` — receive UPDATE on match status | UPDATE event | |
| 10.5 | Subscribe `drift_contact_exchange?match_id=eq.X` — receive INSERT/UPDATE | event | |
| 10.6 | Subscribe `drift_stories` — receive UPDATE on reaction_count change | UPDATE event | |
| 10.7 | `drift_user_locations` NOT in realtime (privacy: no live location tracking) | No channel | |
| 10.8 | `trombl_profiles` NOT in realtime (no live profile updates) | No channel | |
| 10.9 | Non-participant cannot subscribe to another user's match events (RLS) | 0 events | |

**Browser test:** Open `tests/realtime/test_realtime.html`, paste URL + keys, subscribe channels, then trigger events with test scripts.

---

## 11. Edge Functions

Run: `source backend/.env.local && eval "$(python3 tests/auth/mint_jwt.py --export)" && bash tests/http/test_edge_functions.sh`

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 11.1 | All functions reject anon key (no JWT sub) | 401 | |
| 11.2 | GET method rejected on POST-only functions | 405 | |
| 11.3 | `drift-create-session` missing body → 400 | 400 | |
| 11.4 | `drift-match-users` invalid UUID target_id → 400 | 400 | |
| 11.5 | `drift-contact-reveal/consent` invalid contact_type → 400 | 400 | |
| 11.6 | `drift-contact-reveal/reveal` non-existent match → 403 | 403 | |
| 11.7 | `drift-report-user` reason=impersonation → 400 (BUG-008) | 400 | |
| 11.8 | `drift-report-user` reason=fake_profile → proceeds to user lookup | 404 | |
| 11.9 | `drift-publish-story` empty text → 400 | 400 | |
| 11.10 | `drift-publish-story` text >140 chars → 400 | 400 | |
| 11.11 | CORS preflight (OPTIONS) → 200 | 200 | |

---

## 12. Cron Job

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 12.1 | `trombl-cleanup` function deployed to Supabase | Visible in dashboard | |
| 12.2 | Cron secret set: `supabase secrets set CRON_SECRET=<value>` | No error | |
| 12.3 | Manual cron trigger with correct secret → 200 | 200, JSON summary | |
| 12.4 | Manual cron trigger with wrong secret → 401 | 401 | |
| 12.5 | `run_scheduled_cleanup()` returns JSON with all keys | verified | |

---

## 13. Performance Spot Checks

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 13.1 | `EXPLAIN find_nearby_users(...)` uses GiST index | Index Scan on gist_idx | |
| 13.2 | `EXPLAIN SELECT * FROM drift_sessions WHERE status='active' AND city='London'` | Index scan, not seq scan | |
| 13.3 | `EXPLAIN SELECT * FROM drift_matches WHERE initiator_id=X AND status='pending'` | Index scan | |
| 13.4 | `EXPLAIN SELECT * FROM drift_stories WHERE city='London' ORDER BY published_at DESC LIMIT 20` | Index scan | |

---

## Known Issues (not blocking)

| ID | Description | Impact | Fix |
|----|-------------|--------|-----|
| FIND-001 | Flagged stories visible until removed | Safety UX | Add `AND is_flagged=false` to RLS |
| FIND-002 | `recompute_trust_score` always bases from 75 | Score accuracy | Document behavior |
| FIND-003 | Verify participant_count not double-counted | Data integrity | Check edge fn host insert behavior |
| BUG-010 | Session host can manually set `participant_count` | Fake popularity | Add trigger or generated column |
| INFO-003 | Notification expires 6min, window 5min | UX inconsistency | Change to `5/60` hours |
