import { SupabaseClient } from '@supabase/supabase-js';
import { sendFcmToTokens, isFcmConfigured } from './fcm.ts';

// Values must match the trombl_notification_type enum in 00002_enums.sql exactly.
type NotificationType =
  | 'drift_nearby'
  | 'drift_match_request'
  | 'drift_match_accepted'
  | 'drift_match_declined'
  | 'drift_session_expiring'
  | 'drift_contact_revealed'
  | 'drift_story_reaction'
  | 'safety_alert'
  | 'system';

interface CreateNotificationParams {
  adminClient:    SupabaseClient;
  userId:         string;
  type:           NotificationType;
  title:          string;
  body:           string;
  data?:          Record<string, unknown>;
  expiresInHours?: number;
}

/**
 * Inserts a notification row visible to the target user via RLS.
 * Triggers the Supabase Realtime `trombl:notifications:{userId}` channel.
 */
export async function createNotification({
  adminClient,
  userId,
  type,
  title,
  body,
  data,
  expiresInHours,
}: CreateNotificationParams): Promise<void> {
  const expiresAt = expiresInHours
    ? new Date(Date.now() + expiresInHours * 60 * 60 * 1000).toISOString()
    : null;

  const { error } = await adminClient.from('trombl_notifications').insert({
    user_id:    userId,
    type,
    title,
    body,
    data:       data ?? null,
    expires_at: expiresAt,
  });

  if (error) {
    console.error('[notifications] createNotification failed:', error.message);
  }
}

/**
 * Sends a push notification via Firebase Cloud Messaging (FCM v1 API).
 *
 * Token lifecycle:
 *   - FCM device tokens are registered by the Flutter app via trombl_push_tokens.
 *   - Tokens FCM reports as UNREGISTERED (app uninstalled / re-installed) are
 *     automatically deactivated so we never send to stale tokens again.
 *
 * If FCM_SERVICE_ACCOUNT_JSON is not set (e.g. local dev without Firebase),
 * this function is a no-op — the in-app notification from createNotification()
 * still works via Supabase Realtime.
 *
 * @param data  Values must be strings — FCM data payload only supports strings.
 */
export async function sendPushNotification(
  userId:      string,
  adminClient: SupabaseClient,
  title:       string,
  body:        string,
  data?:       Record<string, unknown>
): Promise<void> {
  if (!isFcmConfigured()) return;

  const { data: tokens, error } = await adminClient
    .from('trombl_push_tokens')
    .select('id, token')
    .eq('user_id', userId)
    .eq('is_active', true);

  if (error) {
    console.error('[notifications] token lookup failed:', error.message);
    return;
  }
  if (!tokens || tokens.length === 0) return;

  // FCM data payload values must all be strings
  const stringData: Record<string, string> = {};
  for (const [k, v] of Object.entries(data ?? {})) {
    stringData[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }

  await sendFcmToTokens(
    tokens as Array<{ token: string; id: string }>,
    title,
    body,
    stringData,
    adminClient
  );
}
