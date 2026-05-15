# Trombl Backend — Claude Code Guidelines

## Project Overview

Trombl is a proximity-based social discovery app ("Drift" feature module).
This repository contains the complete Supabase backend.

**Stack:** PostgreSQL 17 + PostGIS · Supabase · Deno Edge Functions · TypeScript

---

## Repository Layout

```
backend/
├── supabase/
│   ├── migrations/          # 00001–00015 SQL migrations (apply in order)
│   ├── functions/           # Deno Edge Functions + _shared/ utilities
│   ├── types/database.ts    # TypeScript types (hand-maintained, matches schema)
│   └── config.toml          # Supabase local dev config
├── tests/
│   ├── pgTAP/               # SQL unit tests (require pgtap extension)
│   ├── rls/                 # RLS policy tests
│   ├── geo/                 # PostGIS query tests
│   ├── scenarios/           # Multi-user integration bash scripts
│   ├── realtime/            # WebSocket + realtime tests
│   ├── http/                # Edge Function HTTP tests
│   ├── auth/mint_jwt.py     # JWT minting utility for QA
│   └── manual/qa_checklist.md
├── docs/
│   ├── architecture/        # System design docs
│   ├── api/                 # Edge Function API docs
│   ├── realtime/            # Realtime channel docs
│   └── deployment/          # Deployment guide
├── TESTING_GUIDE.md         # Complete local testing guide
└── README.md
```

---

## Critical Rules for AI Development

### Never Do
- Never commit `.env.local`, `.env.production`, or any file with real credentials
- Never store service role keys, JWT secrets, or DB passwords in source code
- Never add hardcoded Supabase project URLs/IDs as string literals in source files
  (use `.env.local` → read via `load_project_url()` or `env.ts`)
- Never bypass RLS policies in production code (service role only in Edge Functions)
- Never skip pgTAP regression tests when modifying RLS policies

### Always Do
- Read `.env.local` for all credentials — never hardcode
- Use `SECURITY DEFINER` for any function that must bypass RLS internally
- Add migration file for every schema change (increment: `000XX_description.sql`)
- Update `supabase/types/database.ts` when schema changes
- Run `bash tests/rls/test_rls_live.sh` after any RLS policy change

---

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Production only — no direct commits |
| `develop` | Integration — merge PRs here first |
| `feature/*` | New features |
| `fix/*` | Bug fixes |
| `hotfix/*` | Urgent production patches → merge to main + develop |

**Commit format (Conventional Commits):**
```
feat(sessions): add participant_count trigger guard
fix(rls): resolve stories_update_own infinite recursion
test(geo): add boundary condition for find_nearby_users
docs(api): update contact-reveal endpoint response shape
chore(deps): bump supabase-js to 2.106.0
```

---

## Local Development Setup

```bash
# 1. Copy env template
cp backend/supabase/config/.env.example backend/.env.local
# Fill in real values from Supabase Dashboard

# 2. Verify DB connection
psql "$DATABASE_URL" -c "SELECT version();"

# 3. Apply migrations (if running fresh)
for f in backend/supabase/migrations/*.sql; do
  psql "$DATABASE_URL" -f "$f"
done

# 4. Run test suite
source backend/.env.local
eval "$(python3 backend/tests/auth/mint_jwt.py --export)"
bash backend/tests/geo/test_geo_queries.sh
bash backend/tests/rls/test_rls_live.sh
bash backend/tests/scenarios/test_expiry_systems.sh
```

---

## Known Open Issues

| ID | Severity | Description |
|----|----------|-------------|
| FIND-001 | Medium | Flagged stories visible until removed — add `AND is_flagged=false` to `stories_select_public` RLS |
| BUG-010 | High | Session host can set arbitrary `participant_count` — needs trigger guard |
| INFO-003 | Low | Contact reveal notification expires 6min but window is 5min |

---

## Key Design Invariants

1. **JWT secret:** Used as raw UTF-8 bytes (NOT base64-decoded) for HMAC-SHA256
2. **Location trigger:** `refresh_location_expiry` always resets `expires_at = now()+15min` on INSERT/UPDATE — bypass with `session_replication_role = 'replica'` in tests only
3. **RLS recursion:** Never use self-referencing subqueries in WITH CHECK on the same table — use `SECURITY DEFINER` functions
4. **Realtime privacy:** `drift_user_locations` and `trombl_profiles` are intentionally NOT in the `supabase_realtime` publication
5. **Re-match:** Uniqueness is via partial index on `(initiator_id, target_id) WHERE status IN ('pending','accepted')` — not a hard UNIQUE constraint
