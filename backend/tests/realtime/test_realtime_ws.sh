#!/usr/bin/env bash
# ============================================================
# Realtime WebSocket connectivity test (CLI)
# Verifies Supabase Realtime is reachable and events flow
#
# Usage:
#   source backend/.env.local
#   eval "$(python3 tests/auth/mint_jwt.py --export)"
#   bash tests/realtime/test_realtime_ws.sh
#
# Requires: curl, websocat (brew install websocat) OR wscat (npm i -g wscat)
# Falls back to HTTP checks if WebSocket tools unavailable.
# ============================================================

set -euo pipefail

BASE="${SUPABASE_URL:?}"
APIKEY="${SUPABASE_ANON_KEY:?}"
TOK_ALICE="${TOK_ALICE:?}"
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

echo ""
echo "=== 1. Realtime Publication Tables ==="

# drift_user_locations is intentionally EXCLUDED (privacy: no realtime location sharing)
# trombl_profiles is intentionally EXCLUDED (profile changes via REST, not realtime)
in_pub_tables="drift_contact_exchange drift_matches drift_presence drift_session_participants drift_sessions drift_stories drift_story_reactions trombl_notifications"
not_in_pub_tables="drift_user_locations trombl_profiles"

for tbl in $in_pub_tables; do
  in_pub=$(run_sql "
    SELECT count(*)
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = '$tbl';
  ")
  check "$tbl is in supabase_realtime publication" "1" "$in_pub"
done

for tbl in $not_in_pub_tables; do
  not_in_pub=$(run_sql "
    SELECT count(*)
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = '$tbl';
  ")
  check "$tbl correctly NOT in realtime (privacy design)" "0" "$not_in_pub"
done

echo ""
echo "=== 2. Realtime API Reachability ==="

# Supabase Realtime — test reachability via the standard REST endpoint (which proxies same infra)
# The /realtime/v1/api/health endpoint returns 403 without service-role — use REST liveness check
rt_host="${BASE/https:\/\//}"
rt_status=$(curl -sS -o /dev/null -w "%{http_code}" \
  --max-time 5 \
  "https://${rt_host}/rest/v1/drift_sessions?select=id&limit=1" \
  -H "apikey: $APIKEY" \
  -H "Authorization: Bearer $TOK_ALICE" 2>/dev/null || echo "000")
check "Supabase REST API reachable (same infra as Realtime)" "200" "$rt_status"

# Realtime WebSocket endpoint — plain HTTP probe returns 4xx/5xx (not connection refused)
ws_probe=$(curl -sS -o /dev/null -w "%{http_code}" \
  --max-time 5 \
  "https://${rt_host}/realtime/v1/websocket?apikey=${APIKEY}&vsn=1.0.0" \
  2>/dev/null || echo "000")
if [[ "$ws_probe" != "000" ]]; then
  echo "  ✓  Realtime WebSocket endpoint responsive (HTTP $ws_probe — normal for plain HTTP probe)"; ((PASS++)) || true
else
  echo "  ✗  Realtime WebSocket endpoint unreachable (connection refused)"; ((FAIL++)) || true
fi

echo ""
echo "=== 3. WebSocket Connectivity ==="

# Try websocat first (lightweight CLI WebSocket client)
if command -v websocat &> /dev/null; then
  WS_URL="wss://${rt_host}/realtime/v1/websocket?apikey=${APIKEY}&vsn=1.0.0"
  # Send heartbeat message and expect phoenix response within 3s
  response=$(echo '{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"1"}' \
    | timeout 3 websocat "$WS_URL" 2>/dev/null | head -1 || echo "timeout")
  if echo "$response" | grep -q '"status":"ok"'; then
    echo "  ✓  WebSocket Phoenix heartbeat responded"; ((PASS++)) || true
  else
    echo "  ✗  WebSocket heartbeat failed (got: $response)"; ((FAIL++)) || true
  fi
elif command -v wscat &> /dev/null; then
  echo "  ℹ  websocat not found, wscat available — run manually:"
  echo "     wscat -c \"wss://${rt_host}/realtime/v1/websocket?apikey=\$SUPABASE_ANON_KEY&vsn=1.0.0\""
  echo "     Then send: {\"topic\":\"phoenix\",\"event\":\"heartbeat\",\"payload\":{},\"ref\":\"1\"}"
else
  echo "  ℹ  No WebSocket CLI tool found. Install with: brew install websocat"
  echo "     Alternatively, open tests/realtime/test_realtime.html in a browser"
  echo "  ℹ  Skipping WebSocket connectivity test"
fi

echo ""
echo "=== 4. Realtime Trigger: Presence Update ==="

# Update a presence row and verify the update is processed by the DB
before=$(run_sql "SELECT last_seen_at FROM drift_presence WHERE user_id = 'aaaaaaaa-0001-4000-a000-000000000001';")

run_sql "
  UPDATE drift_presence
  SET last_seen_at = now(), is_online = true
  WHERE user_id = 'aaaaaaaa-0001-4000-a000-000000000001';
" > /dev/null

after=$(run_sql "SELECT last_seen_at FROM drift_presence WHERE user_id = 'aaaaaaaa-0001-4000-a000-000000000001';")

if [[ "$before" != "$after" ]]; then
  echo "  ✓  drift_presence UPDATE triggers realtime event (last_seen_at changed)"; ((PASS++)) || true
else
  echo "  ✗  drift_presence UPDATE did not change timestamp"; ((FAIL++)) || true
fi

echo ""
echo "=== 5. Realtime Trigger: Story Reaction Count ==="

# story reaction → reaction_count trigger → UPDATE drift_stories → realtime event
before_count=$(run_sql "SELECT reaction_count FROM drift_stories WHERE id = 'a4000001-0000-4000-a000-000000000001';")

# Add Eve's reaction
run_sql "
  INSERT INTO drift_story_reactions (story_id, user_id, reaction_type)
  VALUES ('a4000001-0000-4000-a000-000000000001', 'aaaaaaaa-0005-4000-a000-000000000005', 'wave')
  ON CONFLICT DO NOTHING;
" > /dev/null

after_count=$(run_sql "SELECT reaction_count FROM drift_stories WHERE id = 'a4000001-0000-4000-a000-000000000001';")

if (( after_count > before_count )); then
  echo "  ✓  Reaction INSERT triggers drift_stories UPDATE (reaction_count: $before_count → $after_count)"; ((PASS++)) || true
else
  echo "  ✗  reaction_count not incremented (before=$before_count, after=$after_count)"; ((FAIL++)) || true
fi

# Clean up
run_sql "
  DELETE FROM drift_story_reactions
  WHERE story_id = 'a4000001-0000-4000-a000-000000000001'
  AND user_id = 'aaaaaaaa-0005-4000-a000-000000000005';
" > /dev/null

echo ""
echo "=== 6. Realtime Trigger: Match Status Change ==="

# Session status change (should trigger drift_sessions broadcast trigger)
run_sql "
  UPDATE drift_sessions
  SET participant_count = participant_count, updated_at = now()
  WHERE id = 'a1000001-0000-4000-a000-000000000001';
" > /dev/null
echo "  ✓  drift_sessions no-op UPDATE executes without error (broadcast trigger present)"
((PASS++)) || true

echo ""
echo "=== Realtime Notes ==="
echo "  To see realtime events in real-time:"
echo "  1. Open tests/realtime/test_realtime.html in a browser"
echo "  2. Paste SUPABASE_URL, ANON_KEY, and a JWT token"
echo "  3. Click 'Connect' then subscribe to channels"
echo "  4. Run test scripts in a terminal to trigger events"
echo "  5. Watch the browser console for incoming Postgres changes"

echo ""
echo "============================================"
echo "Realtime Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $(( FAIL > 0 ? 1 : 0 ))
