#!/usr/bin/env bash
# ============================================================
# Contact Exchange Scenario Tests
# Tests the full lifecycle: match → consent → mutual consent → reveal
#
# Usage:
#   source backend/.env.local
#   eval "$(python3 tests/auth/mint_jwt.py --export)"
#   bash tests/scenarios/test_contact_exchange.sh
# ============================================================

set -euo pipefail

BASE="${SUPABASE_URL:?}/rest/v1"
APIKEY="${SUPABASE_ANON_KEY:?}"
TOK_ALICE="${TOK_ALICE:?}"
TOK_BOB="${TOK_BOB:?}"
TOK_DAVE="${TOK_DAVE:?}"
TOK_EVE="${TOK_EVE:?}"

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

# Existing test data: Alice-Bob match is ACCEPTED with mutual consent
ALICE_BOB_MATCH="a2000001-0000-4000-a000-000000000001"
ALICE_BOB_EXCHANGE="a3000001-0000-4000-a000-000000000001"

echo ""
echo "=== Setup: Restore Alice-Bob Exchange State ==="

# The Alice-Bob exchange may have been expired by previous test runs or cleanup.
# Reset to a known good state before assertions.
run_sql "
  UPDATE drift_contact_exchange
  SET is_expired = false, expires_at = now() + interval '24 hours'
  WHERE id = 'a3000001-0000-4000-a000-000000000001';
" > /dev/null

echo ""
echo "=== 1. Pre-existing Alice-Bob Exchange State ==="

status=$(run_sql "SELECT status FROM drift_matches WHERE id = '$ALICE_BOB_MATCH';")
check "Alice-Bob match status is accepted" "accepted" "$status"

mutual=$(run_sql "
  SELECT initiator_consented AND target_consented
  FROM drift_contact_exchange WHERE id = '$ALICE_BOB_EXCHANGE';
")
check "Alice-Bob contact exchange is mutually consented" "t" "$mutual"

not_expired=$(run_sql "
  SELECT NOT is_expired FROM drift_contact_exchange WHERE id = '$ALICE_BOB_EXCHANGE';
")
check "Alice-Bob contact exchange is not expired" "t" "$not_expired"

echo ""
echo "=== 2. Create New Match for Dave-Eve Scenario ==="

# Create Dave-Eve accepted match via direct SQL (as service role)
DAVE_EVE_MATCH_ID="a2000003-0000-4000-a000-000000000003"

run_sql "
  INSERT INTO drift_matches (id, initiator_id, target_id, status, initiated_at, accepted_at, expires_at)
  VALUES (
    '$DAVE_EVE_MATCH_ID',
    'aaaaaaaa-0004-4000-a000-000000000004',
    'aaaaaaaa-0005-4000-a000-000000000005',
    'accepted',
    now() - interval '10 minutes',
    now() - interval '8 minutes',
    now() + interval '23 hours 50 minutes'
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

match_exists=$(run_sql "SELECT count(*) FROM drift_matches WHERE id = '$DAVE_EVE_MATCH_ID';")
check "Dave-Eve accepted match created" "1" "$match_exists"

echo ""
echo "=== 3. RLS: Non-participant cannot see contact exchange ==="

carol_tok="${TOK_CAROL:-}"
if [[ -n "$carol_tok" ]]; then
  # Carol tries to see Alice-Bob exchange via REST
  carol_view=$(curl -sS \
    -H "Authorization: Bearer $carol_tok" \
    -H "apikey: $APIKEY" \
    "$BASE/drift_contact_exchange?id=eq.$ALICE_BOB_EXCHANGE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")
  check "Carol cannot see Alice-Bob contact exchange" "0" "$carol_view"
else
  echo "  ℹ  Skipping Carol RLS check (TOK_CAROL not set)"
fi

echo ""
echo "=== 4. Contact Reveal Window Expiry ==="

# Test expire_contact_exchanges function
run_sql "
  INSERT INTO drift_contact_exchange (
    id, match_id, initiator_consented, target_consented,
    initiator_contact_type, target_contact_type,
    reveal_at, expires_at, is_expired
  ) VALUES (
    'a3000002-0000-4000-a000-000000000002',
    '$DAVE_EVE_MATCH_ID',
    true, true, 'instagram', 'instagram',
    now() - interval '10 minutes',
    now() - interval '1 minute',
    false
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

before=$(run_sql "
  SELECT is_expired FROM drift_contact_exchange
  WHERE id = 'a3000002-0000-4000-a000-000000000002';
")
check "Dave-Eve exchange is not_expired before cleanup (is_expired=false)" "f" "$before"

run_sql "SELECT public.expire_contact_exchanges();" > /dev/null

after=$(run_sql "
  SELECT is_expired FROM drift_contact_exchange
  WHERE id = 'a3000002-0000-4000-a000-000000000002';
")
check "expire_contact_exchanges marks expired window" "t" "$after"

echo ""
echo "=== 5. Contact Type Constraint ==="

# The DB enum drift_contact_type — check what values are valid
valid_types=$(run_sql "
  SELECT string_agg(enumlabel, ', ' ORDER BY enumsortorder)
  FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
  WHERE t.typname = 'drift_contact_type';
")
echo "  ℹ  Valid contact types: $valid_types"

# Attempt to insert with invalid contact_type (should fail)
invalid_insert=$(run_sql "
  SELECT 1 FROM (
    SELECT * FROM drift_contact_exchange LIMIT 0
  ) sq;
  -- Can't easily test enum constraint via SQL without a try/catch
  -- This is tested via the HTTP test (test_edge_functions.sh)
")
echo "  ℹ  Invalid contact_type rejection tested in HTTP tests (test_edge_functions.sh)"

echo ""
echo "=== 6. Unique Constraint: One Exchange Per Match ==="

duplicate=$(run_sql "
  SELECT count(*) FROM drift_contact_exchange
  WHERE match_id = '$ALICE_BOB_MATCH';
")
check "Only one exchange record per match (Alice-Bob)" "1" "$duplicate"

# Verify upsert behavior (ON CONFLICT) doesn't double-insert
run_sql "
  INSERT INTO drift_contact_exchange (match_id, initiator_consented, target_consented)
  VALUES ('$ALICE_BOB_MATCH', true, false)
  ON CONFLICT (match_id) DO NOTHING;
" > /dev/null

still_one=$(run_sql "
  SELECT count(*) FROM drift_contact_exchange WHERE match_id = '$ALICE_BOB_MATCH';
")
check "Duplicate exchange insert silently ignored (ON CONFLICT)" "1" "$still_one"

echo ""
echo "=== 7. Cleanup: Remove test match ==="
run_sql "DELETE FROM drift_matches WHERE id = '$DAVE_EVE_MATCH_ID';" > /dev/null
echo "  ℹ  Dave-Eve test match cleaned up"

echo ""
echo "============================================"
echo "Contact Exchange Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $(( FAIL > 0 ? 1 : 0 ))
