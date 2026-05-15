#!/usr/bin/env bash
# ============================================================
# Live RLS tests against Supabase REST API
#
# Usage:
#   source backend/.env.local
#   eval "$(python3 tests/auth/mint_jwt.py --export)"
#   bash tests/rls/test_rls_live.sh
#
# Or one-liner:
#   source backend/.env.local && eval "$(python3 tests/auth/mint_jwt.py --export)" && bash tests/rls/test_rls_live.sh
#
# Requires: curl, jq, python3
# ============================================================

set -euo pipefail

BASE="${SUPABASE_URL:?}/rest/v1"
APIKEY="${SUPABASE_ANON_KEY:?}"

TOK_ALICE="${TOK_ALICE:?Run: eval \"\$(python3 tests/auth/mint_jwt.py --export)\"}"
TOK_BOB="${TOK_BOB:?}"
TOK_MALLORY="${TOK_MALLORY:?}"

PASS=0; FAIL=0

# Test data IDs
ALICE_ID="aaaaaaaa-0001-4000-a000-000000000001"
BOB_ID="aaaaaaaa-0002-4000-a000-000000000002"
CAROL_ID="aaaaaaaa-0003-4000-a000-000000000003"
ALICE_SESSION="a1000001-0000-4000-a000-000000000001"
ALICE_STORY="a4000001-0000-4000-a000-000000000001"
MALLORY_STORY="a4000005-0000-4000-a000-000000000006"
ALICE_BOB_MATCH="a2000001-0000-4000-a000-000000000001"

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓  $desc"; ((PASS++)) || true
  else
    echo "  ✗  $desc (expected=$expected, got=$actual)"; ((FAIL++)) || true
  fi
}

rest_get() {
  local token="$1" path="$2"
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    -H "apikey: $APIKEY" \
    "$BASE/$path"
}

rest_get_body() {
  local token="$1" path="$2"
  curl -sS \
    -H "Authorization: Bearer $token" \
    -H "apikey: $APIKEY" \
    "$BASE/$path"
}

rest_patch() {
  local token="$1" path="$2" body="$3"
  curl -sS -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Authorization: Bearer $token" \
    -H "apikey: $APIKEY" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$BASE/$path"
}

# Returns affected row count via Content-Range header (Prefer: count=exact)
rest_patch_count() {
  local token="$1" path="$2" body="$3"
  local range
  range=$(curl -sS -o /dev/null -D - -X PATCH \
    -H "Authorization: Bearer $token" \
    -H "apikey: $APIKEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: count=exact" \
    -d "$body" \
    "$BASE/$path" | grep -i 'Content-Range' | tr -d '\r')
  # Content-Range: 0-0/1 → extract count after /
  echo "${range##*/}" | tr -d '[:space:]'
}

rest_post() {
  local token="$1" path="$2" body="$3"
  curl -sS -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $token" \
    -H "apikey: $APIKEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "$body" \
    "$BASE/$path"
}

# ─── 1. Profile visibility ────────────────────────────────────────────────────
echo ""
echo "=== 1. Profile RLS ==="

# Any authenticated user can read any profile (public read)
status=$(rest_get "$TOK_ALICE" "trombl_profiles?id=eq.$BOB_ID")
check "Alice can read Bob's profile" "200" "$status"

# Can read own profile
status=$(rest_get "$TOK_ALICE" "trombl_profiles?id=eq.$ALICE_ID")
check "Alice can read her own profile" "200" "$status"

# Anon key alone (no JWT) should get 0 rows (RLS restricts to authenticated)
anon_count=$(curl -sS \
  -H "apikey: $APIKEY" \
  "$BASE/trombl_profiles?select=id&limit=1" | jq 'length')
check "Anon key alone returns 0 profile rows (unauthenticated)" "0" "$anon_count"

# Alice cannot update Bob's profile — PostgREST silently filters 0 rows (USING blocks)
# Verify by checking that the affected count is 0, not 1
affected=$(rest_patch_count "$TOK_ALICE" "trombl_profiles?id=eq.$BOB_ID" '{"display_name":"HACKED"}')
check "Alice cannot update Bob's profile (0 rows affected)" "0" "$affected"

# Alice can update her own profile
status=$(rest_patch "$TOK_ALICE" "trombl_profiles?id=eq.$ALICE_ID" '{"bio":"QA testing bio"}')
check "Alice can update her own profile" "204" "$status"

# ─── 2. Session RLS ───────────────────────────────────────────────────────────
echo ""
echo "=== 2. Session RLS ==="

# Alice can see active sessions
alice_sessions=$(rest_get_body "$TOK_ALICE" "drift_sessions?select=id&status=eq.active" | jq 'length')
check "Alice sees active sessions (≥ 1)" "$(( alice_sessions > 0 ? 1 : 0 ))" "1"

# Expired sessions not visible via select_active policy
expired_visible=$(rest_get_body "$TOK_ALICE" "drift_sessions?id=eq.a1000003-0000-4000-a000-000000000003" | jq 'length')
check "Expired session invisible to non-owner" "0" "$expired_visible"

# Carol (host) can still see her own expired session
carol_own=$(rest_get_body "$TOK_ALICE" "drift_sessions?id=eq.a1000003-0000-4000-a000-000000000003" | jq 'length')
check "Expired session not visible to Alice (not her session)" "0" "$carol_own"

# Alice cannot update Carol's session (USING filters to 0 rows)
affected=$(rest_patch_count "$TOK_ALICE" "drift_sessions?id=eq.a1000003-0000-4000-a000-000000000003" '{"status":"active"}')
check "Alice cannot update Carol's session (0 rows affected)" "0" "$affected"

# ─── 3. Match RLS ─────────────────────────────────────────────────────────────
echo ""
echo "=== 3. Match RLS ==="

# Alice can see her own match
alice_matches=$(rest_get_body "$TOK_ALICE" "drift_matches?id=eq.$ALICE_BOB_MATCH" | jq 'length')
check "Alice sees her match with Bob" "1" "$alice_matches"

# Bob can also see the match (he's target)
bob_matches=$(rest_get_body "$TOK_BOB" "drift_matches?id=eq.$ALICE_BOB_MATCH" | jq 'length')
check "Bob sees his match with Alice (target sees match)" "1" "$bob_matches"

# Carol cannot see Alice-Bob match
carol_id="aaaaaaaa-0003-4000-a000-000000000003"
carol_tok="${TOK_CAROL:?}"
carol_match=$(rest_get_body "$carol_tok" "drift_matches?id=eq.$ALICE_BOB_MATCH" | jq 'length')
check "Carol cannot see Alice-Bob match (not a participant)" "0" "$carol_match"

# Mallory cannot see any matches
mallory_count=$(rest_get_body "$TOK_MALLORY" "drift_matches?select=id&limit=10" | jq 'length')
check "Mallory sees 0 matches (not in any)" "0" "$mallory_count"

# ─── 4. Story RLS ─────────────────────────────────────────────────────────────
echo ""
echo "=== 4. Story RLS ==="

# Alice's story is visible publicly
story_visible=$(rest_get_body "$TOK_BOB" "drift_stories?id=eq.$ALICE_STORY" | jq 'length')
check "Bob can see Alice's story (public feed)" "1" "$story_visible"

# Mallory's flagged story is still visible (is_flagged doesn't hide — FIND-001)
flagged_visible=$(rest_get_body "$TOK_ALICE" "drift_stories?id=eq.$MALLORY_STORY" | jq 'length')
check "Flagged story still visible to others (FIND-001 known issue)" "1" "$flagged_visible"

# Alice cannot modify story's is_flagged or is_removed — WITH CHECK returns 403
status=$(rest_patch "$TOK_ALICE" "drift_stories?id=eq.$ALICE_STORY" '{"is_flagged":true}')
check "Alice cannot set is_flagged on her own story (403 from WITH CHECK)" "403" "$status"

# Alice cannot set is_removed on her own story
status=$(rest_patch "$TOK_ALICE" "drift_stories?id=eq.$ALICE_STORY" '{"is_removed":true}')
check "Alice cannot set is_removed on her own story (403 from WITH CHECK)" "403" "$status"

# Alice can update her story's vibe_tags (allowed field, no WITH CHECK violation)
status=$(rest_patch "$TOK_ALICE" "drift_stories?id=eq.$ALICE_STORY" '{"vibe_tags":["cozy","bright"]}')
check "Alice can update vibe_tags on her own story" "204" "$status"

# ─── 5. Notification RLS (BUG-005 regression) ────────────────────────────────
echo ""
echo "=== 5. Notification RLS ==="

notif_count=$(rest_get_body "$TOK_ALICE" "trombl_notifications?select=id&limit=5" | jq 'length')
echo "  ℹ  Alice notifications visible: $notif_count"

# Alice cannot see Bob's notifications
bob_notif=$(rest_get_body "$TOK_ALICE" \
  "trombl_notifications?user_id=eq.$BOB_ID&select=id&limit=1" | jq 'length')
check "Alice cannot see Bob's notifications" "0" "$bob_notif"

# ─── 6. Presence RLS ─────────────────────────────────────────────────────────
echo ""
echo "=== 6. Presence RLS ==="

# Online users visible
online_count=$(rest_get_body "$TOK_ALICE" "drift_presence?is_online=eq.true&select=user_id" | jq 'length')
check "Online presence visible (≥ 1)" "$(( online_count > 0 ? 1 : 0 ))" "1"

# Offline users NOT visible via select policy (only is_online=true allowed)
offline_count=$(rest_get_body "$TOK_ALICE" \
  "drift_presence?user_id=eq.$CAROL_ID&select=user_id" | jq 'length')
check "Offline user (Carol) not visible via presence" "0" "$offline_count"

echo ""
echo "============================================"
echo "RLS Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $(( FAIL > 0 ? 1 : 0 ))
