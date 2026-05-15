# Trombl Backend — Architecture Overview

## Platform Identity

**Trombl** is a modern social discovery platform. **Drift** is a feature module within Trombl.

```
Trombl (Platform)
└── Drift (Feature Module)
    ├── Session Engine
    ├── Matching System
    ├── Contact Exchange
    ├── Stories
    ├── Presence & Realtime
    ├── Trust & Safety
    └── City Discovery
```

---

## Tech Stack

| Layer              | Technology                    |
|--------------------|-------------------------------|
| Database           | PostgreSQL 15 + PostGIS       |
| Auth               | Supabase Auth (JWT)           |
| Realtime           | Supabase Realtime (WebSocket) |
| Serverless Logic   | Supabase Edge Functions (Deno)|
| Storage            | Supabase Storage              |
| Client SDK         | Supabase Flutter SDK          |
| Language           | TypeScript / SQL              |

---

## Domain Separation

### Trombl (Platform Namespace)
Owns cross-feature concerns:
- User identity and profiles (`trombl_profiles`)
- Push notification infrastructure (`trombl_push_tokens`)
- Notification persistence (`trombl_notifications`)
- User blocking (`trombl_blocked_users`)

### Drift (Feature Namespace)
All Drift-specific data is isolated under the `drift_` prefix:
- Session lifecycle management
- Proximity-based discovery
- Ephemeral matching
- Anonymous stories
- Trust scoring
- Moderation queue
- Presence tracking

This separation allows Trombl to ship other feature modules (e.g., `spark_`, `commons_`) independently without polluting namespaces.

---

## Architectural Principles

### 1. Privacy-by-Default
- Location data expires automatically (TTL via DB triggers)
- Contact info never stored permanently — only shown during mutual-consent window
- Anonymous stories cannot be traced back to users post-publish
- Soft-delete everywhere sensitive data exists

### 2. Ephemeral-First Design
- Sessions have hard expiry (2 hours default)
- Matches auto-expire
- Contact exchange windows auto-expire (5 minutes after reveal)
- Presence clears on disconnect

### 3. Row-Level Security (RLS) Everywhere
- Every table has explicit RLS policies
- No table is accessible without JWT
- Service role bypasses RLS only for scheduled jobs

### 4. Event-Driven Realtime
- DB triggers publish to Supabase Realtime channels
- No polling — all state changes are pushed
- Channels are namespaced to prevent cross-contamination

### 5. Scalability
- UUIDs (v4) for all PKs — sharding-safe
- Composite indexes on hot query paths
- PostGIS GiST indexes for geo queries
- Partitioning-ready schema design

---

## Request Flow

```
Flutter Client
     │
     ├─── Supabase Auth (JWT)
     │         │
     │         ▼
     ├─── Edge Function (validate → business logic)
     │         │
     │         ▼
     ├─── PostgreSQL (RLS enforced)
     │         │
     │         ├─── Trigger → Realtime broadcast
     │         └─── Trigger → Notification queue
     │
     └─── Supabase Realtime (WebSocket subscription)
```

---

## Realtime Event Strategy

All realtime events use Supabase Realtime with PostgreSQL replication.

### Channel Namespacing

| Channel                   | Purpose                              |
|---------------------------|--------------------------------------|
| `trombl:notifications`    | Cross-feature user notifications     |
| `drift:nearby`            | Nearby presence updates              |
| `drift:sessions`          | Session state changes                |
| `drift:matches`           | Match creation/status updates        |
| `drift:stories`           | New story publications               |
| `drift:presence`          | User presence heartbeats             |

### Broadcast Strategy
- DB changes → Supabase Realtime (via replication)
- Edge Function results → direct broadcast for low-latency events
- Presence managed via Supabase Presence API

---

## Geo-Location Architecture

```
Client sends location update
         │
         ▼
drift_user_locations table (PostGIS geometry column)
         │
         ├── Auto-expires via scheduled cleanup (15-min TTL)
         ├── GiST index on location column
         └── ST_DWithin() for radius queries
```

### Supported Radius Queries
- **Nearby** (default): 2km
- **Expanded**: up to 10km  
- **City**: bounding box query
- **Regional**: 500km
- **Global**: no constraint

---

## Security Model

### Auth Tiers
1. **Anonymous**: Temporary session, limited to onboarding reads
2. **Authenticated**: Full Drift access with RLS enforcement
3. **Service Role**: Scheduled jobs, admin tasks (server-only)

### Critical Security Rules
- Users can only read their own location data
- Contact info is NEVER stored — only the exchange consent is stored
- Reports are write-once, read by moderators only
- Moderation queue is service-role only
- Trust scores are computed server-side only

---

## Data Retention Policy

| Data Type         | Retention       | Deletion Method  |
|-------------------|-----------------|------------------|
| User locations    | 15 minutes      | Trigger cleanup  |
| Drift sessions    | 2 hours active  | Auto-expire      |
| Matches           | 24 hours        | Scheduled job    |
| Contact exchange  | 5 min (reveal)  | Trigger          |
| Stories           | 90 days         | Soft delete      |
| Notifications     | 30 days         | Scheduled job    |
| Presence data     | Session only    | On disconnect    |

---

## Future Module Readiness

The platform schema is designed to accommodate future modules:

- `spark_*` — spontaneous 1:1 connection module
- `commons_*` — community spaces module
- `moments_*` — photo/memory sharing module
- `pulse_*` — city activity heatmap module

All future modules share:
- `trombl_profiles` (user identity)
- `trombl_notifications` (push infra)
- `trombl_blocked_users` (block graph)
- Auth system

---

## Database Entity Count

| Namespace | Tables | Enums | Functions | Triggers |
|-----------|--------|-------|-----------|----------|
| trombl    | 4      | 3     | 2         | 3        |
| drift     | 14     | 8     | 12        | 11       |
| shared    | —      | —     | 6         | —        |

Total: 18 tables, 11 enums, 20 functions, 14 triggers
