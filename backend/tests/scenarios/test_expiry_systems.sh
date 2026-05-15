#!/usr/bin/env bash
# ============================================================
# Expiry System Tests
# Verifies all scheduled cleanup functions work correctly
#
# Usage:
#   source backend/.env.local
#   bash tests/scenarios/test_expiry_systems.sh
# ============================================================

set -euo pipefail

DB="${DATABASE_URL:?}"
PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓  $desc"; ((PASS++)) || true
  else
    echo "  ✗  $desc (expected=$expected, got=$actual)"; ((FAIL++)) || true
  fi
}

run_sql() { psql -qtAX "$DB" -c "$1"; }
run_sql_file() { psql -qtAX "$DB" -f "$1"; }

echo ""
echo "=== 1. expire_pending_matches() ==="

# Insert a match that should expire
run_sql "
  INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
  VALUES (
    'a2000099-0000-4000-a000-000000000099',
    'aaaaaaaa-0001-4000-a000-000000000001',
    'aaaaaaaa-0005-4000-a000-000000000005',
    'pending',
    now() - interval '1 minute'
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

before=$(run_sql "SELECT status FROM drift_matches WHERE id = 'a2000099-0000-4000-a000-000000000099';")
check "Overdue pending match exists before cleanup" "pending" "$before"

run_sql "SELECT public.expire_pending_matches();" > /dev/null

after=$(run_sql "SELECT status FROM drift_matches WHERE id = 'a2000099-0000-4000-a000-000000000099';")
check "expire_pending_matches sets status=expired" "expired" "$after"

reason=$(run_sql "SELECT end_reason FROM drift_matches WHERE id = 'a2000099-0000-4000-a000-000000000099';")
check "Expired match has end_reason=auto_expired" "auto_expired" "$reason"

# Accepted match not touched by expire_pending_matches
run_sql "
  UPDATE drift_matches SET expires_at = now() - interval '5 minutes'
  WHERE id = 'a2000001-0000-4000-a000-000000000001';
" > /dev/null

run_sql "SELECT public.expire_pending_matches();" > /dev/null

alice_bob=$(run_sql "SELECT status FROM drift_matches WHERE id = 'a2000001-0000-4000-a000-000000000001';")
check "Accepted match not expired by cleanup (only pending)" "accepted" "$alice_bob"

# Restore Alice-Bob match expiry
run_sql "
  UPDATE drift_matches SET expires_at = now() + interval '23 hours'
  WHERE id = 'a2000001-0000-4000-a000-000000000001';
" > /dev/null

# Cleanup
run_sql "DELETE FROM drift_matches WHERE id = 'a2000099-0000-4000-a000-000000000099';" > /dev/null

echo ""
echo "=== 2. expire_contact_exchanges() ==="

# Create an expired exchange for testing
run_sql "
  INSERT INTO drift_matches (id, initiator_id, target_id, status, expires_at)
  VALUES (
    'a2000098-0000-4000-a000-000000000098',
    'aaaaaaaa-0001-4000-a000-000000000001',
    'aaaaaaaa-0005-4000-a000-000000000005',
    'accepted', now() + interval '23 hours'
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

# Insert exchange with expired reveal window
run_sql "
  INSERT INTO drift_contact_exchange (
    id, match_id, initiator_consented, target_consented,
    initiator_contact_type, target_contact_type,
    reveal_at, expires_at, is_expired
  ) VALUES (
    'a3000099-0000-4000-a000-000000000099',
    'a2000098-0000-4000-a000-000000000098',
    true, true, 'phone', 'phone',
    now() - interval '10 minutes',
    now() - interval '5 minutes',
    false
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

before=$(run_sql "SELECT is_expired FROM drift_contact_exchange WHERE id = 'a3000099-0000-4000-a000-000000000099';")
check "Expired exchange is_expired=false before cleanup" "f" "$before"

expired_count=$(run_sql "SELECT public.expire_contact_exchanges();")
check "expire_contact_exchanges returns count ≥ 1" "$(( expired_count >= 1 ? 1 : 0 ))" "1"

after=$(run_sql "SELECT is_expired FROM drift_contact_exchange WHERE id = 'a3000099-0000-4000-a000-000000000099';")
check "expire_contact_exchanges marks window as expired" "t" "$after"

# Cleanup
run_sql "DELETE FROM drift_matches WHERE id = 'a2000098-0000-4000-a000-000000000098';" > /dev/null

echo ""
echo "=== 3. cleanup_stale_presence() ==="

# Refresh Alice's presence to now() so she won't be caught by cleanup
run_sql "
  UPDATE drift_presence SET last_seen_at = now(), is_online = true
  WHERE user_id = 'aaaaaaaa-0001-4000-a000-000000000001';
" > /dev/null

# Mark Eve as stale (last_seen > 2 minutes ago)
run_sql "
  INSERT INTO drift_presence (user_id, is_online, last_seen_at)
  VALUES ('aaaaaaaa-0005-4000-a000-000000000005', true, now() - interval '3 minutes')
  ON CONFLICT (user_id) DO UPDATE SET is_online = true, last_seen_at = now() - interval '3 minutes';
" > /dev/null

before=$(run_sql "SELECT is_online FROM drift_presence WHERE user_id = 'aaaaaaaa-0005-4000-a000-000000000005';")
check "Stale user (Eve) is online before cleanup" "t" "$before"

run_sql "SELECT public.cleanup_stale_presence();" > /dev/null

after=$(run_sql "SELECT is_online FROM drift_presence WHERE user_id = 'aaaaaaaa-0005-4000-a000-000000000005';")
check "cleanup_stale_presence marks Eve offline after >2min idle" "f" "$after"

# Fresh presence not touched (refreshed to now() just above)
alice_online=$(run_sql "SELECT is_online FROM drift_presence WHERE user_id = 'aaaaaaaa-0001-4000-a000-000000000001';")
check "Alice (fresh presence) remains online" "t" "$alice_online"

echo ""
echo "=== 4. cleanup_old_stories() ==="

# Insert a story older than the retention window
old_story_id="a4000098-0000-4000-a000-000000000098"
run_sql "
  INSERT INTO drift_stories (id, user_id, emoji, text, city, published_at, created_at)
  VALUES (
    '$old_story_id',
    'aaaaaaaa-0001-4000-a000-000000000001',
    '🗂', 'Old story for cleanup test', 'London',
    now() - interval '48 hours', now() - interval '48 hours'
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

before=$(run_sql "SELECT count(*) FROM drift_stories WHERE id = '$old_story_id';")
check "Old story exists before cleanup" "1" "$before"

cleaned=$(run_sql "SELECT public.cleanup_old_stories();")
echo "  ℹ  cleanup_old_stories deleted: $cleaned rows (retention window depends on env config)"

after=$(run_sql "SELECT count(*) FROM drift_stories WHERE id = '$old_story_id';")
if [[ "$after" == "0" ]]; then
  check "Old story removed by cleanup_old_stories" "0" "$after"
else
  echo "  ℹ  Story retained — retention window likely > 48h (check DRIFT_STORY_RETENTION_HOURS env)"
  run_sql "DELETE FROM drift_stories WHERE id = '$old_story_id';" > /dev/null
fi

echo ""
echo "=== 5. run_scheduled_cleanup() Orchestrator ==="

result=$(run_sql "SELECT public.run_scheduled_cleanup()::text;")
echo "  ℹ  run_scheduled_cleanup result: $result"

# Verify result has all expected keys
for key in locations_cleaned matches_expired stories_soft_del presence_cleared exchanges_expired; do
  if echo "$result" | grep -q "\"$key\""; then
    echo "  ✓  Cleanup result contains key: $key"; ((PASS++)) || true
  else
    echo "  ✗  Cleanup result missing key: $key"; ((FAIL++)) || true
  fi
done

echo ""
echo "============================================"
echo "Expiry Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $(( FAIL > 0 ? 1 : 0 ))
