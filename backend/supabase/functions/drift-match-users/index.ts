import { handleCors } from '../_shared/cors.ts';
import { requireAuth, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { isUuid, requireFields } from '../_shared/validation.ts';
import { createNotification, sendPushNotification } from '../_shared/notifications.ts';
import { assertEnv, getEnv } from '../_shared/env.ts';

assertEnv();

interface MatchRequestBody {
  target_id: string;
  session_id?: string;
  action?: 'send' | 'accept' | 'decline';
}


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

  const validated = requireFields<MatchRequestBody>(body, ['target_id']);
  if (typeof validated === 'string') {
    return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
  }

  const { target_id, session_id, action = 'send' } = validated;

  if (!isUuid(target_id)) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'target_id must be a valid UUID', 400);
  }
  if (target_id === userId) {
    return errorResponse('DRIFT_SELF_MATCH', 'Cannot match yourself', 400);
  }

  // ── Handle accept/decline actions ────────────────────────────────────────
  if (action === 'accept' || action === 'decline') {
    const { data: match, error: findError } = await adminClient
      .from('drift_matches')
      .select('id, status, initiator_id, target_id')
      .eq('initiator_id', target_id)
      .eq('target_id', userId)
      .eq('status', 'pending')
      .gt('expires_at', new Date().toISOString())
      .single();

    if (findError || !match) {
      return errorResponse('DRIFT_MATCH_NOT_FOUND', 'No pending match request found', 404);
    }

    const newStatus = action === 'accept' ? 'accepted' : 'declined';
    const { data: updated, error: updateError } = await adminClient
      .from('drift_matches')
      .update({ status: newStatus })
      .eq('id', match.id)
      .select('id, status, initiator_id, target_id, accepted_at, expires_at')
      .single();

    if (updateError) {
      console.error('drift-match-users update error:', updateError);
      return errorResponse('SYSTEM_DB_ERROR', 'Failed to update match', 500);
    }

    const notifType = action === 'accept' ? 'drift_match_accepted' : 'drift_match_declined';
    const notifTitle = action === 'accept' ? 'Drift match accepted!' : 'Match declined';
    const notifBody  = action === 'accept'
      ? 'Your match was accepted. Exchange contact if you want to meet up!'
      : 'The other person passed on this one.';

    await Promise.all([
      createNotification({
        adminClient, userId: match.initiator_id, type: notifType,
        title: notifTitle, body: notifBody,
        data: { match_id: match.id },
        expiresInHours: 24,
      }),
      sendPushNotification(match.initiator_id, adminClient, notifTitle, notifBody, { match_id: match.id }),
    ]);

    return jsonResponse({ success: true, match: updated });
  }

  // ── Send new match request ────────────────────────────────────────────────

  // Check target user exists, is not banned, and is not blocked
  const { data: targetProfile } = await adminClient
    .from('trombl_profiles')
    .select('id, is_banned, drift_openness')
    .eq('id', target_id)
    .eq('is_banned', false)
    .is('deleted_at', null)
    .single();

  if (!targetProfile) {
    return errorResponse('DRIFT_TARGET_NOT_FOUND', 'Target user not found or unavailable', 404);
  }
  if (targetProfile.drift_openness === 'solo') {
    return errorResponse('DRIFT_TARGET_SOLO', 'This user is currently in solo mode', 409);
  }

  // Block check
  const { data: blockCheck } = await adminClient.rpc('is_blocked', {
    user_a: userId,
    user_b: target_id,
  });
  if (blockCheck) {
    return errorResponse('DRIFT_BLOCKED', 'Cannot match — block relationship exists', 403);
  }

  // Trust score check on initiator
  const { data: trustScore } = await adminClient
    .from('drift_trust_scores')
    .select('score')
    .eq('user_id', userId)
    .single();

  const { drift } = getEnv();

  if (trustScore && trustScore.score < drift.minTrustScoreToMatch) {
    return errorResponse(
      'DRIFT_LOW_TRUST',
      'Your trust score is too low to send match requests',
      403
    );
  }

  // Check for existing active match
  const { data: existingMatch } = await adminClient.rpc('get_active_match', {
    p_user_a: userId,
    p_user_b: target_id,
  });
  if (existingMatch) {
    return errorResponse('DRIFT_MATCH_EXISTS', 'An active match already exists', 409);
  }

  // Check pending rate limit
  const { count: pendingCount } = await adminClient
    .from('drift_matches')
    .select('id', { count: 'exact', head: true })
    .eq('initiator_id', userId)
    .eq('status', 'pending')
    .gt('expires_at', new Date().toISOString());

  if ((pendingCount ?? 0) >= drift.maxPendingMatchesPerUser) {
    return errorResponse('RATE_LIMIT_MATCH_REQUESTS', 'Too many pending match requests', 429);
  }

  const insertPayload: Record<string, unknown> = {
    initiator_id: userId,
    target_id,
    status: 'pending',
  };
  if (session_id && isUuid(session_id)) {
    insertPayload.session_id = session_id;
  }

  const { data: match, error: insertError } = await adminClient
    .from('drift_matches')
    .insert(insertPayload)
    .select('id, status, initiator_id, target_id, expires_at, created_at')
    .single();

  if (insertError) {
    console.error('drift-match-users insert error:', insertError);
    return errorResponse('SYSTEM_DB_ERROR', 'Failed to create match request', 500);
  }

  // Get initiator display info for notification
  const { data: initiatorProfile } = await adminClient
    .from('trombl_profiles')
    .select('username, display_name')
    .eq('id', userId)
    .single();

  const displayName = initiatorProfile?.display_name ?? initiatorProfile?.username ?? 'Someone';

  await Promise.all([
    createNotification({
      adminClient, userId: target_id, type: 'drift_match_request',
      title: 'New Drift match request',
      body: `${displayName} wants to drift with you`,
      data: { match_id: match.id, initiator_id: userId },
      expiresInHours: 1,
    }),
    sendPushNotification(
      target_id, adminClient,
      'New Drift match',
      `${displayName} wants to drift with you`,
      { match_id: match.id }
    ),
  ]);

  return jsonResponse({ success: true, match }, 201);
});
