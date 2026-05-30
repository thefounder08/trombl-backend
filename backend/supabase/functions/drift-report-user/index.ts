import { handleCors } from '../_shared/cors.ts';
import { requireAuth, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { isUuid, requireFields } from '../_shared/validation.ts';
import { assertEnv } from '../_shared/env.ts';

assertEnv();

// Values must match the drift_report_reason enum in 00002_enums.sql exactly.
type ReportReason =
  | 'made_me_feel_unsafe'
  | 'harassment'
  | 'inappropriate_behaviour'
  | 'fake_profile'
  | 'spam'
  | 'didnt_show_up'
  | 'other';

interface ReportBody {
  reported_id:   string;
  reason:        ReportReason;
  custom_reason?: string;
  match_id?:     string;
  session_id?:   string;
  story_id?:     string;
}

const VALID_REASONS: ReportReason[] = [
  'made_me_feel_unsafe',
  'harassment',
  'inappropriate_behaviour',
  'fake_profile',
  'spam',
  'didnt_show_up',
  'other',
];

const REPORT_RATE_LIMIT_PER_TARGET = 1; // 1 report per user pair per 7 days
const REPORT_RATE_LIMIT_GLOBAL = 10;    // 10 reports per day from one user

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

  const validated = requireFields<ReportBody>(body, ['reported_id', 'reason']);
  if (typeof validated === 'string') {
    return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
  }

  const { reported_id, reason, custom_reason, match_id, session_id, story_id } = validated;

  if (!isUuid(reported_id)) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'reported_id must be a valid UUID', 400);
  }
  if (reported_id === userId) {
    return errorResponse('DRIFT_SELF_REPORT', 'Cannot report yourself', 400);
  }
  if (!VALID_REASONS.includes(reason)) {
    return errorResponse('VALIDATION_INVALID_FIELD', `reason must be one of: ${VALID_REASONS.join(', ')}`, 400);
  }
  if (reason === 'other' && (!custom_reason || custom_reason.trim().length === 0)) {
    return errorResponse('VALIDATION_MISSING_FIELD', 'custom_reason is required when reason is "other"', 400);
  }
  if (custom_reason && custom_reason.length > 500) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'custom_reason must be ≤ 500 characters', 400);
  }

  // Verify reported user exists
  const { data: reportedProfile } = await adminClient
    .from('trombl_profiles')
    .select('id')
    .eq('id', reported_id)
    .is('deleted_at', null)
    .single();

  if (!reportedProfile) {
    return errorResponse('DRIFT_TARGET_NOT_FOUND', 'Reported user not found', 404);
  }

  // Rate limit: 1 report per pair per 7 days
  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const { count: pairCount } = await adminClient
    .from('drift_reports')
    .select('id', { count: 'exact', head: true })
    .eq('reporter_id', userId)
    .eq('reported_id', reported_id)
    .gte('created_at', sevenDaysAgo);

  if ((pairCount ?? 0) >= REPORT_RATE_LIMIT_PER_TARGET) {
    return errorResponse(
      'RATE_LIMIT_REPORT',
      'You have already reported this user recently',
      429
    );
  }

  // Global rate limit: 10 reports per day
  const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { count: globalCount } = await adminClient
    .from('drift_reports')
    .select('id', { count: 'exact', head: true })
    .eq('reporter_id', userId)
    .gte('created_at', oneDayAgo);

  if ((globalCount ?? 0) >= REPORT_RATE_LIMIT_GLOBAL) {
    return errorResponse('RATE_LIMIT_REPORT', 'Too many reports submitted today', 429);
  }

  const insertPayload: Record<string, unknown> = {
    reporter_id:   userId,
    reported_id,
    reason,
    custom_reason: custom_reason?.trim() ?? null,
    status:        'open',
  };
  if (match_id   && isUuid(match_id))   insertPayload.match_id   = match_id;
  if (session_id && isUuid(session_id)) insertPayload.session_id = session_id;
  if (story_id   && isUuid(story_id))   insertPayload.story_id   = story_id;

  const { data: report, error: insertError } = await adminClient
    .from('drift_reports')
    .insert(insertPayload)
    .select('id, reason, status, created_at')
    .single();

  if (insertError) {
    console.error('drift-report-user insert error:', insertError);
    return errorResponse('SYSTEM_DB_ERROR', 'Failed to submit report', 500);
  }

  // Auto-block the reported user on the reporter's side
  // (safety measure — non-system block, user can undo if false alarm)
  await adminClient
    .from('trombl_blocked_users')
    .insert({ blocker_id: userId, blocked_id: reported_id, is_system_block: false })
    .then(() => {}) // ignore if block already exists
    .catch(() => {});

  return jsonResponse({
    success: true,
    report: {
      id:         report.id,
      status:     report.status,
      created_at: report.created_at,
    },
    message: 'Report submitted. The user has also been blocked.',
  }, 201);
});
