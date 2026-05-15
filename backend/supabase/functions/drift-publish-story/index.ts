import { handleCors } from '../_shared/cors.ts';
import { requireAuth, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { isUuid, requireFields } from '../_shared/validation.ts';
import { assertEnv, getEnv } from '../_shared/env.ts';

assertEnv();

interface PublishStoryBody {
  emoji: string;
  text: string;
  city: string;
  country_code?: string;
  activity_tag?: string;
  activity_emoji?: string;
  vibe_tags?: string[];
}

interface DeleteStoryBody {
  story_id: string;
}

const MAX_VIBE_TAGS = 5;

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const auth = await requireAuth(req);
  if (auth instanceof Response) return auth;
  const { userId, adminClient } = auth;

  // ── DELETE /drift-publish-story (soft-delete own story) ──────────────────
  if (req.method === 'DELETE') {
    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return errorResponse('VALIDATION_INVALID_JSON', 'Invalid JSON body', 400);
    }

    const validated = requireFields<DeleteStoryBody>(body, ['story_id']);
    if (typeof validated === 'string') {
      return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
    }

    if (!isUuid(validated.story_id)) {
      return errorResponse('VALIDATION_INVALID_FIELD', 'story_id must be a valid UUID', 400);
    }

    const { error } = await adminClient
      .from('drift_stories')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', validated.story_id)
      .eq('user_id', userId)
      .is('deleted_at', null);

    if (error) {
      console.error('drift-publish-story delete error:', error);
      return errorResponse('SYSTEM_DB_ERROR', 'Failed to delete story', 500);
    }

    return jsonResponse({ success: true });
  }

  if (req.method !== 'POST') {
    return errorResponse('METHOD_NOT_ALLOWED', 'POST or DELETE only', 405);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return errorResponse('VALIDATION_INVALID_JSON', 'Invalid JSON body', 400);
  }

  const validated = requireFields<PublishStoryBody>(body, ['emoji', 'text', 'city']);
  if (typeof validated === 'string') {
    return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
  }

  const { emoji, text, city, country_code, activity_tag, activity_emoji, vibe_tags } = validated;

  // Field validation
  if (typeof emoji !== 'string' || emoji.trim().length === 0) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'emoji is required', 400);
  }
  if (typeof text !== 'string' || text.trim().length < 1 || text.trim().length > 140) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'text must be 1-140 characters', 400);
  }
  if (typeof city !== 'string' || city.trim().length < 1 || city.trim().length > 100) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'city must be 1-100 characters', 400);
  }
  if (country_code !== undefined && (typeof country_code !== 'string' || country_code.length !== 2)) {
    return errorResponse('VALIDATION_INVALID_FIELD', 'country_code must be 2 characters', 400);
  }
  if (vibe_tags !== undefined && (!Array.isArray(vibe_tags) || vibe_tags.length > MAX_VIBE_TAGS)) {
    return errorResponse('VALIDATION_INVALID_FIELD', `Maximum ${MAX_VIBE_TAGS} vibe tags`, 400);
  }

  const storyRateLimit = getEnv().drift.maxStoriesPerHour;
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count } = await adminClient
    .from('drift_stories')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .gte('created_at', oneHourAgo)
    .is('deleted_at', null);

  if ((count ?? 0) >= storyRateLimit) {
    return errorResponse(
      'RATE_LIMIT_STORIES',
      `Maximum ${storyRateLimit} stories per hour`,
      429
    );
  }

  const { data: story, error: insertError } = await adminClient
    .from('drift_stories')
    .insert({
      user_id:        userId,
      emoji:          emoji.trim(),
      text:           text.trim(),
      city:           city.trim(),
      country_code:   country_code?.toUpperCase() ?? null,
      activity_tag:   activity_tag?.trim() ?? null,
      activity_emoji: activity_emoji?.trim() ?? null,
      vibe_tags:      vibe_tags ?? [],
    })
    .select('id, emoji, text, city, country_code, activity_tag, activity_emoji, vibe_tags, reaction_count, published_at')
    .single();

  if (insertError) {
    console.error('drift-publish-story insert error:', insertError);
    return errorResponse('SYSTEM_DB_ERROR', 'Failed to publish story', 500);
  }

  // NOTE: user_id is intentionally excluded from the response to preserve anonymity
  return jsonResponse({ success: true, story }, 201);
});
