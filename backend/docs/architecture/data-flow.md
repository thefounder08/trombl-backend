# Trombl — Data Flow Documentation

## Core User Flows

---

### Flow 1: User Onboarding → Profile Creation

```
1. Client: Supabase Auth signup (email/anonymous)
2. Auth trigger fires → inserts row into trombl_profiles
3. Client: PATCH /functions/drift/update-profile
4. Edge Function validates JWT, updates profile fields
5. Realtime: no broadcast (private onboarding)
```

**Tables involved:**
- `auth.users` (Supabase managed)
- `trombl_profiles`

---

### Flow 2: Start a Drift Session

```
1. Client: POST /functions/drift/create-session
   Body: { activity_type_id, openness, timeframe, vibe_note, location }

2. Edge Function:
   a. Validates JWT → extracts user_id
   b. Validates body schema
   c. Calls upsert on drift_user_locations (with location)
   d. Inserts into drift_sessions
   e. Inserts into drift_session_participants (as host)
   f. Returns session_id + participant record

3. DB Trigger fires on drift_sessions INSERT:
   → Broadcasts to channel: drift:sessions

4. Client subscribes to: drift:sessions:${session_id}
```

**Tables involved:**
- `drift_sessions`
- `drift_session_participants`
- `drift_user_locations`
- `drift_activity_types`

---

### Flow 3: Discover Nearby Users

```
1. Client: POST /functions/drift/discover-nearby
   Body: { latitude, longitude, radius_km, activity_filter? }

2. Edge Function:
   a. Validates JWT
   b. Upserts caller's location → drift_user_locations
   c. Executes PostGIS query:
      SELECT profiles, sessions WHERE ST_DWithin(location, point, radius)
      AND session.status = 'active'
      AND NOT blocked by/blocking caller
      AND drift window open
   d. Returns paginated list of nearby users

3. Client receives list
4. Client subscribes to: drift:nearby channel for real-time updates
```

**Tables involved:**
- `drift_user_locations`
- `drift_sessions`
- `drift_session_participants`
- `trombl_blocked_users`
- `trombl_profiles`

---

### Flow 4: Match Request → Accepted

```
1. Client A: POST /functions/drift/match-users
   Body: { target_user_id }

2. Edge Function:
   a. Validates JWT
   b. Checks A is not blocked by B
   c. Checks A has active session
   d. Checks B has active session
   e. Inserts drift_matches: { initiator=A, target=B, status='pending' }
   f. Inserts trombl_notifications for B: "someone wants to drift with you"

3. DB Trigger → broadcasts to drift:matches

4. Client B receives notification + realtime event
5. Client B: POST /functions/drift/match-users
   Body: { match_id, action: 'accept' }

6. Edge Function:
   a. Validates B is the target
   b. Updates drift_matches: { status='accepted', accepted_at=now() }
   c. Inserts notifications for both A and B

7. DB Trigger → broadcasts match accepted to both users
8. Both clients enter live session screen
```

**Tables involved:**
- `drift_matches`
- `drift_sessions`
- `trombl_notifications`
- `trombl_blocked_users`

---

### Flow 5: Contact Exchange (Mutual Consent)

```
1. Session ends → both clients shown contact exchange UI

2. Client A: POST /functions/drift/contact-reveal
   Body: { match_id, consent: true, contact_type: 'instagram' }

3. Edge Function:
   a. Upserts drift_contact_exchange: { user_a=A, consent_a=true }
   b. Checks if B has also consented

4. Client B: POST /functions/drift/contact-reveal
   Body: { match_id, consent: true, contact_type: 'instagram' }

5. Edge Function:
   a. Upserts drift_contact_exchange: { consent_b=true }
   b. Both consented → reveal_at = now()
   c. Sets expires_at = now() + 5 minutes
   d. Returns BOTH users' contact info (from trombl_profiles)
   e. Broadcasts to drift:matches:${match_id}: { event: 'contact_revealed' }

6. After 5 minutes:
   Scheduled job: marks exchange as expired
   Contact info no longer retrievable
```

**Tables involved:**
- `drift_contact_exchange`
- `drift_matches`
- `trombl_profiles`

**Security:** Contact info is read from profiles at reveal time. It is NEVER copied into the exchange table.

---

### Flow 6: Publish Anonymous Story

```
1. Client: POST /functions/drift/publish-story
   Body: { text, emoji, city, activity_tag?, vibe_tags? }

2. Edge Function:
   a. Validates JWT
   b. Validates text length ≤ 140 chars
   c. Runs basic content moderation check
   d. Inserts drift_stories: { user_id=NULL (anonymized), text, city, ... }
   e. Returns story_id

3. DB Trigger → broadcasts to drift:stories

4. All city subscribers receive new story
```

**Key:** `user_id` is stored (for moderation/block purposes) but never exposed in API responses. All read queries return stories without user_id.

---

### Flow 7: Report a User

```
1. Client: POST /functions/drift/report-user
   Body: { reported_user_id, reason, context_match_id? }

2. Edge Function:
   a. Validates JWT
   b. Validates reported_user exists
   c. Inserts drift_reports: { reporter, reported, reason, status='open' }
   d. Inserts into drift_moderation_queue
   e. Increments drift_trust_scores: negative signal for reported user
   f. Returns success

3. Moderator (admin) reviews drift_moderation_queue
4. Moderator takes action → updates drift_reports.status
5. If confirmed → bans user, inserts trombl_blocked_users (system block)
```

**Tables involved:**
- `drift_reports`
- `drift_moderation_queue`
- `drift_trust_scores`
- `trombl_blocked_users`

---

## Realtime Event Map

```
Table Change                    → Channel                      → Event
─────────────────────────────────────────────────────────────────────
drift_sessions INSERT/UPDATE    → drift:sessions               → session_changed
drift_matches INSERT/UPDATE     → drift:matches                → match_updated
drift_user_locations INSERT     → drift:nearby                 → user_nearby
drift_stories INSERT            → drift:stories                → story_published
trombl_notifications INSERT     → trombl:notifications         → notification
drift_presence UPSERT           → drift:presence               → presence_update
```

---

## Error Handling Strategy

All Edge Functions return structured errors:

```typescript
{
  error: {
    code: "DRIFT_SESSION_EXPIRED",
    message: "Your drift session has expired",
    status: 400
  }
}
```

Error code categories:
- `AUTH_*` — authentication/authorization errors
- `DRIFT_*` — drift feature business logic errors
- `GEO_*` — geolocation errors
- `VALIDATION_*` — input validation errors
- `RATE_LIMIT_*` — rate limiting errors
- `SYSTEM_*` — infrastructure errors
