# Trombl Backend

Supabase backend for **Trombl** — the platform — with **Drift** as the real-world connection feature module.

## Architecture

```
Trombl (platform)
└── Drift (feature module)
    ├── Sessions     — host a public drift activity
    ├── Discovery    — find nearby drifters via PostGIS
    ├── Matching     — send/accept match requests
    ├── Exchange     — privacy-preserving contact reveal
    ├── Stories      — anonymous city feed
    └── Trust/Safety — trust scores, reports, moderation
```

Full details: [docs/architecture/overview.md](docs/architecture/overview.md)

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Database | PostgreSQL 15 + PostGIS |
| Auth | Supabase Auth (JWT) |
| Security | Row Level Security (all 18 tables) |
| Realtime | Supabase Realtime |
| API | 7 Deno Edge Functions |
| Geo | PostGIS `geometry(Point, 4326)`, GiST indexes |
| Client | Flutter + Supabase Flutter SDK |

## Quick Start

```bash
cd backend
npm install
npm run db:start      # Start local Supabase stack
npm run db:migrate    # Apply all 13 migrations
npm run functions:serve  # Serve Edge Functions locally
```

See [docs/deployment/setup-guide.md](docs/deployment/setup-guide.md) for full setup.

## Database

13 migrations, applied in order:

| # | File | Contents |
|---|------|----------|
| 01 | `00001_extensions_and_config.sql` | PostGIS, uuid-ossp, utility functions |
| 02 | `00002_enums.sql` | All domain enums |
| 03 | `00003_trombl_platform_tables.sql` | profiles, blocked_users, push_tokens, notifications |
| 04 | `00004_drift_catalog_tables.sql` | activity_types, vibe_tags |
| 05 | `00005_drift_location_table.sql` | user_locations (PostGIS), geo functions |
| 06 | `00006_drift_session_tables.sql` | sessions, participants, activity_logs |
| 07 | `00007_drift_matching_tables.sql` | matches, contact_exchange |
| 08 | `00008_drift_stories_table.sql` | stories, story_reactions |
| 09 | `00009_drift_trust_safety_tables.sql` | trust_scores, reports, moderation_queue, presence |
| 10 | `00010_seed_data.sql` | 10 activity types, 12 vibe tags |
| 11 | `00011_rls_platform.sql` | RLS for platform tables |
| 12 | `00012_rls_drift.sql` | RLS for all drift tables |
| 13 | `00013_realtime_and_indexes.sql` | Realtime publication, broadcast triggers, perf indexes |

## Edge Functions

| Function | Path | Purpose |
|----------|------|---------|
| `drift-create-session` | `POST /drift-create-session` | Create a Drift session |
| `drift-discover-nearby` | `POST /drift-discover-nearby` | PostGIS nearby user discovery |
| `drift-match-users` | `POST /drift-match-users` | Send/accept/decline match |
| `drift-contact-reveal` | `POST /drift-contact-reveal/consent` | Record contact exchange consent |
| `drift-contact-reveal` | `POST /drift-contact-reveal/reveal` | Retrieve contact in 5-min window |
| `drift-publish-story` | `POST /drift-publish-story` | Publish anonymous story |
| `drift-report-user` | `POST /drift-report-user` | File safety report |
| `trombl-cleanup` | `POST /trombl-cleanup` | Cron: TTL cleanup for all ephemeral data |

API reference: [docs/api/edge-functions.md](docs/api/edge-functions.md)

## Key Privacy Properties

- **Location privacy**: `drift_user_locations` is not in realtime publication. Nearby discovery goes only through `find_nearby_users()` SECURITY DEFINER function — users cannot read each other's coordinates directly.
- **Contact privacy**: Contact values (Instagram handle, phone, WhatsApp) are never stored in `drift_contact_exchange`. They are read from `trombl_profiles` at reveal time, only during a 5-minute window, via `get_revealed_contact()` SECURITY DEFINER function.
- **Story anonymity**: `drift_stories.user_id` is stored for moderation and block-filtering only. It is never returned by Edge Functions. RLS filters stories from blocked users using this field at SELECT time.
- **Moderation isolation**: `drift_moderation_queue` has a `USING (false)` deny-all RLS policy. Only service role (Edge Functions, cron) can access it.

## Tests

```bash
psql $SUPABASE_DB_URL -f tests/rls/test_rls_platform.sql
psql $SUPABASE_DB_URL -f tests/rls/test_rls_drift.sql
psql $SUPABASE_DB_URL -f tests/geo/test_geo_functions.sql
psql $SUPABASE_DB_URL -f tests/functions/test_trust_safety.sql
psql $SUPABASE_DB_URL -f tests/functions/test_session_lifecycle.sql
```

Requires [pgTAP](https://pgtap.org/) installed in the database.

## Realtime Channels

| Channel | Tables | Events |
|---------|--------|--------|
| `trombl:notifications:{userId}` | `trombl_notifications` | INSERT |
| `drift:sessions` | `drift_sessions` | UPDATE |
| `drift:matches` | `drift_matches` | UPDATE |
| `drift:contact_exchange` | `drift_contact_exchange` | INSERT, UPDATE |
| `drift:stories` | `drift_stories` | INSERT |
| `drift:presence` | Supabase Presence API | track/untrack |

Details: [docs/realtime/channels.md](docs/realtime/channels.md)
