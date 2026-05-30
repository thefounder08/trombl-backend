import { handleCors } from '../_shared/cors.ts';
import { requireAuth, jsonResponse, errorResponse } from '../_shared/auth.ts';
import { isUuid, requireFields } from '../_shared/validation.ts';
import { createNotification, sendPushNotification } from '../_shared/notifications.ts';
import { assertEnv } from '../_shared/env.ts';

assertEnv();

type ContactType = 'instagram' | 'whatsapp' | 'phone';

interface ConsentBody {
  match_id: string;
  contact_type: ContactType;
}

interface RevealBody {
  match_id: string;
}

const VALID_CONTACT_TYPES: ContactType[] = ['instagram', 'whatsapp', 'phone'];
const CONTACT_FIELD_MAP: Record<ContactType, string> = {
  instagram: 'instagram_handle',
  whatsapp:  'whatsapp_number',
  phone:     'phone_number',
};

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const auth = await requireAuth(req);
  if (auth instanceof Response) return auth;
  const { userId, adminClient } = auth;

  const url = new URL(req.url);
  const pathAction = url.pathname.split('/').pop();

  if (req.method !== 'POST') {
    return errorResponse('METHOD_NOT_ALLOWED', 'POST only', 405);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return errorResponse('VALIDATION_INVALID_JSON', 'Invalid JSON body', 400);
  }

  // ── POST /drift-contact-reveal/consent ───────────────────────────────────
  if (pathAction === 'consent') {
    const validated = requireFields<ConsentBody>(body, ['match_id', 'contact_type']);
    if (typeof validated === 'string') {
      return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
    }
    const { match_id, contact_type } = validated;

    if (!isUuid(match_id)) {
      return errorResponse('VALIDATION_INVALID_FIELD', 'match_id must be a valid UUID', 400);
    }
    if (!VALID_CONTACT_TYPES.includes(contact_type)) {
      return errorResponse('VALIDATION_INVALID_FIELD', `contact_type must be one of: ${VALID_CONTACT_TYPES.join(', ')}`, 400);
    }

    // Verify the user has an accepted match
    const { data: match } = await adminClient
      .from('drift_matches')
      .select('id, initiator_id, target_id, status')
      .eq('id', match_id)
      .eq('status', 'accepted')
      .gt('expires_at', new Date().toISOString())
      .single();

    if (!match) {
      return errorResponse('DRIFT_MATCH_NOT_FOUND', 'No accepted match found', 404);
    }

    const isInitiator = match.initiator_id === userId;
    const isTarget    = match.target_id    === userId;
    if (!isInitiator && !isTarget) {
      return errorResponse('AUTH_FORBIDDEN', 'Not a participant of this match', 403);
    }

    // Verify user has the contact info they're consenting to share
    const profileField = CONTACT_FIELD_MAP[contact_type];
    const { data: profile } = await adminClient
      .from('trombl_profiles')
      .select(profileField)
      .eq('id', userId)
      .single();

    if (!profile || !profile[profileField]) {
      return errorResponse(
        'DRIFT_NO_CONTACT_INFO',
        `You have not set a ${contact_type} handle on your profile`,
        422
      );
    }

    // Upsert the consent record — contact value is NEVER stored here.
    // Uses atomic upsert (ON CONFLICT match_id) to avoid a race condition
    // where two simultaneous consent calls both see no existing row and both
    // try to INSERT, causing a unique-constraint 500 on the second call.
    const consentField      = isInitiator ? 'initiator_consented'    : 'target_consented';
    const contactTypeField  = isInitiator ? 'initiator_contact_type' : 'target_contact_type';

    const { data: exchangeRecord, error: upsertError } = await adminClient
      .from('drift_contact_exchange')
      .upsert(
        { match_id, [contactTypeField]: contact_type, [consentField]: true },
        { onConflict: 'match_id', ignoreDuplicates: false }
      )
      .select()
      .single();

    if (upsertError) {
      console.error('drift-contact-reveal upsert error:', upsertError);
      return errorResponse('SYSTEM_DB_ERROR', 'Failed to record consent', 500);
    }

    // If mutual consent now, trigger notification for both parties
    if (exchangeRecord.initiator_consented && exchangeRecord.target_consented) {
      const otherUserId = isInitiator ? match.target_id : match.initiator_id;
      await Promise.all([
        createNotification({
          adminClient, userId, type: 'drift_contact_revealed',
          title: 'Contact reveal ready!',
          body: 'Both you and your match agreed. Tap to reveal contact details.',
          data: { match_id },
          expiresInHours: 0.1, // 6 minutes
        }),
        createNotification({
          adminClient, userId: otherUserId, type: 'drift_contact_revealed',
          title: 'Contact reveal ready!',
          body: 'Both you and your match agreed. Tap to reveal contact details.',
          data: { match_id },
          expiresInHours: 0.1,
        }),
        sendPushNotification(userId, adminClient, 'Contact reveal ready!', 'Tap to see contact info', { match_id }),
        sendPushNotification(otherUserId, adminClient, 'Contact reveal ready!', 'Tap to see contact info', { match_id }),
      ]);
    }

    return jsonResponse({ success: true, exchange: exchangeRecord });
  }

  // ── POST /drift-contact-reveal/reveal ────────────────────────────────────
  if (pathAction === 'reveal') {
    const validated = requireFields<RevealBody>(body, ['match_id']);
    if (typeof validated === 'string') {
      return errorResponse('VALIDATION_MISSING_FIELD', validated, 400);
    }
    const { match_id } = validated;

    if (!isUuid(match_id)) {
      return errorResponse('VALIDATION_INVALID_FIELD', 'match_id must be a valid UUID', 400);
    }

    // SECURITY DEFINER function does all auth/timing validation
    const { data: revealed, error } = await adminClient.rpc('get_revealed_contact', {
      p_match_id:           match_id,
      p_requesting_user_id: userId,
    });

    if (error) {
      console.error('drift-contact-reveal rpc error:', error);
      return errorResponse('SYSTEM_DB_ERROR', 'Failed to retrieve contact', 500);
    }

    if (!revealed) {
      return errorResponse(
        'DRIFT_CONTACT_UNAVAILABLE',
        'Contact reveal window has not opened or has expired',
        403
      );
    }

    return jsonResponse({ success: true, contact: revealed });
  }

  return errorResponse('NOT_FOUND', 'Invalid endpoint. Use /consent or /reveal', 404);
});
