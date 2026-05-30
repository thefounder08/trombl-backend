-- ============================================================
-- Migration: 00001_extensions_and_config
-- Description: Enable required PostgreSQL extensions
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable cryptographic functions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Enable PostGIS for geo-spatial queries
CREATE EXTENSION IF NOT EXISTS "postgis";

-- Enable PostGIS topology
CREATE EXTENSION IF NOT EXISTS "postgis_topology";

-- Enable fuzzy string matching (for future search features)
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Enable unaccent for text normalization
CREATE EXTENSION IF NOT EXISTS "unaccent";

-- ─── Shared Utility Functions ───────────────────────────────────────────────

-- Returns the authenticated user's UUID from the JWT
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE
  AS $$
  SELECT COALESCE(
    current_setting('request.jwt.claim.sub', true),
    (current_setting('request.jwt.claims', true)::jsonb->>'sub')
  )::uuid
$$;

-- Returns the JWT role
CREATE OR REPLACE FUNCTION auth.role() RETURNS text
  LANGUAGE sql STABLE
  AS $$
  SELECT COALESCE(
    current_setting('request.jwt.claim.role', true),
    (current_setting('request.jwt.claims', true)::jsonb->>'role')
  )::text
$$;

-- Automatically set updated_at on row update
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Generate a short human-readable code (for session codes etc.)
CREATE OR REPLACE FUNCTION public.generate_short_code(length int DEFAULT 6)
RETURNS text AS $$
DECLARE
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text := '';
  i int;
BEGIN
  FOR i IN 1..length LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Soft-delete helper: sets deleted_at = now()
CREATE OR REPLACE FUNCTION public.soft_delete()
RETURNS TRIGGER AS $$
BEGIN
  NEW.deleted_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Check if a user is blocked (bidirectional)
CREATE OR REPLACE FUNCTION public.is_blocked(user_a uuid, user_b uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM trombl_blocked_users
    WHERE (blocker_id = user_a AND blocked_id = user_b)
       OR (blocker_id = user_b AND blocked_id = user_a)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Get distance in km between two points (helper)
CREATE OR REPLACE FUNCTION public.distance_km(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision
)
RETURNS double precision AS $$
  SELECT ST_Distance(
    ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)::geography,
    ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)::geography
  ) / 1000.0
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
