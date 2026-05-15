# Deployment & Setup Guide

## Prerequisites

- Supabase CLI ≥ 1.172.0
- Node.js ≥ 20 (for package scripts)
- Deno ≥ 1.40 (for local Edge Function development)
- PostgreSQL client (psql) for running SQL tests

## 1. Supabase Project Setup

```bash
# Login to Supabase CLI
supabase login

# Link to your remote project
supabase link --project-ref <your-project-id>

# Copy and populate environment variables
cp backend/supabase/config/.env.example backend/supabase/config/.env
```

Required `.env` values:

| Variable | Source |
|----------|--------|
| `SUPABASE_PROJECT_ID` | Project settings → General |
| `SUPABASE_URL` | Project settings → API |
| `SUPABASE_ANON_KEY` | Project settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | Project settings → API (keep secret) |
| `SUPABASE_DB_URL` | Project settings → Database → Connection string |
| `SUPABASE_JWT_SECRET` | Project settings → API |
| `CRON_SECRET` | Generate: `openssl rand -hex 32` |

## 2. Enable Extensions

Run once in the Supabase SQL editor or via migration (already in `00001_extensions_and_config.sql`):

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
```

PostGIS requires the **Supabase Pro plan** or manual enablement in the database settings for hosted projects.

## 3. Apply Migrations

```bash
cd backend
npm install
npm run db:migrate
```

Migration order (must be sequential):
1. `00001_extensions_and_config.sql`
2. `00002_enums.sql`
3. `00003_trombl_platform_tables.sql`
4. `00004_drift_catalog_tables.sql`
5. `00005_drift_location_table.sql`
6. `00006_drift_session_tables.sql`
7. `00007_drift_matching_tables.sql`
8. `00008_drift_stories_table.sql`
9. `00009_drift_trust_safety_tables.sql`
10. `00010_seed_data.sql`
11. `00011_rls_platform.sql`
12. `00012_rls_drift.sql`
13. `00013_realtime_and_indexes.sql`

## 4. Deploy Edge Functions

```bash
npm run functions:deploy
```

This deploys all 7 functions:
- `drift-create-session`
- `drift-discover-nearby`
- `drift-match-users`
- `drift-contact-reveal`
- `drift-publish-story`
- `drift-report-user`
- `trombl-cleanup`

### Set Edge Function Secrets

```bash
supabase secrets set CRON_SECRET=<your-cron-secret>
supabase secrets set PUSH_NOTIFICATION_URL=<your-push-url>
```

All other Supabase-provided secrets (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`) are available automatically in Edge Functions via `Deno.env.get()`.

## 5. Configure Cron Schedule

In the Supabase dashboard under **Database → Cron Jobs**, create:

```
Name:     trombl-cleanup
Schedule: */5 * * * *   (every 5 minutes)
Command:  SELECT net.http_post(
            url := 'https://<project-ref>.functions.supabase.co/trombl-cleanup',
            headers := '{"Authorization": "Bearer <CRON_SECRET>"}'::jsonb,
            body := '{}'::jsonb
          );
```

Requires the `pg_net` extension (enabled by default on Supabase).

## 6. Configure Supabase Realtime

In the Supabase dashboard under **Database → Replication**:

Confirm that the `supabase_realtime` publication includes:
- `trombl_notifications`
- `drift_sessions`
- `drift_session_participants`
- `drift_matches`
- `drift_contact_exchange`
- `drift_stories`
- `drift_story_reactions`
- `drift_presence`

These are added via `ALTER PUBLICATION supabase_realtime ADD TABLE ...` in migration `00013`.

## 7. Auth Configuration

In the Supabase dashboard under **Authentication → Settings**:

- Site URL: your Flutter app deep link URL
- Enable Email provider: yes
- Enable Anonymous sign-ins: yes (for guest browsing if needed)
- JWT expiry: 3600 seconds (1 hour)

Email templates should be customized with Trombl branding.

## 8. Run Tests

```bash
# RLS tests (requires psql and pgtap installed)
psql $SUPABASE_DB_URL -f tests/rls/test_rls_platform.sql
psql $SUPABASE_DB_URL -f tests/rls/test_rls_drift.sql

# Geo function tests
psql $SUPABASE_DB_URL -f tests/geo/test_geo_functions.sql

# Trust & safety tests
psql $SUPABASE_DB_URL -f tests/functions/test_trust_safety.sql
psql $SUPABASE_DB_URL -f tests/functions/test_session_lifecycle.sql
```

### Install pgtap

```bash
# macOS
brew install pgtap

# Ubuntu
apt-get install postgresql-<version>-pgtap
```

## 9. Local Development

```bash
# Start local Supabase stack
npm run db:start

# Serve Edge Functions locally
npm run functions:serve

# Reset and re-run all migrations + seed
npm run db:reset
```

The local stack runs at:
- API: `http://localhost:54321`
- Studio: `http://localhost:54323`
- DB: `postgresql://postgres:postgres@localhost:54322/postgres`

## 10. Generate TypeScript Types

After any schema change:

```bash
npm run db:generate-types
```

This updates `backend/supabase/types/database.ts` from the live schema.

## Security Checklist (Pre-Launch)

- [ ] `SUPABASE_SERVICE_ROLE_KEY` is never exposed to the Flutter client
- [ ] `CRON_SECRET` is only in Supabase secrets, not in `.env` committed to git
- [ ] RLS is enabled on all 18 tables (verify: `SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname = 'public'`)
- [ ] `drift_moderation_queue` has deny-all authenticated policy
- [ ] `drift_user_locations` is NOT in the realtime publication
- [ ] Edge Functions validate JWT on every request (not just anon key)
- [ ] `get_revealed_contact()` SECURITY DEFINER function validated: returns null after 5-minute window
- [ ] Auto-ban trigger tested: trust score → 0 bans the account
- [ ] pg_cron cleanup job running (check Supabase cron logs)
- [ ] PostGIS spatial indexes in place (verify: `\d drift_user_locations`)
