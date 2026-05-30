# Edge Functions API Reference

All Edge Functions require an `Authorization: Bearer <jwt>` header obtained from Supabase Auth.
Responses use `Content-Type: application/json`.

## Error Format

```json
{ "error": "ERROR_CODE", "message": "Human-readable description" }
```

Error code prefixes: `AUTH_*`, `DRIFT_*`, `GEO_*`, `VALIDATION_*`, `RATE_LIMIT_*`, `SYSTEM_*`

---

## POST /drift-create-session

Creates a new active Drift session for the authenticated user.

### Request

```json
{
  "activity_type_id": "uuid",
  "openness":         "open | maybe | solo",
  "timeframe":        "now | next_hour | this_morning | this_afternoon | this_evening",
  "latitude":         51.5074,
  "longitude":        -0.1278,
  "city":             "London",
  "vibe_note":        "optional, max 200 chars",
  "vibe_tags":        ["optional", "array"],
  "radius_km":        2.0
}
```

### Response `201`

```json
{
  "success": true,
  "session": {
    "id":               "uuid",
    "activity_type_id": "uuid",
    "openness":         "open",
    "timeframe":        "now",
    "status":           "active",
    "radius_km":        2.0,
    "city":             "London",
    "expires_at":       "2026-05-14T12:00:00Z",
    "created_at":       "2026-05-14T10:00:00Z"
  }
}
```

### Error Codes

| Code | Status | Meaning |
|------|--------|---------|
| `DRIFT_SESSION_LIMIT` | 409 | User already has an active session |
| `VALIDATION_INVALID_FIELD` | 400 | activity_type_id not found or inactive |
| `GEO_INVALID_COORDINATES` | 400 | lat/lon out of range |

---

## POST /drift-discover-nearby

Returns users within a radius who are not in solo mode and not blocked.
Also upserts the caller's location so they appear in others' searches.

### Request

```json
{
  "latitude":         51.5074,
  "longitude":        -0.1278,
  "radius_km":        2.0,
  "limit":            30,
  "activity_type_id": "uuid | null"
}
```

### Response `200`

```json
{
  "success":    true,
  "users":      [...],
  "total":      12,
  "radius_km":  2.0,
  "latitude":   51.5074,
  "longitude":  -0.1278
}
```

Each user object shape is defined by `find_nearby_users()` (see `00005_drift_location_table.sql`).
`user_id` is included for match initiation; location coordinates are NOT returned.

---

## POST /drift-match-users

Sends a match request, or accepts/declines an existing one.

### Send Request

```json
{
  "target_id":  "uuid",
  "session_id": "uuid | null",
  "action":     "send"
}
```

### Accept/Decline

```json
{
  "target_id": "uuid",
  "action":    "accept | decline"
}
```

### Response `201` (send) / `200` (accept/decline)

```json
{
  "success": true,
  "match": {
    "id":           "uuid",
    "status":       "pending | accepted | declined",
    "initiator_id": "uuid",
    "target_id":    "uuid",
    "expires_at":   "...",
    "created_at":   "..."
  }
}
```

### Error Codes

| Code | Status | Meaning |
|------|--------|---------|
| `DRIFT_SELF_MATCH` | 400 | Cannot match yourself |
| `DRIFT_TARGET_SOLO` | 409 | Target is in solo mode |
| `DRIFT_BLOCKED` | 403 | Block relationship exists |
| `DRIFT_LOW_TRUST` | 403 | Initiator trust score < 20 |
| `DRIFT_MATCH_EXISTS` | 409 | Active match already exists |
| `RATE_LIMIT_MATCH_REQUESTS` | 429 | > 5 pending outgoing matches |

---

## POST /drift-contact-reveal/consent

Records the authenticated user's consent to exchange a contact method.
Contact values are **never stored** — only the consent flag and contact type.

### Request

```json
{
  "match_id":     "uuid",
  "contact_type": "instagram | whatsapp | phone"
}
```

### Response `200`

```json
{
  "success":  true,
  "exchange": {
    "match_id":           "uuid",
    "initiator_consented": true,
    "target_consented":    false,
    "contact_type":        "instagram",
    "reveal_at":           null,
    "expires_at":          null
  }
}
```

When both parties consent, `reveal_at` and `expires_at` are set automatically.

### Error Codes

| Code | Status | Meaning |
|------|--------|---------|
| `DRIFT_NO_CONTACT_INFO` | 422 | User profile missing that contact field |
| `DRIFT_MATCH_NOT_FOUND` | 404 | No accepted, unexpired match found |

---

## POST /drift-contact-reveal/reveal

Retrieves the other party's contact value during the 5-minute reveal window.
The contact value is read from `trombl_profiles` at query time — never from storage.

### Request

```json
{ "match_id": "uuid" }
```

### Response `200`

```json
{
  "success": true,
  "contact": {
    "contact_type":  "instagram",
    "contact_value": "@their_handle",
    "reveal_at":     "...",
    "expires_at":    "..."
  }
}
```

### Error Codes

| Code | Status | Meaning |
|------|--------|---------|
| `DRIFT_CONTACT_UNAVAILABLE` | 403 | Window not open or expired |

---

## POST /drift-publish-story

Publishes an anonymous story to the city feed.
`user_id` is stored for moderation but **never returned** in API responses.

### Request

```json
{
  "emoji":          "☕",
  "text":           "Just drifting around London",
  "city":           "London",
  "country_code":   "GB",
  "activity_tag":   "Coffee",
  "activity_emoji": "☕",
  "vibe_tags":      ["no small talk", "introvert-friendly"]
}
```

### Response `201`

```json
{
  "success": true,
  "story": {
    "id":             "uuid",
    "emoji":          "☕",
    "text":           "Just drifting around London",
    "city":           "London",
    "country_code":   "GB",
    "activity_tag":   "Coffee",
    "activity_emoji": "☕",
    "vibe_tags":      ["no small talk"],
    "reaction_count": 0,
    "published_at":   "..."
  }
}
```

### Error Codes

| Code | Status | Meaning |
|------|--------|---------|
| `RATE_LIMIT_STORIES` | 429 | > 5 stories in last hour |
| `VALIDATION_INVALID_FIELD` | 400 | text > 140 chars or > 5 vibe tags |

---

## DELETE /drift-publish-story

Soft-deletes the user's own story.

### Request

```json
{ "story_id": "uuid" }
```

### Response `200`

```json
{ "success": true }
```

---

## POST /drift-report-user

Files a safety or behaviour report. Auto-blocks the reported user on the reporter's side.

### Request

```json
{
  "reported_id":   "uuid",
  "reason":        "made_me_feel_unsafe | harassment | inappropriate_behaviour | impersonation | spam | didnt_show_up | other",
  "custom_reason": "required when reason is 'other', max 500 chars",
  "match_id":      "uuid | null",
  "session_id":    "uuid | null",
  "story_id":      "uuid | null"
}
```

### Response `201`

```json
{
  "success": true,
  "report": {
    "id":         "uuid",
    "status":     "open",
    "created_at": "..."
  },
  "message": "Report submitted. The user has also been blocked."
}
```

### Error Codes

| Code | Status | Meaning |
|------|--------|---------|
| `DRIFT_SELF_REPORT` | 400 | Cannot report yourself |
| `RATE_LIMIT_REPORT` | 429 | Already reported this user in last 7 days, or > 10 reports today |

---

## POST /trombl-cleanup (internal cron)

Runs all scheduled cleanup jobs. Called by Supabase cron schedule every 5 minutes.

**Authorization:** `Bearer <CRON_SECRET>` (not a user JWT).

### Response `200`

```json
{
  "success": true,
  "result": {
    "ran_at":            "...",
    "locations_cleaned": 12,
    "sessions_expired":  3,
    "matches_expired":   7,
    "stories_soft_del":  0,
    "presence_cleared":  5
  }
}
```
