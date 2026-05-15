-- ============================================================
-- Migration: 00010_seed_data
-- Description: Reference data for activity types and vibe tags
-- ============================================================

-- ─── Drift Activity Types ─────────────────────────────────────────────────────

INSERT INTO drift_activity_types (id, emoji, label, sub_label, sort_order) VALUES
  (uuid_generate_v4(), '☕', 'Coffee',    'solo or with a stranger',      1),
  (uuid_generate_v4(), '🚶', 'Walk',      'no destination needed',         2),
  (uuid_generate_v4(), '📖', 'Reading',   'park, café, anywhere',          3),
  (uuid_generate_v4(), '✏️', 'Sketching', 'drawing, doodling, journaling', 4),
  (uuid_generate_v4(), '🎵', 'Listening', 'music, podcast, silence',       5),
  (uuid_generate_v4(), '🏷️', 'Thrifting', 'vintage, secondhand',           6),
  (uuid_generate_v4(), '🍜', 'Eating',    'trying something new',          7),
  (uuid_generate_v4(), '🏃', 'Running',   'slow is fine too',              8),
  (uuid_generate_v4(), '📷', 'Shooting',  'film, phone, whatever',         9),
  (uuid_generate_v4(), '🌿', 'Sitting',   'just existing outside',        10)
ON CONFLICT (label) DO NOTHING;

-- ─── Drift Vibe Tags ──────────────────────────────────────────────────────────

INSERT INTO drift_vibe_tags (id, label, sort_order) VALUES
  (uuid_generate_v4(), 'introvert-friendly',    1),
  (uuid_generate_v4(), 'no small talk',         2),
  (uuid_generate_v4(), 'open to anything',      3),
  (uuid_generate_v4(), 'a bit anxious',         4),
  (uuid_generate_v4(), 'needs coffee first',    5),
  (uuid_generate_v4(), 'creative energy',       6),
  (uuid_generate_v4(), 'philosopher vibes',     7),
  (uuid_generate_v4(), 'just existing',         8),
  (uuid_generate_v4(), 'slow morning',          9),
  (uuid_generate_v4(), 'spontaneous',          10),
  (uuid_generate_v4(), 'music person',         11),
  (uuid_generate_v4(), 'city explorer',        12)
ON CONFLICT (label) DO NOTHING;
