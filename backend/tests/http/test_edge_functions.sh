#!/usr/bin/env bash
# ============================================================
# HTTP tests for Trombl Edge Functions
# Usage: SUPABASE_URL=https://xxx.supabase.co \
#        ANON_KEY=<anon-jwt> \
#        USER_A_TOKEN=<jwt> \
#        USER_B_TOKEN=<jwt> \
#        bash tests/http/test_edge_functions.sh
#
# Requires: curl, jq
# ============================================================

set -euo pipefail

BASE="${SUPABASE_URL}/functions/v1"
ANON="${ANON_KEY:-}"
TOK_A="${USER_A_TOKEN:-}"    # authenticated user A (initiator)
TOK_B="${USER_B_TOKEN:-}"    # authenticated user B (target)

PASS=0
FAIL=0

check() {
  local desc="$1"
  local expected_status="$2"
  local actual_status="$3"
  local body="$4"
  if [[ "$actual_status" == "$expected_status" ]]; then
    echo "  ✓  $desc"
    ((PASS++)) || true
  else
    echo "  ✗  $desc"
    echo "     Expected HTTP $expected_status, got HTTP $actual_status"
    echo "     Body: $body"
    ((FAIL++)) || true
  fi
}

check_field() {
  local desc="$1"
  local field="$2"
  local expected="$3"
  local body="$4"
  local actual
  actual=$(echo "$body" | jq -r "$field" 2>/dev/null || echo "<jq error>")
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓  $desc"
    ((PASS++)) || true
  else
    echo "  ✗  $desc"
    echo "     Expected $field = $expected, got: $actual"
    ((FAIL++)) || true
  fi
}

require_env() {
  if [[ -z "${!1:-}" ]]; then
    echo "ERROR: $1 is required"
    exit 1
  fi
}

require_env SUPABASE_URL
require_env ANON_KEY

# ─── Unauthenticated access ───────────────────────────────────────────────────

echo ""
echo "=== Auth guard tests ==="

for fn in drift-create-session drift-discover-nearby drift-match-users drift-publish-story drift-contact-reveal drift-report-user; do
  resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/$fn" \
    -H "Authorization: Bearer $ANON" \
    -H "Content-Type: application/json" \
    -d '{}')
  status=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  check "/$fn rejects anon key (no JWT sub)" "401" "$status" "$body"
done

if [[ -z "$TOK_A" || -z "$TOK_B" ]]; then
  echo ""
  echo "⚠  USER_A_TOKEN and USER_B_TOKEN not set — skipping authenticated tests"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

# ─── drift-create-session ────────────────────────────────────────────────────

echo ""
echo "=== drift-create-session ==="

# Missing required fields
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-create-session" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d '{}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Missing body returns 400" "400" "$status" "$body"

# Invalid method
resp=$(curl -s -w "\n%{http_code}" -X GET "$BASE/drift-create-session" \
  -H "Authorization: Bearer $TOK_A")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "GET method returns 405" "405" "$status" "$body"

# ─── drift-match-users ───────────────────────────────────────────────────────

echo ""
echo "=== drift-match-users ==="

# Self-match
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-match-users" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d "{\"target_id\": \"00000000-0000-0000-0000-000000000000\"}")
# Note: this will 404 (user not found) or 400 depending on how tok_a's sub compares
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
echo "  ℹ  Match to non-existent user: HTTP $status"

# Invalid UUID
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-match-users" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d '{"target_id": "not-a-uuid"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Invalid target_id UUID returns 400" "400" "$status" "$body"

# ─── drift-contact-reveal: invalid contact_type ───────────────────────────────

echo ""
echo "=== drift-contact-reveal ==="

resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-contact-reveal/consent" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d '{"match_id": "00000000-0000-4000-a000-000000000000", "contact_type": "telegram"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Invalid contact_type (telegram) returns 400" "400" "$status" "$body"

resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-contact-reveal/consent" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d '{"match_id": "not-a-uuid", "contact_type": "instagram"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Invalid match_id UUID returns 400" "400" "$status" "$body"

# Reveal on non-existent match
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-contact-reveal/reveal" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d '{"match_id": "00000000-0000-4000-a000-000000000000"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Reveal on non-existent match returns 403" "403" "$status" "$body"

# ─── drift-report-user ───────────────────────────────────────────────────────

echo ""
echo "=== drift-report-user ==="

# 'impersonation' was bug-fixed to 'fake_profile' — must now reject impersonation
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-report-user" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d "{\"reported_id\": \"00000000-0000-4000-a000-000000000000\", \"reason\": \"impersonation\"}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "reason=impersonation rejected (not in VALID_REASONS after fix)" "400" "$status" "$body"

# fake_profile now accepted at API level
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-report-user" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d "{\"reported_id\": \"00000000-0000-4000-a000-000000000000\", \"reason\": \"fake_profile\"}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
# Will 404 on user lookup but reason validation passes
check "reason=fake_profile passes validation (404 from user lookup expected)" "404" "$status" "$body"

# reason=other requires custom_reason
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-report-user" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d "{\"reported_id\": \"00000000-0000-4000-a000-000000000000\", \"reason\": \"other\"}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "reason=other without custom_reason returns 400" "400" "$status" "$body"

# custom_reason > 500 chars
long_reason=$(python3 -c "print('x' * 501)")
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-report-user" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d "{\"reported_id\": \"00000000-0000-4000-a000-000000000000\", \"reason\": \"other\", \"custom_reason\": \"$long_reason\"}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "custom_reason > 500 chars returns 400" "400" "$status" "$body"

# ─── drift-publish-story ─────────────────────────────────────────────────────

echo ""
echo "=== drift-publish-story ==="

resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-publish-story" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d '{"emoji": "😊", "text": "", "city": "London"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Empty story text returns 400" "400" "$status" "$body"

long_text=$(python3 -c "print('x' * 141)")
resp=$(curl -s -w "\n%{http_code}" -X POST "$BASE/drift-publish-story" \
  -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" \
  -d "{\"emoji\": \"😊\", \"text\": \"$long_text\", \"city\": \"London\"}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -1)
check "Story text > 140 chars returns 400" "400" "$status" "$body"

# ─── CORS preflight ──────────────────────────────────────────────────────────

echo ""
echo "=== CORS preflight ==="

resp=$(curl -s -w "\n%{http_code}" -X OPTIONS "$BASE/drift-create-session" \
  -H "Origin: https://example.com" \
  -H "Access-Control-Request-Method: POST")
status=$(echo "$resp" | tail -1)
check "OPTIONS preflight returns 200" "200" "$status" ""

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

exit $(( FAIL > 0 ? 1 : 0 ))
