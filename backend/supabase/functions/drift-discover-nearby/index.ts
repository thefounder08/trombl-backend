import { handleCors } from '../_shared/cors.ts';
import { requireAuth, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { isLatitude, isLongitude, clamp } from '../_shared/validation.ts';
import { assertEnv, getEnv } from '../_shared/env.ts';

assertEnv();

const MIN_RADIUS_KM  = 0.5;
const MAX_LIMIT      = 100;

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const auth = await requireAuth(req);
  if (auth instanceof Response) return auth;
  const { userId, adminClient } = auth;

  if (req.method !== 'POST') {
    return errorResponse('METHOD_NOT_ALLOWED', 'POST only', 405);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return errorResponse('VALIDATION_INVALID_JSON', 'Invalid JSON body', 400);
  }

  const b = body as Record<string, unknown>;
  const latitude  = b.latitude  as number;
  const longitude = b.longitude as number;

  if (!isLatitude(latitude) || !isLongitude(longitude)) {
    return errorResponse('GEO_INVALID_COORDINATES', 'Valid latitude and longitude are required', 400);
  }

  const { drift } = getEnv();
  const radiusKm = clamp(
    Number(b.radius_km ?? drift.defaultRadiusKm),
    MIN_RADIUS_KM,
    drift.maxRadiusKm
  );
  const limitVal = clamp(Number(b.limit ?? 30), 1, MAX_LIMIT);

  // Upsert the requester's location so they appear in others' feeds
  await adminClient.rpc('upsert_user_location', {
    p_user_id:   userId,
    p_latitude:  latitude,
    p_longitude: longitude,
  });

  // SECURITY DEFINER function — bypasses RLS, filters blocked users and solo-mode users
  const { data: nearbyUsers, error } = await adminClient.rpc('find_nearby_users', {
    p_latitude:        latitude,
    p_longitude:       longitude,
    p_radius_km:       radiusKm,
    p_limit:           limitVal,
    p_exclude_user_id: userId,
  });

  if (error) {
    console.error('[drift-discover-nearby] rpc error:', error);
    return errorResponse('SYSTEM_DB_ERROR', 'Failed to fetch nearby users', 500);
  }

  const users = (nearbyUsers ?? []) as Record<string, unknown>[];

  return jsonResponse({
    success:   true,
    users,
    total:     users.length,
    radius_km: radiusKm,
    latitude,
    longitude,
  });
});
