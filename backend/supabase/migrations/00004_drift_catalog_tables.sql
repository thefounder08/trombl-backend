-- ============================================================
-- Migration: 00004_drift_catalog_tables
-- Description: Drift activity types and vibe tags (reference data)
-- ============================================================

-- ─── drift_activity_types ────────────────────────────────────────────────────

CREATE TABLE public.drift_activity_types (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  emoji       text NOT NULL,
  label       text NOT NULL UNIQUE,
  sub_label   text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  sort_order  int NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX drift_activity_types_active_idx
  ON drift_activity_types (sort_order)
  WHERE is_active = true;

COMMENT ON TABLE drift_activity_types IS 'Catalog of available drift activities. Managed by admins.';

-- ─── drift_vibe_tags ─────────────────────────────────────────────────────────

CREATE TABLE public.drift_vibe_tags (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  label       text NOT NULL UNIQUE,
  is_active   boolean NOT NULL DEFAULT true,
  sort_order  int NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE drift_vibe_tags IS 'Catalog of vibe tags for drift sessions and profiles.';
