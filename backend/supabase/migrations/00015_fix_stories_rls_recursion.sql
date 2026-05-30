-- ============================================================
-- Migration: 00015_fix_stories_rls_recursion.sql
-- Fix: BUG-011 — infinite recursion in stories_update_own RLS
-- ============================================================
--
-- The BUG-005 fix in 00014 added a WITH CHECK that subqueries
-- drift_stories to verify is_flagged/is_removed have not changed.
-- This caused PostgreSQL error 42P17: "infinite recursion detected
-- in policy for relation drift_stories" on any UPDATE.
--
-- Root cause: the SELECT subquery inside WITH CHECK triggers
-- SELECT RLS policies on the same table, which in combination
-- with the in-progress UPDATE policy evaluation causes recursion.
--
-- Fix: SECURITY DEFINER helper functions bypass RLS when called,
-- breaking the recursive cycle. The same invariants are enforced
-- without self-referential policy evaluation.
-- ============================================================

-- Helper: read a story's protected fields without triggering RLS
-- SECURITY DEFINER means this runs as the function owner (postgres),
-- bypassing RLS on drift_stories and avoiding recursion.
CREATE OR REPLACE FUNCTION public.get_story_protected_fields(p_story_id uuid)
RETURNS TABLE(is_flagged boolean, is_removed boolean, user_id uuid, created_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT is_flagged, is_removed, user_id, created_at
  FROM drift_stories
  WHERE id = p_story_id;
$$;

-- Drop the recursive policy
DROP POLICY IF EXISTS stories_update_own ON drift_stories;

-- Recreate with SECURITY DEFINER function instead of subquery
CREATE POLICY stories_update_own ON drift_stories
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (
    user_id = auth.uid()
    AND is_flagged  = (SELECT f.is_flagged  FROM public.get_story_protected_fields(drift_stories.id) f)
    AND is_removed  = (SELECT f.is_removed  FROM public.get_story_protected_fields(drift_stories.id) f)
  );

-- Verify no recursion by testing a self-referencing plan would not loop
-- (this is just a comment — tested via live test_rls_live.sh)
