-- ============================================================
-- Migration: 00005_drift_location_table
-- Description: Geo-location tracking for drift discovery
-- Uses PostGIS geometry for efficient spatial queries.
-- ============================================================

CREATE TABLE public.drift_user_locations (
  id               uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id          uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,

  -- PostGIS point: SRID 4326 = WGS84 (standard GPS coordinates)
  location         geometry(Point, 4326) NOT NULL,

  -- Denormalized for fast non-geo queries
  latitude         double precision NOT NULL,
  longitude        double precision NOT NULL,

  accuracy_meters  double precision,
  city             text,
  country_code     char(2),

  -- TTL: location auto-expires after 15 minutes of inactivity
  expires_at       timestamptz NOT NULL DEFAULT (now() + interval '15 minutes'),

  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  -- One active location row per user
  CONSTRAINT drift_user_locations_one_per_user UNIQUE (user_id)
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────

-- GiST spatial index — critical for ST_DWithin performance
CREATE INDEX drift_user_locations_gist_idx
  ON drift_user_locations USING GIST (location);

-- Filter expired locations quickly
CREATE INDEX drift_user_locations_expires_idx
  ON drift_user_locations (expires_at);

-- Lookup by user
CREATE INDEX drift_user_locations_user_idx
  ON drift_user_locations (user_id);

-- Composite: active (non-expired) spatial queries
CREATE INDEX drift_user_locations_active_gist_idx
  ON drift_user_locations USING GIST (location)
  WHERE expires_at > now();

-- ─── Auto-update trigger ─────────────────────────────────────────────────────

CREATE TRIGGER drift_user_locations_updated_at
  BEFORE UPDATE ON drift_user_locations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Refresh expires_at on every upsert
CREATE OR REPLACE FUNCTION public.refresh_location_expiry()
RETURNS TRIGGER AS $$
BEGIN
  NEW.expires_at := now() + interval '15 minutes';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER drift_user_locations_refresh_expiry
  BEFORE INSERT OR UPDATE ON drift_user_locations
  FOR EACH ROW EXECUTE FUNCTION public.refresh_location_expiry();

-- ─── Geo Helper Functions ─────────────────────────────────────────────────────

-- Upsert user location (called by Edge Function)
CREATE OR REPLACE FUNCTION public.upsert_user_location(
  p_user_id       uuid,
  p_latitude      double precision,
  p_longitude     double precision,
  p_accuracy      double precision DEFAULT NULL,
  p_city          text DEFAULT NULL,
  p_country_code  char(2) DEFAULT NULL
)
RETURNS void AS $$
BEGIN
  INSERT INTO drift_user_locations (
    user_id, location, latitude, longitude,
    accuracy_meters, city, country_code
  )
  VALUES (
    p_user_id,
    ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326),
    p_latitude,
    p_longitude,
    p_accuracy,
    p_city,
    p_country_code
  )
  ON CONFLICT (user_id) DO UPDATE SET
    location        = EXCLUDED.location,
    latitude        = EXCLUDED.latitude,
    longitude       = EXCLUDED.longitude,
    accuracy_meters = EXCLUDED.accuracy_meters,
    city            = COALESCE(EXCLUDED.city, drift_user_locations.city),
    country_code    = COALESCE(EXCLUDED.country_code, drift_user_locations.country_code),
    updated_at      = now(),
    expires_at      = now() + interval '15 minutes';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Find nearby active drift sessions within a radius
CREATE OR REPLACE FUNCTION public.find_nearby_users(
  p_latitude   double precision,
  p_longitude  double precision,
  p_radius_km  double precision DEFAULT 2.0,
  p_limit      int DEFAULT 50,
  p_exclude_user_id uuid DEFAULT NULL
)
RETURNS TABLE (
  user_id         uuid,
  display_name    text,
  avatar_url      text,
  drift_vibe_tags text[],
  drift_openness  public.drift_openness,
  activity_emoji  text,
  activity_label  text,
  session_id      uuid,
  distance_km     double precision
) AS $$
DECLARE
  search_point geometry := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326);
BEGIN
  RETURN QUERY
  SELECT
    p.id                                                        AS user_id,
    p.display_name,
    p.avatar_url,
    p.drift_vibe_tags,
    p.drift_openness,
    a.emoji                                                     AS activity_emoji,
    a.label                                                     AS activity_label,
    ds.id                                                       AS session_id,
    (ST_Distance(ul.location::geography, search_point::geography) / 1000.0)::double precision AS distance_km
  FROM drift_user_locations ul
  JOIN trombl_profiles p         ON p.id = ul.user_id
  JOIN drift_sessions ds         ON ds.host_user_id = ul.user_id
  JOIN drift_activity_types a    ON a.id = ds.activity_type_id
  WHERE
    -- Within radius
    ST_DWithin(ul.location::geography, search_point::geography, p_radius_km * 1000)
    -- Location not expired
    AND ul.expires_at > now()
    -- Session is active
    AND ds.status = 'active'
    AND ds.expires_at > now()
    -- Profile is active
    AND p.deleted_at IS NULL
    AND p.is_banned = false
    -- User is open to drift
    AND p.drift_openness != 'solo'
    AND p.location_sharing_enabled = true
    -- Exclude self
    AND (p_exclude_user_id IS NULL OR ul.user_id != p_exclude_user_id)
    -- Exclude blocked users (bidirectional)
    AND NOT EXISTS (
      SELECT 1 FROM trombl_blocked_users b
      WHERE (b.blocker_id = p_exclude_user_id AND b.blocked_id = ul.user_id)
         OR (b.blocker_id = ul.user_id AND b.blocked_id = p_exclude_user_id)
    )
  ORDER BY distance_km ASC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- City-level discovery: find drifts within a city bounding box or named city
CREATE OR REPLACE FUNCTION public.find_city_drifts(
  p_city       text,
  p_limit      int DEFAULT 100
)
RETURNS TABLE (
  session_id      uuid,
  user_id         uuid,
  activity_emoji  text,
  activity_label  text,
  drift_openness  public.drift_openness,
  participant_count int,
  started_at      timestamptz
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    ds.id             AS session_id,
    ds.host_user_id   AS user_id,
    a.emoji           AS activity_emoji,
    a.label           AS activity_label,
    p.drift_openness,
    ds.participant_count,
    ds.started_at
  FROM drift_sessions ds
  JOIN drift_activity_types a ON a.id = ds.activity_type_id
  JOIN trombl_profiles p      ON p.id = ds.host_user_id
  WHERE
    ds.city = p_city
    AND ds.status = 'active'
    AND ds.expires_at > now()
    AND p.deleted_at IS NULL
    AND p.is_banned = false
  ORDER BY ds.started_at DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Cleanup expired locations (called by scheduled job)
CREATE OR REPLACE FUNCTION public.cleanup_expired_locations()
RETURNS int AS $$
DECLARE
  deleted_count int;
BEGIN
  DELETE FROM drift_user_locations
  WHERE expires_at < now();
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON TABLE drift_user_locations IS
  'Ephemeral user geo-locations. TTL 15 minutes. One row per user (upsert). Never stored historically.';
