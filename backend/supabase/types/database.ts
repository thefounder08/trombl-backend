// Trombl — Database Types
// Auto-generated types for Supabase client usage.
// Keep in sync with migrations.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

// ─── Enums ───────────────────────────────────────────────────────────────────

export type TromblNotificationType =
  | "drift_nearby"
  | "drift_match_request"
  | "drift_match_accepted"
  | "drift_match_declined"
  | "drift_session_expiring"
  | "drift_contact_revealed"
  | "drift_story_reaction"
  | "safety_alert"
  | "system";

export type DriftSessionStatus =
  | "active"
  | "expired"
  | "cancelled"
  | "completed";

export type DriftMatchStatus =
  | "pending"
  | "accepted"
  | "declined"
  | "expired"
  | "cancelled"
  | "completed";

export type DriftOpenness =
  | "open"
  | "maybe"
  | "solo";

export type DriftTimeframe =
  | "right_now"
  | "in_30_min"
  | "in_1_hour";

export type DriftContactType =
  | "instagram"
  | "whatsapp"
  | "phone";

export type DriftReportReason =
  | "made_me_feel_unsafe"
  | "didnt_show_up"
  | "inappropriate_behaviour"
  | "fake_profile"
  | "harassment"
  | "spam"
  | "other";

export type DriftReportStatus =
  | "open"
  | "reviewing"
  | "resolved_actioned"
  | "resolved_dismissed";

export type DriftModerationAction =
  | "warn"
  | "suspend"
  | "ban"
  | "dismiss";

export type DriftStoryReactionType =
  | "heart"
  | "spark"
  | "wave"
  | "coffee";

// ─── Platform Tables ─────────────────────────────────────────────────────────

export interface TromblProfile {
  id: string; // UUID, references auth.users
  username: string | null;
  display_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  instagram_handle: string | null;
  whatsapp_number: string | null;
  phone_number: string | null;
  drift_vibe_tags: string[];
  drift_openness: DriftOpenness;
  location_sharing_enabled: boolean;
  notifications_enabled: boolean;
  is_banned: boolean;
  banned_at: string | null;
  ban_reason: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface TromblNotification {
  id: string;
  user_id: string;
  type: TromblNotificationType;
  title: string;
  body: string;
  data: Json;
  is_read: boolean;
  read_at: string | null;
  created_at: string;
  expires_at: string | null;
}

export interface TromblPushToken {
  id: string;
  user_id: string;
  token: string;
  platform: "ios" | "android" | "web";
  is_active: boolean;
  last_used_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface TromblBlockedUser {
  id: string;
  blocker_id: string;
  blocked_id: string;
  is_system_block: boolean;
  reason: string | null;
  created_at: string;
}

// ─── Drift Tables ─────────────────────────────────────────────────────────────

export interface DriftActivityType {
  id: string;
  emoji: string;
  label: string;
  sub_label: string;
  is_active: boolean;
  sort_order: number;
  created_at: string;
}

export interface DriftVibeTag {
  id: string;
  label: string;
  is_active: boolean;
  sort_order: number;
  created_at: string;
}

export interface DriftUserLocation {
  id: string;
  user_id: string;
  location: unknown; // PostGIS geometry(Point, 4326)
  latitude: number;
  longitude: number;
  accuracy_meters: number | null;
  city: string | null;
  country_code: string | null;
  expires_at: string;
  created_at: string;
  updated_at: string;
}

export interface DriftSession {
  id: string;
  host_user_id: string;
  activity_type_id: string;
  openness: DriftOpenness;
  timeframe: DriftTimeframe;
  vibe_note: string | null;
  vibe_tags: string[];
  status: DriftSessionStatus;
  radius_km: number;
  location_snapshot: unknown; // PostGIS geometry at session creation
  city: string | null;
  participant_count: number;
  started_at: string;
  expires_at: string;
  ended_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface DriftSessionParticipant {
  id: string;
  session_id: string;
  user_id: string;
  is_host: boolean;
  joined_at: string;
  left_at: string | null;
}

export interface DriftMatch {
  id: string;
  session_id: string | null;
  initiator_id: string;
  target_id: string;
  status: DriftMatchStatus;
  initiated_at: string;
  responded_at: string | null;
  accepted_at: string | null;
  expires_at: string;
  ended_at: string | null;
  end_reason: string | null;
  created_at: string;
  updated_at: string;
}

export interface DriftContactExchange {
  id: string;
  match_id: string;
  initiator_consented: boolean;
  target_consented: boolean;
  initiator_contact_type: DriftContactType | null;
  target_contact_type: DriftContactType | null;
  reveal_at: string | null;
  expires_at: string | null;
  is_expired: boolean;
  created_at: string;
  updated_at: string;
}

export interface DriftStory {
  id: string;
  user_id: string; // stored for moderation only, never exposed in reads
  emoji: string;
  text: string;
  city: string;
  activity_tag: string | null;
  activity_emoji: string | null;
  vibe_tags: string[];
  reaction_count: number;
  is_flagged: boolean;
  is_removed: boolean;
  removed_reason: string | null;
  published_at: string;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface DriftStoryReaction {
  id: string;
  story_id: string;
  user_id: string;
  reaction_type: DriftStoryReactionType;
  created_at: string;
}

export interface DriftPresence {
  id: string;
  user_id: string;
  session_id: string | null;
  is_online: boolean;
  last_seen_at: string;
  client_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface DriftReport {
  id: string;
  reporter_id: string;
  reported_id: string;
  match_id: string | null;
  session_id: string | null;
  story_id: string | null;
  reason: DriftReportReason;
  custom_reason: string | null;
  status: DriftReportStatus;
  reviewed_by: string | null;
  reviewed_at: string | null;
  action_taken: DriftModerationAction | null;
  moderator_notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface DriftTrustScore {
  id: string;
  user_id: string;
  score: number; // 0-100
  positive_signals: number;
  negative_signals: number;
  report_count: number;
  no_show_count: number;
  successful_drifts: number;
  computed_at: string;
  created_at: string;
  updated_at: string;
}

export interface DriftSessionActivityLog {
  id: string;
  session_id: string;
  user_id: string | null;
  event_type: string;
  event_data: Json;
  created_at: string;
}

export interface DriftModerationQueue {
  id: string;
  report_id: string;
  priority: number; // 1=high, 2=medium, 3=low
  assigned_to: string | null;
  assigned_at: string | null;
  resolved_at: string | null;
  created_at: string;
  updated_at: string;
}

// ─── API Response Types ───────────────────────────────────────────────────────

export interface NearbyUser {
  user_id: string;
  display_name: string;
  avatar_url: string | null;
  drift_vibe_tags: string[];
  drift_openness: DriftOpenness;
  activity_emoji: string;
  activity_label: string;
  distance_km: number;
  session_id: string;
}

export interface PublicStory {
  id: string;
  emoji: string;
  text: string;
  city: string;
  activity_tag: string | null;
  activity_emoji: string | null;
  vibe_tags: string[];
  reaction_count: number;
  published_at: string;
}

export interface MatchDetails {
  id: string;
  matched_user: {
    user_id: string;
    display_name: string;
    avatar_url: string | null;
    vibe_tags: string[];
  };
  status: DriftMatchStatus;
  initiated_at: string;
  expires_at: string;
}

// ─── Error Types ─────────────────────────────────────────────────────────────

export interface ApiError {
  error: {
    code: string;
    message: string;
    status: number;
    details?: Json;
  };
}

export interface ApiSuccess<T> {
  data: T;
  meta?: {
    total?: number;
    page?: number;
    per_page?: number;
  };
}
