import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { corsHeaders } from './cors.ts';
import { getEnv } from './env.ts';

export interface AuthContext {
  userId: string;
  userClient: SupabaseClient;
  adminClient: SupabaseClient;
}

/**
 * Creates a Supabase client authenticated as the service role.
 * NEVER expose this client or its key to user-facing code.
 * Only for use inside Edge Functions and cron handlers.
 */
export function makeAdminClient(): SupabaseClient {
  const env = getEnv();
  return createClient(
    env.supabaseUrl,
    env.supabaseServiceRoleKey,
    { auth: { persistSession: false } }
  );
}

/**
 * Creates a Supabase client authenticated as the requesting user (via their JWT).
 * This client respects RLS — it can only see what the user is allowed to see.
 */
function makeUserClient(authHeader: string): SupabaseClient {
  const env = getEnv();
  return createClient(
    env.supabaseUrl,
    env.supabaseAnonKey,
    { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } }
  );
}

/**
 * Validates the Authorization header, resolves the Supabase user,
 * and checks for account bans. Returns an AuthContext on success
 * or a ready-to-return error Response on failure.
 */
export async function requireAuth(req: Request): Promise<AuthContext | Response> {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return errorResponse('AUTH_REQUIRED', 'Missing Authorization header', 401);
  }

  const userClient = makeUserClient(authHeader);

  const { data: { user }, error } = await userClient.auth.getUser();
  if (error || !user) {
    return errorResponse('AUTH_INVALID', 'Invalid or expired token', 401);
  }

  const adminClient = makeAdminClient();

  const { data: profile } = await adminClient
    .from('trombl_profiles')
    .select('is_banned')
    .eq('id', user.id)
    .single();

  if (profile?.is_banned) {
    return errorResponse('AUTH_BANNED', 'Account is suspended', 403);
  }

  return { userId: user.id, userClient, adminClient };
}

export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export function errorResponse(code: string, message: string, status: number): Response {
  return new Response(
    JSON.stringify({ error: code, message }),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}
