/// <reference lib="deno.ns" />

/**
 * Centralized environment configuration for Trombl Edge Functions.
 *
 * Security contract:
 *   - SUPABASE_SERVICE_ROLE_KEY  → server-only (Edge Functions, cron jobs)
 *   - SUPABASE_ANON_KEY          → client-safe (Flutter SDK initialization)
 *   - SUPABASE_URL               → client-safe
 *   - All other vars below       → server-only
 *
 * Never expose SERVICE_ROLE_KEY or CRON_SECRET to the Flutter client.
 * The Flutter app only needs SUPABASE_URL + SUPABASE_ANON_KEY.
 */

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ServerEnv {
  // Supabase connection
  supabaseUrl:            string;
  supabaseAnonKey:        string;
  supabaseServiceRoleKey: string;

  // Cron job security
  cronSecret: string;

  // Optional integrations
  moderationApiKey:       string | null;
  geoIpApiKey:            string | null;

  // App runtime
  appEnv:                 'development' | 'staging' | 'production';
  appName:                string;

  // Drift business logic (can be tuned per environment)
  drift: {
    defaultRadiusKm:              number;
    maxRadiusKm:                  number;
    sessionDurationHours:         number;
    contactExchangeWindowMinutes: number;
    locationTtlMinutes:           number;
    minTrustScoreToMatch:         number;
    maxPendingMatchesPerUser:      number;
    maxStoriesPerHour:             number;
  };
}

// ─── Validation ───────────────────────────────────────────────────────────────

class EnvValidationError extends Error {
  constructor(missing: string[], invalid: string[]) {
    const parts: string[] = [];
    if (missing.length)  parts.push(`Missing required env vars: ${missing.join(', ')}`);
    if (invalid.length)  parts.push(`Invalid env var values: ${invalid.join(', ')}`);
    super(`[Trombl] Environment validation failed.\n  ${parts.join('\n  ')}`);
    this.name = 'EnvValidationError';
  }
}

function require(name: string): string {
  const val = Deno.env.get(name);
  if (!val || val.trim() === '') return '';
  return val.trim();
}

function optional(name: string): string | null {
  const val = Deno.env.get(name);
  return (val && val.trim() !== '') ? val.trim() : null;
}

function requirePositiveNumber(name: string, fallback: number): number {
  const raw = Deno.env.get(name);
  if (!raw) return fallback;
  const n = Number(raw);
  return (Number.isFinite(n) && n > 0) ? n : fallback;
}

function parseAppEnv(raw: string | null): 'development' | 'staging' | 'production' {
  if (raw === 'staging' || raw === 'production') return raw;
  return 'development';
}

// ─── Singleton ────────────────────────────────────────────────────────────────

let _env: ServerEnv | null = null;

/**
 * Returns the validated server environment.
 * Throws EnvValidationError on first call if required vars are missing.
 * Subsequent calls return the cached, already-validated object.
 */
export function getEnv(): ServerEnv {
  if (_env) return _env;

  const missing: string[] = [];
  const invalid: string[] = [];

  // ── Required vars ──────────────────────────────────────────────────────────

  const supabaseUrl            = require('SUPABASE_URL');
  const supabaseAnonKey        = require('SUPABASE_ANON_KEY');
  const supabaseServiceRoleKey = require('SUPABASE_SERVICE_ROLE_KEY');
  const cronSecret             = require('CRON_SECRET');

  if (!supabaseUrl)            missing.push('SUPABASE_URL');
  if (!supabaseAnonKey)        missing.push('SUPABASE_ANON_KEY');
  if (!supabaseServiceRoleKey) missing.push('SUPABASE_SERVICE_ROLE_KEY');
  if (!cronSecret)             missing.push('CRON_SECRET');

  // Validate SUPABASE_URL format
  if (supabaseUrl && !supabaseUrl.startsWith('https://')) {
    invalid.push('SUPABASE_URL (must start with https://)');
  }

  // Validate keys look like JWTs (three dot-separated segments)
  if (supabaseAnonKey && supabaseAnonKey.split('.').length !== 3) {
    invalid.push('SUPABASE_ANON_KEY (does not look like a JWT)');
  }
  if (supabaseServiceRoleKey && supabaseServiceRoleKey.split('.').length !== 3) {
    invalid.push('SUPABASE_SERVICE_ROLE_KEY (does not look like a JWT)');
  }

  // Security guard: anon key must NOT equal service role key
  if (
    supabaseAnonKey && supabaseServiceRoleKey &&
    supabaseAnonKey === supabaseServiceRoleKey
  ) {
    invalid.push('SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY must be different keys');
  }

  if (missing.length > 0 || invalid.length > 0) {
    throw new EnvValidationError(missing, invalid);
  }

  // ── Optional vars with defaults ────────────────────────────────────────────

  const appEnvRaw = optional('APP_ENV');

  _env = {
    supabaseUrl,
    supabaseAnonKey,
    supabaseServiceRoleKey,
    cronSecret,
    moderationApiKey: optional('MODERATION_API_KEY'),
    geoIpApiKey:      optional('GEO_IP_API_KEY'),
    appEnv:           parseAppEnv(appEnvRaw),
    appName:          optional('APP_NAME') ?? 'Trombl',
    drift: {
      defaultRadiusKm:              requirePositiveNumber('DRIFT_DEFAULT_RADIUS_KM',               2),
      maxRadiusKm:                  requirePositiveNumber('DRIFT_MAX_RADIUS_KM',                  10),
      sessionDurationHours:         requirePositiveNumber('DRIFT_SESSION_DURATION_HOURS',           2),
      contactExchangeWindowMinutes: requirePositiveNumber('DRIFT_CONTACT_EXCHANGE_WINDOW_MINUTES',  5),
      locationTtlMinutes:           requirePositiveNumber('DRIFT_LOCATION_TTL_MINUTES',            15),
      minTrustScoreToMatch:         requirePositiveNumber('DRIFT_MIN_TRUST_SCORE_TO_MATCH',        20),
      maxPendingMatchesPerUser:     requirePositiveNumber('DRIFT_MAX_PENDING_MATCHES',              5),
      maxStoriesPerHour:            requirePositiveNumber('DRIFT_MAX_STORIES_PER_HOUR',             5),
    },
  };

  return _env;
}

/**
 * Run startup validation immediately and log result.
 * Call this at the top of Edge Functions that are sensitive to misconfiguration.
 */
export function assertEnv(): void {
  try {
    getEnv();
  } catch (err) {
    console.error((err as Error).message);
    throw err;
  }
}

/**
 * Returns only the fields that are safe to expose to Flutter clients.
 * Never include service role key, cron secret, or any server-only key here.
 */
export function getPublicConfig(): { supabaseUrl: string; supabaseAnonKey: string; appName: string } {
  const env = getEnv();
  return {
    supabaseUrl:     env.supabaseUrl,
    supabaseAnonKey: env.supabaseAnonKey,
    appName:         env.appName,
  };
}
