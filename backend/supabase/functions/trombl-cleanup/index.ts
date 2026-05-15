import { makeAdminClient, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { assertEnv, getEnv } from '../_shared/env.ts';

// Validate environment at cold-start — fail loudly rather than silently
assertEnv();

// This function is called by a Supabase cron schedule (every 5 minutes).
// Authorization uses a shared CRON_SECRET — NOT a user JWT.
// The secret is set via `supabase secrets set CRON_SECRET=...` and never
// committed to the repository or exposed to the Flutter client.

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const env = getEnv();
  const authHeader = req.headers.get('Authorization') ?? '';
  const expectedSecret = `Bearer ${env.cronSecret}`;

  if (authHeader !== expectedSecret) {
    return errorResponse('AUTH_FORBIDDEN', 'Invalid cron secret', 403);
  }

  if (req.method !== 'POST') {
    return errorResponse('METHOD_NOT_ALLOWED', 'POST only', 405);
  }

  const adminClient = makeAdminClient();

  const { data, error } = await adminClient.rpc('run_scheduled_cleanup');

  if (error) {
    console.error('[trombl-cleanup] rpc error:', error);
    return errorResponse('SYSTEM_DB_ERROR', 'Cleanup job failed', 500);
  }

  return jsonResponse({ success: true, result: data });
});
