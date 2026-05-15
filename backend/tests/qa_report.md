# Trombl Backend — QA Report

**Date:** 2026-05-15 (updated with live testing findings)  
**Scope:** Static analysis of all 15 migrations + 6 Edge Functions + live REST/SQL testing  
**Testing:** Against live Supabase project (`<your-project-id>.supabase.co`)

---

## Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 7 | 7 |
| High | 4 | 3 |
| Medium | 4 | 0 (documented) |
| Info | 3 | — |

BUG-001 through BUG-008 are fixed in migration `00014_qa_bug_fixes.sql` and updated Edge Function files.  
BUG-011 is fixed in migration `00015_fix_stories_rls_recursion.sql` (found during live testing).

---

## Critical Bugs (break core functionality)

### BUG-001 · `unique_active_match` blocks all re-matches after expiry

**File:** `00007_drift_matching_tables.sql`  
**Type:** Schema bug — permanent data loss of UX capability

**Description:**  
The constraint `CONSTRAINT unique_active_match UNIQUE (initiator_id, target_id)` on `drift_matches` is a hard table-level uniqueness constraint. `expire_pending_matches()` updates status to `'expired'` but never deletes rows. Because the expired row remains, any second match attempt between the same pair hits the constraint and fails with a PostgreSQL unique violation error. **Users can never rematch with someone they previously matched with**, regardless of outcome (expired, declined, completed).

**Reproduction:**
```sql
-- Alice → Bob: first match
INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
VALUES ('alice-uuid', 'bob-uuid', 'pending', now() + interval '10 min');

-- First match expires
UPDATE drift_matches SET status = 'expired' WHERE initiator_id = 'alice-uuid';

-- Second attempt → FAILS with unique constraint violation
INSERT INTO drift_matches (initiator_id, target_id, status, expires_at)
VALUES ('alice-uuid', 'bob-uuid', 'pending', now() + interval '10 min');
```

**Fix:** `00014_qa_bug_fixes.sql`
- Drop the hard UNIQUE constraint
- Replace with `CREATE UNIQUE INDEX ... WHERE status IN ('pending', 'accepted')` — a partial index that scopes uniqueness to only active states

---

### BUG-002 · `broadcast_contact_exchange_update` trigger references non-existent column

**File:** `00013_realtime_and_indexes.sql`  
**Type:** Runtime crash — blocks the entire contact exchange flow

**Description:**  
The trigger function `broadcast_contact_exchange_update()` references `NEW.contact_type` in its `json_build_object` call. The `drift_contact_exchange` table does **not** have a `contact_type` column — the actual columns are `initiator_contact_type` and `target_contact_type`. This means **every INSERT or UPDATE to `drift_contact_exchange` causes the trigger to error**, effectively blocking the entire contact consent and reveal flow.

**Fix:** `00014_qa_bug_fixes.sql`
- Replace `NEW.contact_type` with `NEW.initiator_contact_type` and `NEW.target_contact_type`

---

### BUG-003 · `get_revealed_contact` declared `STABLE` but performs a write

**File:** `00007_drift_matching_tables.sql`  
**Type:** Semantic bug — potential query planner corruption

**Description:**  
The function `get_revealed_contact` is declared `LANGUAGE plpgsql STABLE SECURITY DEFINER` but internally executes `UPDATE drift_contact_exchange SET is_expired = true ...`. PostgreSQL's `STABLE` declaration means "this function reads the database but does not modify it." Declaring a write-performing function as STABLE can cause the query planner to:
- Inline the function in ways that skip the write
- Call the function multiple times (memoization assumptions)
- Produce unpredictable results under parallel query plans

**Fix:** `00014_qa_bug_fixes.sql`
- Changed function volatility from `STABLE` to `VOLATILE`

---

### BUG-004 · `expire_contact_exchanges()` not called in `run_scheduled_cleanup()`

**File:** `00013_realtime_and_indexes.sql`  
**Type:** Data leak — contact reveal windows never auto-expire via scheduler

**Description:**  
The cleanup orchestrator `run_scheduled_cleanup()` calls: `cleanup_expired_locations()`, `expire_pending_matches()`, `cleanup_old_stories()`, `cleanup_stale_presence()`. The function `expire_contact_exchanges()` is defined but **never called**. Contact reveal windows (5 minutes after mutual consent) will remain marked `is_expired = false` indefinitely unless `get_revealed_contact()` is called on that specific record (which writes expiry lazily). An expired window that is never accessed stays queryable as active.

**Fix:** `00014_qa_bug_fixes.sql`
- Added `SELECT public.expire_contact_exchanges() INTO v_exchanges_expired;` to the orchestrator
- Added `exchanges_expired` key to the returned JSONB summary

---

### BUG-005 · Notification `UPDATE` RLS allows overwriting all fields

**File:** `00011_rls_platform.sql`  
**Type:** Security bug — content spoofing

**Description:**  
The `notifications_update_own` policy's `WITH CHECK` only verifies `user_id = auth.uid()`. Users can `UPDATE` their own notifications to change any field — including `type` (escalating to `'safety_alert'`), `title`, `body`, and `data`. A malicious user could, for example, change a `'system'` notification to `'safety_alert'` to manipulate their notification center display, or modify `data.match_id` to point to a different match.

**Fix:** `00014_qa_bug_fixes.sql`
- Added subquery checks in `WITH CHECK` that assert `type`, `title`, `body`, `data`, and `created_at` must match their current stored values (users can only change `is_read` and `read_at`)

---

### BUG-006 · `contact_type` column name mismatch in Edge Function

**File:** `drift-contact-reveal/index.ts`  
**Type:** Runtime crash — contact consent always returns 500

**Description:**  
The Edge Function inserts with payload `{ match_id, contact_type, [consentField]: true }` — but the table has no `contact_type` column. The actual column names are `initiator_contact_type` and `target_contact_type`. Every `/consent` call results in a PostgREST 400 "column not found" error, surfaced as a 500 to the client. The entire contact exchange feature was non-functional.

Additionally, the consent flow used a SELECT-then-INSERT/UPDATE pattern, creating a race condition: two simultaneous consent calls (initiator and target consenting at the same moment) would both see `existing = null` and both attempt INSERT, with the second hitting the `UNIQUE (match_id)` constraint and failing.

**Fix:** `drift-contact-reveal/index.ts`
- Replaced SELECT→INSERT/UPDATE with a single atomic `upsert({ onConflict: 'match_id' })` call
- Used `isInitiator ? 'initiator_contact_type' : 'target_contact_type'` to select the correct column

---

## High Severity Bugs

### BUG-007 · `'drift_match_received'` not in `trombl_notification_type` enum

**File:** `drift-match-users/index.ts`, `_shared/notifications.ts`  
**Type:** Runtime crash — match notifications always fail

**Description:**  
The TypeScript `NotificationType` union and the call site in `drift-match-users` used `'drift_match_received'`. The DB enum (`00002_enums.sql`) has `'drift_match_request'`. Every match request notification insert fails with PostgreSQL error: `invalid input value for enum trombl_notification_type: "drift_match_received"`.

Additional mismatches in the original TS type:
- `'drift_match_expired'` → not in DB enum
- `'drift_session_joined'` → not in DB enum
- `'drift_report_resolved'` → not in DB enum
- `'trombl_system'` → DB enum has `'system'`

**Fix:**
- Updated `NotificationType` in `notifications.ts` to exactly match the DB enum values
- Updated call site in `drift-match-users/index.ts`: `'drift_match_received'` → `'drift_match_request'`

---

### BUG-008 · `'impersonation'` report reason not in DB enum

**File:** `drift-report-user/index.ts`  
**Type:** Runtime crash — impersonation reports always fail

**Description:**  
The Edge Function accepts `'impersonation'` as a valid report reason and includes it in `VALID_REASONS`. The DB enum `drift_report_reason` does not have `'impersonation'` — it has `'fake_profile'`. Any report submitted with `reason: 'impersonation'` passes Edge Function validation but fails at DB insert with `invalid input value for enum drift_report_reason: "impersonation"`.

**Fix:** `drift-report-user/index.ts`
- Changed `'impersonation'` → `'fake_profile'` in both the TypeScript type and `VALID_REASONS`

---

### BUG-009 · Contact consent race condition (SELECT + INSERT not atomic)

**Covered by BUG-006 fix above.** Documented here for tracking.

---

### BUG-010 · Session host can set arbitrary `participant_count` via UPDATE RLS

**File:** `00012_rls_drift.sql`  
**Type:** Data integrity — inflated participant counts

**Description:**  
The `sessions_update_own` RLS policy allows the session host to UPDATE any field on their session, including `participant_count`. The policy comment says "Prevent escalating participant_count manually" but no actual constraint enforces this. A malicious host could set `participant_count = 9999` to appear more popular in discovery feeds.

**Recommendation (not auto-fixed — requires schema change):**  
Add a WITH CHECK that asserts `participant_count` matches the trigger-computed value:
```sql
AND participant_count = (SELECT s.participant_count FROM drift_sessions s WHERE s.id = drift_sessions.id)
```
Or better: add a GENERATED column / trigger that prevents direct writes to `participant_count`.

---

---

### BUG-011 · `stories_update_own` RLS WITH CHECK causes infinite recursion

**File:** `00014_qa_bug_fixes.sql` (introduced by BUG-005 fix)  
**Type:** Critical — any story UPDATE returns PostgreSQL error 42P17  
**Found during:** Live REST API testing (2026-05-15)

**Description:**  
The BUG-005 fix added a `WITH CHECK` that subqueries `drift_stories` to verify `is_flagged` and `is_removed` have not changed:
```sql
WITH CHECK (
  user_id = auth.uid() AND
  is_flagged = (SELECT s.is_flagged FROM drift_stories s WHERE s.id = drift_stories.id) AND
  is_removed = (SELECT s.is_removed FROM drift_stories s WHERE s.id = drift_stories.id)
)
```
This subquery triggers PostgreSQL's RLS policy evaluation for the same table that is being updated, causing `ERROR 42P17: infinite recursion detected in policy for relation "drift_stories"`. Every story UPDATE (even allowed fields like `vibe_tags`) returns a 500.

**Fix:** `00015_fix_stories_rls_recursion.sql`
- Added SECURITY DEFINER function `get_story_protected_fields(uuid)` that reads from `drift_stories` without triggering RLS
- Rewrote `stories_update_own` WITH CHECK to call this function instead of using an inline subquery

---

## Medium Severity Findings

### FIND-001 · Flagged stories visible to users

`stories_select_public` RLS filters `is_removed = false` but not `is_flagged = false`. Flagged stories remain visible in the public feed until moderation action removes them. This is a minor UX/safety issue — flagged stories should arguably be hidden from the feed while under review.

**Recommendation:** Add `AND is_flagged = false` to the stories SELECT policy, or handle in the client.

---

### FIND-002 · `recompute_trust_score` always bases from hardcoded 75

The formula `v_score := GREATEST(0, LEAST(100, 75 + v_positive - v_negative))` always starts from 75 regardless of the user's current score. Running `recompute_trust_score` after a user has built up a good score (e.g., 95) would reset them toward 75. The trigger-based immediate update (score -= 5 on report) is the "live" signal; `recompute_trust_score` is the full recalculation. Since the formula is designed to compute from raw event counts (not accumulated deltas), starting from 75 is intentional — but the behavior may surprise: a user with 10 successful drifts and 0 reports scores `75 + 20 = 95` via recompute, but the immediate trigger fires can push it below that between recomputes.

**Recommendation:** Document this behavior clearly in the function comment.

---

### FIND-003 · `participant_count DEFAULT 1` + trigger potential double-count

`drift_sessions.participant_count` defaults to `1` (host counted implicitly at creation). The trigger `update_session_participant_count()` increments on INSERT to `drift_session_participants`. If the host's `drift_create_session` edge function also inserts a row for the host in `drift_session_participants`, the count becomes 2 immediately. Verify that `drift-create-session` does **not** insert the host into `drift_session_participants`.

---

### FIND-004 · `expire_contact_exchanges()` was missing from scheduler (fixed in BUG-004)

---

## Info / Design Notes

### INFO-001 · `find_nearby_users` requires active session

The `find_nearby_users()` function INNER JOINs `drift_sessions`. Users who have shared their location but don't have an active session are invisible in discovery. This appears intentional (drift is session-first) but means a user whose session just expired is instantly invisible even if they're physically nearby.

### INFO-002 · Story `user_id` visible in raw table reads

RLS does not column-mask `drift_stories.user_id`. Any client with a valid JWT can SELECT `user_id` from stories they can read. The API layer is expected to strip this field. This is correct architecture but worth noting: if the Flutter client ever does a direct Supabase table read without going through the Edge Function, `user_id` will leak.

### INFO-003 · Contact reveal notification expires in 6 minutes, window is 5 minutes

The notification created on mutual consent has `expiresInHours: 0.1` (= 6 minutes), while the reveal window is 5 minutes. There's a 1-minute window where the notification is still visible but the reveal has already expired. Minor UX inconsistency — harmless but worth tightening to `expiresInHours: 5/60`.

---

## Test Files Generated

| File | Coverage |
|------|----------|
| `tests/pgTAP/test_rematch_after_expiry.sql` | BUG-001 regression: re-match after expiry/decline/complete |
| `tests/pgTAP/test_contact_exchange.sql` | BUG-002, BUG-003, BUG-004: schema correctness, consent flow, expiry |
| `tests/pgTAP/test_rls_attacks.sql` | BUG-005 regression, 15 attack scenarios |
| `tests/pgTAP/test_edge_cases.sql` | Match lifecycle, story reactions, cleanup functions, validation |
| `tests/http/test_edge_functions.sh` | BUG-007, BUG-008: HTTP-level validation, auth guards, CORS |
| `tests/functions/test_trust_safety.sql` | (existing) Trust score, auto-ban, is_blocked |
| `tests/rls/test_rls_drift.sql` | (existing) All drift RLS policies |

---

## Running Tests

```bash
# Requires: Supabase local stack running (Docker)
psql $DATABASE_URL -f tests/pgTAP/test_rematch_after_expiry.sql
psql $DATABASE_URL -f tests/pgTAP/test_contact_exchange.sql
psql $DATABASE_URL -f tests/pgTAP/test_rls_attacks.sql
psql $DATABASE_URL -f tests/pgTAP/test_edge_cases.sql
psql $DATABASE_URL -f tests/functions/test_trust_safety.sql
psql $DATABASE_URL -f tests/rls/test_rls_drift.sql
psql $DATABASE_URL -f tests/rls/test_rls_platform.sql
psql $DATABASE_URL -f tests/geo/test_geo_functions.sql

# HTTP tests (against deployed or local function serve):
SUPABASE_URL=... ANON_KEY=... USER_A_TOKEN=... USER_B_TOKEN=... \
  bash tests/http/test_edge_functions.sh
```
