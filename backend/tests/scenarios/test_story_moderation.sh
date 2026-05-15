#!/usr/bin/env bash
# ============================================================
# Story Moderation Scenario Tests
# Tests: flagging, removal, visibility, rate limiting, reactions
#
# Usage:
#   source backend/.env.local
#   eval "$(python3 tests/auth/mint_jwt.py --export)"
#   bash tests/scenarios/test_story_moderation.sh
# ============================================================

set -euo pipefail

BASE="${SUPABASE_URL:?}/rest/v1"
APIKEY="${SUPABASE_ANON_KEY:?}"
TOK_ALICE="${TOK_ALICE:?}"
TOK_BOB="${TOK_BOB:?}"
TOK_MALLORY="${TOK_MALLORY:?}"
DB="${DATABASE_URL:?}"

PASS=0; FAIL=0

ALICE_ID="aaaaaaaa-0001-4000-a000-000000000001"
BOB_ID="aaaaaaaa-0002-4000-a000-000000000002"
MALLORY_ID="aaaaaaaa-0006-4000-a000-000000000006"
MALLORY_STORY="a4000005-0000-4000-a000-000000000006"
ALICE_STORY="a4000001-0000-4000-a000-000000000001"

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓  $desc"; ((PASS++)) || true
  else
    echo "  ✗  $desc (expected=$expected, got=$actual)"; ((FAIL++)) || true
  fi
}

run_sql() { psql -qtAX "$DB" -c "$1"; }

# ─── 1. Flagged story visibility ─────────────────────────────────────────────
echo ""
echo "=== 1. Flagged Story Visibility (FIND-001) ==="

flagged=$(run_sql "SELECT is_flagged FROM drift_stories WHERE id = '$MALLORY_STORY';")
check "Mallory's story is flagged" "t" "$flagged"

# FIND-001: flagged stories are still publicly visible (by design or bug)
visible_to_alice=$(curl -sS \
  -H "Authorization: Bearer $TOK_ALICE" \
  -H "apikey: $APIKEY" \
  "$BASE/drift_stories?id=eq.$MALLORY_STORY&select=id,is_flagged" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")
check "FIND-001: Flagged story visible to other users (known issue)" "1" "$visible_to_alice"
echo "  ⚠  FIND-001: Add AND is_flagged = false to stories_select_public RLS to fix"

# ─── 2. Removed story visibility ─────────────────────────────────────────────
echo ""
echo "=== 2. Removed Story Visibility ==="

# Admin (service role) removes a story
run_sql "
  UPDATE drift_stories SET is_removed = true, removed_reason = 'violates_community_guidelines'
  WHERE id = '$MALLORY_STORY';
" > /dev/null

removed=$(run_sql "SELECT is_removed FROM drift_stories WHERE id = '$MALLORY_STORY';")
check "Mallory's story marked as removed (by admin)" "t" "$removed"

# Removed story should NOT be visible (is_removed = false in RLS)
visible_after_removal=$(curl -sS \
  -H "Authorization: Bearer $TOK_ALICE" \
  -H "apikey: $APIKEY" \
  "$BASE/drift_stories?id=eq.$MALLORY_STORY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")
check "Removed story invisible to other users" "0" "$visible_after_removal"

# Restore for next tests
run_sql "
  UPDATE drift_stories SET is_removed = false, removed_reason = NULL
  WHERE id = '$MALLORY_STORY';
" > /dev/null

# ─── 3. Story self-moderation constraints ────────────────────────────────────
echo ""
echo "=== 3. Story Self-Moderation Constraints ==="

# Alice cannot flag her own story
status=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH \
  -H "Authorization: Bearer $TOK_ALICE" \
  -H "apikey: $APIKEY" \
  -H "Content-Type: application/json" \
  "$BASE/drift_stories?id=eq.$ALICE_STORY" \
  -d '{"is_flagged":true}')
check "Alice cannot flag her own story (403)" "403" "$status"

# Alice cannot remove her own story
status=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH \
  -H "Authorization: Bearer $TOK_ALICE" \
  -H "apikey: $APIKEY" \
  -H "Content-Type: application/json" \
  "$BASE/drift_stories?id=eq.$ALICE_STORY" \
  -d '{"is_removed":true}')
check "Alice cannot remove her own story (403)" "403" "$status"

# ─── 4. Reaction count trigger ───────────────────────────────────────────────
echo ""
echo "=== 4. Reaction Count Trigger ==="

initial_count=$(run_sql "SELECT reaction_count FROM drift_stories WHERE id = '$ALICE_STORY';")
echo "  ℹ  Alice's story current reaction_count: $initial_count"

# Mallory reacts
run_sql "
  INSERT INTO drift_story_reactions (story_id, user_id, reaction_type)
  VALUES ('$ALICE_STORY', '$MALLORY_ID', 'wave')
  ON CONFLICT DO NOTHING;
" > /dev/null

after_react=$(run_sql "SELECT reaction_count FROM drift_stories WHERE id = '$ALICE_STORY';")
check "reaction_count incremented after Mallory reacts" "$(( initial_count + 1 ))" "$after_react"

# Mallory removes reaction
run_sql "
  DELETE FROM drift_story_reactions
  WHERE story_id = '$ALICE_STORY' AND user_id = '$MALLORY_ID';
" > /dev/null

after_remove=$(run_sql "SELECT reaction_count FROM drift_stories WHERE id = '$ALICE_STORY';")
check "reaction_count decremented after reaction removed" "$initial_count" "$after_remove"

# Duplicate reaction blocked by UNIQUE constraint
dup_insert=$(run_sql "
  INSERT INTO drift_story_reactions (story_id, user_id, reaction_type)
  VALUES ('$ALICE_STORY', '$BOB_ID', 'spark')
  ON CONFLICT DO NOTHING;
  SELECT count(*) FROM drift_story_reactions
  WHERE story_id = '$ALICE_STORY' AND user_id = '$BOB_ID';
")
check "Duplicate reaction silently ignored (ON CONFLICT DO NOTHING)" "1" "$dup_insert"

# ─── 5. Story text constraints ───────────────────────────────────────────────
echo ""
echo "=== 5. Story Text Constraints ==="

# Insert story >140 chars fails
too_long=$(python3 -c "print('x' * 141)")
result=$(run_sql "
  DO \$\$
  BEGIN
    INSERT INTO drift_stories (user_id, emoji, text, city)
    VALUES ('$ALICE_ID', '📝', '$too_long', 'London');
    RAISE NOTICE 'INSERT succeeded (unexpected)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'CHECK violation (expected)';
  END;
  \$\$;
" 2>&1 | grep -c "CHECK\|check_violation\|violates check constraint" || true)
check "Story text > 140 chars rejected by CHECK constraint" "1" "$result"

# Empty story text fails
empty_result=$(run_sql "
  DO \$\$
  BEGIN
    INSERT INTO drift_stories (user_id, emoji, text, city)
    VALUES ('$ALICE_ID', '📝', '', 'London');
    RAISE NOTICE 'INSERT succeeded';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'CHECK violation (expected)';
  END;
  \$\$;
" 2>&1 | grep -c "CHECK\|check_violation\|violates check constraint" || true)
check "Empty story text rejected by CHECK constraint" "1" "$empty_result"

# ─── 6. Story soft-delete vs hard-delete ─────────────────────────────────────
echo ""
echo "=== 6. Story Soft-Delete ==="

# Create a test story to soft-delete
run_sql "
  INSERT INTO drift_stories (id, user_id, emoji, text, city)
  VALUES (
    'a4000099-0000-4000-a000-000000000099',
    '$ALICE_ID', '🗑', 'This story will be deleted', 'London'
  ) ON CONFLICT (id) DO NOTHING;
" > /dev/null

# Soft-delete by setting deleted_at
run_sql "
  UPDATE drift_stories SET deleted_at = now()
  WHERE id = 'a4000099-0000-4000-a000-000000000099';
" > /dev/null

# stories_select_public requires deleted_at IS NULL
visible=$(curl -sS \
  -H "Authorization: Bearer $TOK_BOB" \
  -H "apikey: $APIKEY" \
  "$BASE/drift_stories?id=eq.a4000099-0000-4000-a000-000000000099" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")
check "Soft-deleted story invisible to others" "0" "$visible"

# Cleanup
run_sql "DELETE FROM drift_stories WHERE id = 'a4000099-0000-4000-a000-000000000099';" > /dev/null

echo ""
echo "============================================"
echo "Moderation Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $(( FAIL > 0 ? 1 : 0 ))
