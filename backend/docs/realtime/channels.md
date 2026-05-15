# Realtime Channel Architecture

Trombl uses Supabase Realtime for live updates. Channels are namespaced by domain.

## Channel Map

| Channel | Mechanism | Who subscribes | Events |
|---------|-----------|----------------|--------|
| `trombl:notifications:{userId}` | Postgres Changes | Authenticated user (own) | `INSERT` on `trombl_notifications` |
| `drift:sessions` | Postgres Changes + Broadcast | All authenticated users | `UPDATE` on `drift_sessions` |
| `drift:matches` | Postgres Changes + pg_notify | Match participants | `UPDATE` on `drift_matches` |
| `drift:contact_exchange` | Postgres Changes + pg_notify | Match participants | `INSERT`, `UPDATE` on `drift_contact_exchange` |
| `drift:stories` | Postgres Changes | All authenticated users | `INSERT` on `drift_stories` |
| `drift:presence` | Presence | Session co-participants | Online/offline transitions |

## Flutter SDK Integration

### Subscribe to own notifications

```dart
final notifChannel = supabase.channel('trombl:notifications:${userId}')
  .onPostgresChanges(
    event: PostgresChangeEvent.insert,
    schema: 'public',
    table: 'trombl_notifications',
    filter: PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'user_id',
      value: userId,
    ),
    callback: (payload) => _handleNewNotification(payload.newRecord),
  )
  .subscribe();
```

### Subscribe to match updates

```dart
final matchChannel = supabase.channel('drift:matches')
  .onPostgresChanges(
    event: PostgresChangeEvent.update,
    schema: 'public',
    table: 'drift_matches',
    callback: (payload) {
      final match = payload.newRecord;
      // RLS ensures only the user's own matches are streamed
      if (match['initiator_id'] == userId || match['target_id'] == userId) {
        _handleMatchUpdate(match);
      }
    },
  )
  .subscribe();
```

### Subscribe to story feed

```dart
final storiesChannel = supabase.channel('drift:stories')
  .onPostgresChanges(
    event: PostgresChangeEvent.insert,
    schema: 'public',
    table: 'drift_stories',
    callback: (payload) => _handleNewStory(payload.newRecord),
    // Note: user_id is visible here but should be stripped before rendering
  )
  .subscribe();
```

### Presence (session co-presence)

```dart
final presenceChannel = supabase.channel('drift:presence:${sessionId}')
  ..onPresenceSync(callback: (payload) => _updatePresenceList(payload))
  ..onPresenceJoin(callback: (payload) => _userJoined(payload))
  ..onPresenceLeave(callback: (payload) => _userLeft(payload));

await presenceChannel.subscribe();

// Heartbeat: call every 30 seconds to maintain presence
await presenceChannel.track({
  'user_id':    userId,
  'session_id': sessionId,
  'joined_at':  DateTime.now().toIso8601String(),
});
```

## Privacy Constraints

- **`drift_user_locations` is NOT in the realtime publication.** Location discovery happens via `POST /drift-discover-nearby` (Edge Function → SECURITY DEFINER SQL). This prevents accidental location broadcast.
- **`drift_moderation_queue`, `drift_trust_scores`, `drift_reports` are NOT published.** Service role access only.
- **`drift_stories.user_id` is in the realtime payload** but the Flutter client must strip it from UI state. The RLS policy filters blocked users at SELECT time — the realtime INSERT event fires before that filter applies, so the client should re-fetch through the RLS-filtered `drift_stories` table if anonymity is critical.

## Cleanup / Unsubscribe

Always unsubscribe channels when the widget is disposed:

```dart
@override
void dispose() {
  supabase.removeChannel(notifChannel);
  supabase.removeChannel(matchChannel);
  super.dispose();
}
```

## pg_notify Broadcast Triggers

The following PostgreSQL triggers call `pg_notify()` in addition to the Supabase Realtime publication:

| Trigger | Table | Condition | Channel |
|---------|-------|-----------|---------|
| `drift_matches_broadcast` | `drift_matches` | status changes | `drift:matches` |
| `drift_contact_exchange_broadcast` | `drift_contact_exchange` | any insert/update | `drift:contact_exchange` |
| `drift_sessions_broadcast` | `drift_sessions` | status or count changes | `drift:sessions` |

Clients can listen to these via `supabase.channel('...').on(RealtimeListenTypes.broadcast, ...)`.
