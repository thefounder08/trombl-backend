import { handleCors } from '../_shared/cors.ts';
import { requireAuth, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { isUuid, isLatitude, isLongitude, clamp, requireFields } from '../_shared/validation.ts';
import { assertEnv, getEnv } from '../_shared/env.ts';

assertEnv();

interface CreateSessionBody {
  activity_type_id: string;
  openness: string;
  timeframe: string;
  vibe_note?: string;
  vibe_tags?: string[];
  radius_km?: number;
  latitude: number;
  longitude: number;
  city: string;
}

const VALID_OPENNESS  = ['open', 'maybe', 'solo'] as const;
const VALID_TIMEFRAME = ['now', 'next_hour', 'this_morning', 'this_afternoon', 'this_evening'] as const;

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

  const validated = requireFields<CreateSessionBody>(body, [
    'activity_type_id', 'openness', 'timeframe', 'latitude', 'longitude', 'city',
  ]);
  if (typeof validated === 'string') {
    return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
  }

  const {
    activity_type_id, openness, timeframe, vibe_note, vibe_tags,
    radius_km, latitude, longitude, city,
  } = validated;

  if (!isUuid(activity_type_id)) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'activity_type_id must be a valid UUID', 400);
  }
  if (!VALID_OPENNESS.includes(openness as typeof VALID_OPENNESS[number])) {
    return errorResponse('VALIDATION_INVALID_FIELD', `openness must be one of: ${VALID_OPENNESS.join(', ')}`, 400);
  }
  if (!VALID_TIMEFRAME.includes(timeframe as typeof VALID_TIMEFRAME[number])) {
    return errorResponse('VALIDATION_INVALID_FIELD', `timeframe must be one of: ${VALID_TIMEFRAME.join(', ')}`, 400);
  }
  if (!isLatitude(latitude) || !isLongitude(longitude)) {
    return errorResponse('GEO_INVALID_COORDINATES', 'latitude/longitude out of range', 400);
  }
  if (typeof city !== 'string' || city.trim().length < 1 || city.trim().length > 100) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'city must be 1-100 characters', 400);
  }

  const { drift } = getEnv();
  const safeRadius = clamp(radius_km ?? drift.defaultRadiusKm, 0.5, drift.maxRadiusKm);

  const { count } = await adminClient
    .from('drift_sessions')
    .select('id', { count: 'exact', head: true })
    .eq('host_user_id', userId)
    .eq('status', 'active');

  if ((count ?? 0) >= 1) {
    return errorResponse(
      'DRIFT_SESSION_LIMIT',
      'You already have an active session. End it before creating a new one.',
      409
    );
  }

  const { data: activityType, error: activityError } = await adminClient
    .from('drift_activity_types')
    .select('id')
    .eq('id', activity_type_id)
    .eq('is_active', true)
    .single();

  if (activityError || !activityType) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'activity_type_id not found or inactive', 400);
  }

  const locationWkt = `SRID=4326;POINT(${longitude} ${latitude})`;

  const { data: session, error: insertError } = await adminClient
    .from('drift_sessions')
    .insert({
      host_user_id:      userId,
      activity_type_id,
      openness,
      timeframe,
      vibe_note:         vibe_note?.trim().slice(0, 200) ?? null,
      vibe_tags:         vibe_tags ?? [],
      radius_km:         safeRadius,
      location_snapshot: locationWkt,
      city:              city.trim(),
      status:            'active',
    })
    .select('id, activity_type_id, openness, timeframe, status, radius_km, city, expires_at, created_at')
    .single();

  if (insertError) {
    console.error('[drift-create-session] insert error:', insertError);
    return errorResponse('SYSTEM_DB_ERROR', 'Failed to create session', 500);
  }

  await adminClient.rpc('upsert_user_location', {
    p_user_id:   userId,
    p_latitude:  latitude,
    p_longitude: longitude,
  });

  return jsonResponse({ success: true, session }, 201);
});
