/**
 * Firebase Cloud Messaging (FCM) v1 API client for Deno Edge Functions.
 *
 * Uses the FCM HTTP v1 API:
 *   POST https://fcm.googleapis.com/v1/projects/{project_id}/messages:send
 *
 * Auth: Google OAuth2 via a service account JWT (RS256).
 * The legacy FCM API (server key) was deprecated June 2024 and will be
 * shut down. This implementation uses the current v1 API only.
 *
 * Required env var:
 *   FCM_SERVICE_ACCOUNT_JSON — the full Firebase service account JSON, pasted
 *   as a single line (or with literal \n newlines in the private_key field).
 *   Obtain from Firebase Console → Project Settings → Service Accounts.
 */

interface ServiceAccount {
  type:                        string;
  project_id:                  string;
  private_key_id:              string;
  private_key:                 string;
  client_email:                string;
  client_id:                   string;
  auth_uri:                    string;
  token_uri:                   string;
  auth_provider_x509_cert_url: string;
  client_x509_cert_url:        string;
}

interface FcmTokenCache {
  accessToken: string;
  expiresAt:   number; // Unix timestamp (ms)
}

// Module-level cache so the token survives across requests on a warm instance
let _tokenCache: FcmTokenCache | null = null;
let _serviceAccount: ServiceAccount | null = null;

// ─── Service account parsing ──────────────────────────────────────────────────

function parseServiceAccount(): ServiceAccount | null {
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON');
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ServiceAccount;
  } catch {
    console.error('[fcm] FCM_SERVICE_ACCOUNT_JSON is not valid JSON');
    return null;
  }
}

// ─── JWT construction (RS256) ─────────────────────────────────────────────────

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (const b of arr) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function base64urlJson(obj: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s/g, '');
  const binary = atob(b64);
  const buf = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
  return buf.buffer;
}

async function buildServiceAccountJwt(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  const header  = base64urlJson({ alg: 'RS256', typ: 'JWT' });
  const payload = base64urlJson({
    iss:   sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud:   'https://oauth2.googleapis.com/token',
    iat:   now,
    exp:   now + 3600,
  });

  const unsigned  = `${header}.${payload}`;
  const keyBuffer = pemToArrayBuffer(sa.private_key);

  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBuffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  );

  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(unsigned)
  );

  return `${unsigned}.${base64url(signature)}`;
}

// ─── OAuth2 token exchange ────────────────────────────────────────────────────

async function fetchAccessToken(sa: ServiceAccount): Promise<FcmTokenCache> {
  const jwt = await buildServiceAccountJwt(sa);

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion:  jwt,
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`[fcm] OAuth2 token exchange failed (${res.status}): ${text}`);
  }

  const data = await res.json() as { access_token: string; expires_in: number };
  return {
    accessToken: data.access_token,
    // Refresh 5 minutes before actual expiry
    expiresAt: Date.now() + (data.expires_in - 300) * 1000,
  };
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  if (_tokenCache && Date.now() < _tokenCache.expiresAt) {
    return _tokenCache.accessToken;
  }
  _tokenCache = await fetchAccessToken(sa);
  return _tokenCache.accessToken;
}

// ─── FCM v1 send ─────────────────────────────────────────────────────────────

export interface FcmSendResult {
  token:   string;
  success: boolean;
  error?:  string;
}

/**
 * Sends a single FCM notification to one device token.
 * Returns success/error per token — never throws.
 */
async function sendOne(
  sa:          ServiceAccount,
  deviceToken: string,
  title:       string,
  body:        string,
  data:        Record<string, string>
): Promise<FcmSendResult> {
  const accessToken = await getAccessToken(sa);
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

  const message = {
    message: {
      token: deviceToken,
      notification: { title, body },
      data,
      // Platform-specific config
      android: {
        priority: 'high',
        notification: { sound: 'default', channel_id: 'trombl_default' },
      },
      apns: {
        payload: { aps: { sound: 'default', badge: 1 } },
        headers: { 'apns-priority': '10' },
      },
    },
  };

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type':  'application/json',
        'Authorization': `Bearer ${accessToken}`,
      },
      body: JSON.stringify(message),
    });

    if (res.ok) {
      return { token: deviceToken, success: true };
    }

    const errBody = await res.json().catch(() => ({})) as Record<string, unknown>;
    const errMsg  = (errBody?.error as Record<string, unknown>)?.message as string ?? res.statusText;

    // Stale/invalid token — mark for cleanup
    if (res.status === 404 || (errMsg ?? '').includes('UNREGISTERED')) {
      return { token: deviceToken, success: false, error: 'UNREGISTERED' };
    }

    return { token: deviceToken, success: false, error: errMsg };
  } catch (err) {
    return { token: deviceToken, success: false, error: (err as Error).message };
  }
}

/**
 * Sends an FCM notification to all of a user's registered device tokens.
 * Automatically deactivates tokens that FCM reports as unregistered.
 *
 * @param tokens   Array of { token, id } from trombl_push_tokens
 * @param adminClient  Supabase admin client (to deactivate stale tokens)
 */
export async function sendFcmToTokens(
  tokens: Array<{ token: string; id: string }>,
  title:  string,
  body:   string,
  data:   Record<string, string>,
  // deno-lint-ignore no-explicit-any
  adminClient: any
): Promise<void> {
  if (tokens.length === 0) return;

  if (!_serviceAccount) {
    _serviceAccount = parseServiceAccount();
  }
  if (!_serviceAccount) {
    console.warn('[fcm] FCM_SERVICE_ACCOUNT_JSON not set — push notifications disabled');
    return;
  }

  const sa = _serviceAccount;
  const results = await Promise.allSettled(
    tokens.map((t) => sendOne(sa, t.token, title, body, data))
  );

  // Deactivate unregistered tokens so we stop sending to them
  const staleIds: string[] = [];
  for (let i = 0; i < results.length; i++) {
    const result = results[i];
    if (result.status === 'fulfilled' && result.value.error === 'UNREGISTERED') {
      staleIds.push(tokens[i].id);
    } else if (result.status === 'rejected') {
      console.error('[fcm] sendOne rejected:', result.reason);
    }
  }

  if (staleIds.length > 0) {
    await adminClient
      .from('trombl_push_tokens')
      .update({ is_active: false })
      .in('id', staleIds);
  }
}

/**
 * Returns true if FCM is configured (FCM_SERVICE_ACCOUNT_JSON is set).
 * Use this to skip push notification code paths in tests/dev when Firebase
 * isn't set up yet.
 */
export function isFcmConfigured(): boolean {
  return !!Deno.env.get('FCM_SERVICE_ACCOUNT_JSON');
}
