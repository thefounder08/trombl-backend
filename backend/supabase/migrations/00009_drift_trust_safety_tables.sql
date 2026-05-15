-- ============================================================
-- Migration: 00009_drift_trust_safety_tables
-- Description: Trust scores, reports, moderation queue, presence
-- ============================================================

-- ─── drift_trust_scores ──────────────────────────────────────────────────────

CREATE TABLE public.drift_trust_scores (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  score             int NOT NULL DEFAULT 75 CHECK (score BETWEEN 0 AND 100),
  positive_signals  int NOT NULL DEFAULT 0,
  negative_signals  int NOT NULL DEFAULT 0,
  report_count      int NOT NULL DEFAULT 0,
  no_show_count     int NOT NULL DEFAULT 0,
  successful_drifts int NOT NULL DEFAULT 0,
  computed_at       timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unique_trust_score_per_user UNIQUE (user_id)
);

CREATE INDEX drift_trust_scores_user_idx ON drift_trust_scores (user_id);
CREATE INDEX drift_trust_scores_score_idx ON drift_trust_scores (score);

CREATE TRIGGER drift_trust_scores_updated_at
  BEFORE UPDATE ON drift_trust_scores
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Auto-create trust score row on profile creation
CREATE OR REPLACE FUNCTION public.create_trust_score_for_new_profile()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO drift_trust_scores (user_id)
  VALUES (NEW.id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trombl_profiles_create_trust_score
  AFTER INSERT ON trombl_profiles
  FOR EACH ROW EXECUTE FUNCTION public.create_trust_score_for_new_profile();

-- Recompute trust score (called after report or drift completion)
CREATE OR REPLACE FUNCTION public.recompute_trust_score(p_user_id uuid)
RETURNS int AS $$
DECLARE
  v_report_count      int;
  v_no_show_count     int;
  v_successful_drifts int;
  v_positive          int;
  v_negative          int;
  v_score             int;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE status IN ('resolved_actioned')),
    COUNT(*) FILTER (WHERE reason = 'didnt_show_up')
  INTO v_report_count, v_no_show_count
  FROM drift_reports
  WHERE reported_id = p_user_id;

  SELECT COUNT(*) INTO v_successful_drifts
  FROM drift_matches
  WHERE
    (initiator_id = p_user_id OR target_id = p_user_id)
    AND status = 'completed';

  v_positive := v_successful_drifts * 2;
  v_negative := (v_report_count * 10) + (v_no_show_count * 5);
  v_score    := GREATEST(0, LEAST(100, 75 + v_positive - v_negative));

  UPDATE drift_trust_scores
  SET
    score             = v_score,
    positive_signals  = v_positive,
    negative_signals  = v_negative,
    report_count      = v_report_count,
    no_show_count     = v_no_show_count,
    successful_drifts = v_successful_drifts,
    computed_at       = now(),
    updated_at        = now()
  WHERE user_id = p_user_id;

  RETURN v_score;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON TABLE drift_trust_scores IS
  'Computed trust scores for drift users. Recalculated on report/completion events. Score 0-100, default 75.';

-- ─── drift_reports ───────────────────────────────────────────────────────────

CREATE TABLE public.drift_reports (
  id               uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id      uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  reported_id      uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  match_id         uuid REFERENCES drift_matches(id) ON DELETE SET NULL,
  session_id       uuid REFERENCES drift_sessions(id) ON DELETE SET NULL,
  story_id         uuid REFERENCES drift_stories(id) ON DELETE SET NULL,
  reason           public.drift_report_reason NOT NULL,
  custom_reason    text CHECK (char_length(custom_reason) <= 500),
  status           public.drift_report_status NOT NULL DEFAULT 'open',
  reviewed_by      uuid REFERENCES trombl_profiles(id) ON DELETE SET NULL,
  reviewed_at      timestamptz,
  action_taken     public.drift_moderation_action,
  moderator_notes  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT no_self_report CHECK (reporter_id != reported_id)
);

CREATE INDEX drift_reports_reported_idx ON drift_reports (reported_id, created_at DESC);
CREATE INDEX drift_reports_reporter_idx ON drift_reports (reporter_id, created_at DESC);
CREATE INDEX drift_reports_status_idx   ON drift_reports (status, created_at DESC);

CREATE TRIGGER drift_reports_updated_at
  BEFORE UPDATE ON drift_reports
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- On new report: insert into moderation queue and update trust score signal
CREATE OR REPLACE FUNCTION public.handle_new_report()
RETURNS TRIGGER AS $$
DECLARE
  v_priority int;
BEGIN
  -- Prioritize safety reports higher
  v_priority := CASE NEW.reason
    WHEN 'made_me_feel_unsafe' THEN 1
    WHEN 'harassment'          THEN 1
    WHEN 'inappropriate_behaviour' THEN 2
    ELSE 3
  END;

  INSERT INTO drift_moderation_queue (report_id, priority)
  VALUES (NEW.id, v_priority)
  ON CONFLICT DO NOTHING;

  -- Apply immediate negative signal to trust score
  UPDATE drift_trust_scores
  SET
    negative_signals = negative_signals + 5,
    report_count     = report_count + 1,
    score            = GREATEST(0, score - 5),
    updated_at       = now()
  WHERE user_id = NEW.reported_id;

  -- Auto-ban if score drops to 0 or trust score very low
  UPDATE trombl_profiles
  SET
    is_banned  = true,
    banned_at  = now(),
    ban_reason = 'Automated: trust score critical threshold'
  WHERE
    id = NEW.reported_id
    AND EXISTS (
      SELECT 1 FROM drift_trust_scores
      WHERE user_id = NEW.reported_id AND score <= 0
    )
    AND is_banned = false;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER drift_reports_handle_new
  AFTER INSERT ON drift_reports
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_report();

COMMENT ON TABLE drift_reports IS
  'User reports for safety incidents. Triggers moderation queue entry on insert.';

-- ─── drift_moderation_queue ───────────────────────────────────────────────────

CREATE TABLE public.drift_moderation_queue (
  id           uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  report_id    uuid NOT NULL REFERENCES drift_reports(id) ON DELETE CASCADE,
  priority     int NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3), -- 1=high
  assigned_to  uuid REFERENCES trombl_profiles(id) ON DELETE SET NULL,
  assigned_at  timestamptz,
  resolved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unique_report_in_queue UNIQUE (report_id)
);

CREATE INDEX drift_moderation_queue_priority_idx
  ON drift_moderation_queue (priority, created_at)
  WHERE resolved_at IS NULL;

CREATE INDEX drift_moderation_queue_assigned_idx
  ON drift_moderation_queue (assigned_to)
  WHERE assigned_to IS NOT NULL AND resolved_at IS NULL;

CREATE TRIGGER drift_moderation_queue_updated_at
  BEFORE UPDATE ON drift_moderation_queue
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE drift_moderation_queue IS
  'Work queue for moderators. Priority 1=high (safety), 2=medium, 3=low. Service-role access only.';

-- ─── drift_presence ──────────────────────────────────────────────────────────

CREATE TABLE public.drift_presence (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     uuid NOT NULL REFERENCES trombl_profiles(id) ON DELETE CASCADE,
  session_id  uuid REFERENCES drift_sessions(id) ON DELETE SET NULL,
  is_online   boolean NOT NULL DEFAULT true,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  client_id   text, -- random client identifier per connection
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unique_presence_per_user UNIQUE (user_id)
);

CREATE INDEX drift_presence_online_idx
  ON drift_presence (last_seen_at DESC)
  WHERE is_online = true;

CREATE INDEX drift_presence_session_idx
  ON drift_presence (session_id)
  WHERE session_id IS NOT NULL AND is_online = true;

CREATE TRIGGER drift_presence_updated_at
  BEFORE UPDATE ON drift_presence
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Cleanup stale presence (> 2 min without heartbeat)
CREATE OR REPLACE FUNCTION public.cleanup_stale_presence()
RETURNS int AS $$
DECLARE
  updated_count int;
BEGIN
  UPDATE drift_presence
  SET is_online = false, updated_at = now()
  WHERE
    is_online = true
    AND last_seen_at < now() - interval '2 minutes';
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON TABLE drift_presence IS
  'Realtime presence tracking. Heartbeat-driven. Stale entries (>2min) auto-marked offline.';
