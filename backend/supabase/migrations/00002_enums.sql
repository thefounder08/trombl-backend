-- ============================================================
-- Migration: 00002_enums
-- Description: All platform and feature enums
-- ============================================================

-- ─── Trombl Platform Enums ──────────────────────────────────────────────────

CREATE TYPE public.trombl_notification_type AS ENUM (
  'drift_nearby',
  'drift_match_request',
  'drift_match_accepted',
  'drift_match_declined',
  'drift_session_expiring',
  'drift_contact_revealed',
  'drift_story_reaction',
  'safety_alert',
  'system'
);

CREATE TYPE public.trombl_platform AS ENUM (
  'ios',
  'android',
  'web'
);

-- ─── Drift Feature Enums ─────────────────────────────────────────────────────

CREATE TYPE public.drift_session_status AS ENUM (
  'active',
  'expired',
  'cancelled',
  'completed'
);

CREATE TYPE public.drift_match_status AS ENUM (
  'pending',
  'accepted',
  'declined',
  'expired',
  'cancelled',
  'completed'
);

CREATE TYPE public.drift_openness AS ENUM (
  'open',       -- yes, why not
  'maybe',      -- solo but open
  'solo'        -- not open to meeting
);

CREATE TYPE public.drift_timeframe AS ENUM (
  'right_now',
  'in_30_min',
  'in_1_hour'
);

CREATE TYPE public.drift_contact_type AS ENUM (
  'instagram',
  'whatsapp',
  'phone'
);

CREATE TYPE public.drift_report_reason AS ENUM (
  'made_me_feel_unsafe',
  'didnt_show_up',
  'inappropriate_behaviour',
  'fake_profile',
  'harassment',
  'spam',
  'other'
);

CREATE TYPE public.drift_report_status AS ENUM (
  'open',
  'reviewing',
  'resolved_actioned',
  'resolved_dismissed'
);

CREATE TYPE public.drift_moderation_action AS ENUM (
  'warn',
  'suspend',
  'ban',
  'dismiss'
);

CREATE TYPE public.drift_story_reaction_type AS ENUM (
  'heart',
  'spark',
  'wave',
  'coffee'
);
