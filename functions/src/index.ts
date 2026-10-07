import { randomInt, randomUUID } from 'node:crypto';

import { initializeApp } from 'firebase-admin/app';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { defineSecret } from 'firebase-functions/params';
import * as logger from 'firebase-functions/logger';

import {
  AccessPolicy,
  StoredReservation,
  StoredToken,
  TOKEN_TTL_SECONDS,
  canIssueToken,
  userMessage,
} from './accessPolicy';

/**
 * The two Cloud Functions from the Milestone 2 design.
 *
 * Milestone 1 specified six backend services. That was cut to two during
 * implementation: everything else reads and writes Firestore directly under
 * security rules. What survives the cut is the rule that matters, which is that
 * only the server may decide whether a code opens a locker.
 *
 * This file is the wiring. It reads the request, asks `AccessPolicy`, and
 * writes the result down. The rules themselves are in `accessPolicy.ts` and are
 * covered by Jest to the branch; this file is excluded from coverage because
 * testing it would mean running the Firestore emulator in CI for very little
 * return.
 *
 * ### Where this runs
 *
 * In the Firebase Local Emulator Suite, not deployed. Deploying Cloud Functions
 * requires the Blaze plan and a payment method, and this is a student project
 * with no budget. The architecture is unaffected. Reported as a scoped
 * limitation.
 */

initializeApp();

/**
 * The signing key. Held as a secret so it is never in the repository and never
 * in the application. A key that reaches a phone is a key that has been given
 * away.
 */
const signingKey = defineSecret('SCLS_SIGNING_KEY');

const db = getFirestore();

/** FR4. Issues a signed, single use code with a 120 second life. */
export const issueAccessToken = onCall(
  { secrets: [signingKey], region: 'australia-southeast1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Sign in first.');
    }

    const reservationId = asString(request.data?.reservationId);
    if (!reservationId) {
      throw new HttpsError('invalid-argument', 'A booking is required.');
    }
    const delegateUserId = asString(request.data?.delegateUserId);

    const reservation = await loadReservation(reservationId);
    if (!reservation) {
      throw new HttpsError('not-found', 'That booking no longer exists.');
    }
    if (reservation.userId !== uid) {
      // Same message as a missing booking. Telling a caller that a booking
      // exists but is not theirs is a way to enumerate other people's bookings.
      throw new HttpsError('not-found', 'That booking no longer exists.');
    }
    if (!canIssueToken(reservation.state)) {
      throw new HttpsError(
        'failed-precondition',
        'That booking is no longer active, so no code can be issued.',
      );
    }
    if (delegateUserId && delegateUserId === uid) {
      throw new HttpsError(
        'invalid-argument',
        'You already have access to this locker.',
      );
    }

    const policy = new AccessPolicy(signingKey.value());
    const now = Date.now();
    const tokenId = randomUUID();
    const expiresAt = now + TOKEN_TTL_SECONDS * 1000;

    const payload = policy.sign({
      tid: tokenId,
      rid: reservation.id,
      sid: reservation.stationId,
      cid: reservation.compartmentId,
      iat: now,
      exp: expiresAt,
    });

    await db.collection('accessTokens').doc(tokenId).set({
      reservationId: reservation.id,
      issuedAt: now,
      expiresAt,
      singleUse: true,
      used: false,
      delegatedTo: delegateUserId ?? null,
      issuedBy: uid,
      createdAt: FieldValue.serverTimestamp(),
    });

    // The backup PIN belongs to the booking rather than the token, because it
    // has to keep working when the network is down and no new token can be
    // fetched (QR4). Only a hash is stored; the cabinet caches the same hash.
    const pin = await ensurePin(reservation.id);

    return { tokenId, payload, expiresAt, fallbackPin: pin };
  },
);

/**
 * FR5. Decides whether a presented credential opens a locker.
 *
 * The cabinet reaches this same code by publishing what it scanned to MQTT. The
 * application reaches it directly, which is the remote open path Milestone 1
 * chose to build first because it needs no camera.
 */
export const handleScan = onCall(
  { secrets: [signingKey], region: 'australia-southeast1' },
  async (request) => {
    const uid = request.auth?.uid ?? null;
    const payload = asString(request.data?.payload);
    const stationId = asString(request.data?.stationId) ?? 'unknown';
    const compartmentId = asString(request.data?.compartmentId) ?? 'unknown';

    if (!payload) {
      throw new HttpsError('invalid-argument', 'No code was presented.');
    }

    const policy = new AccessPolicy(signingKey.value());
    const now = Date.now();

    const claims = policy.verify(payload);
    const storedToken = claims ? await loadToken(claims.tid) : null;
    const reservation = storedToken
      ? await loadReservation(storedToken.reservationId)
      : null;

    const decision = policy.decide({
      payload,
      now,
      storedToken,
      reservation,
      presentedBy: uid,
    });

    // Every attempt is written down, accepted or not. E4 asks for the refusals
    // to be logged as well as refused, and QR5 asks for every open to be
    // attributable. The payload and the signature are never written: a log you
    // can replay from is not an audit trail.
    await db.collection('accessLog').add({
      stationId,
      compartmentId,
      tokenId: claims?.tid ?? null,
      reservationId: storedToken?.reservationId ?? null,
      presentedBy: uid,
      decision,
      at: FieldValue.serverTimestamp(),
    });

    if (decision !== 'accepted') {
      logger.info('Access refused', { decision, stationId, compartmentId });
      return { accepted: false, decision, message: userMessage(decision) };
    }

    // Spend the token and move the booking on. A booking becomes active at its
    // first successful open, not at its start time, because users arrive late.
    await db.collection('accessTokens').doc(storedToken!.id).update({
      used: true,
      usedAt: FieldValue.serverTimestamp(),
    });
    if (reservation!.state === 'confirmed') {
      await db
        .collection('reservations')
        .doc(reservation!.id)
        .update({ state: 'active' });
    }

    // The open command goes to the cabinet over MQTT, and the cabinet reports
    // what the door actually did on a separate topic. Publishing is not wired
    // up in this build: the Python simulator in `simulator/` plays the cabinet.
    logger.info('Access granted', {
      tokenId: storedToken!.id,
      stationId,
      compartmentId,
    });

    return {
      accepted: true,
      decision,
      message: userMessage(decision),
      tokenId: storedToken!.id,
    };
  },
);

async function loadReservation(id: string): Promise<StoredReservation | null> {
  const snapshot = await db.collection('reservations').doc(id).get();
  if (!snapshot.exists) return null;
  const data = snapshot.data() ?? {};
  return {
    id: snapshot.id,
    userId: String(data.userId ?? ''),
    stationId: String(data.stationId ?? ''),
    compartmentId: String(data.compartmentId ?? ''),
    state: data.state,
  };
}

async function loadToken(id: string): Promise<StoredToken | null> {
  const snapshot = await db.collection('accessTokens').doc(id).get();
  if (!snapshot.exists) return null;
  const data = snapshot.data() ?? {};
  return {
    id: snapshot.id,
    reservationId: String(data.reservationId ?? ''),
    issuedAt: Number(data.issuedAt ?? 0),
    expiresAt: Number(data.expiresAt ?? 0),
    singleUse: data.singleUse !== false,
    used: data.used === true,
    delegatedTo: data.delegatedTo ?? null,
  };
}

/**
 * Returns the booking's backup PIN, creating one the first time it is asked
 * for. Only a hash is kept, so the PIN itself is returned exactly once per
 * booking and never again.
 */
async function ensurePin(reservationId: string): Promise<string | null> {
  const ref = db.collection('reservationPins').doc(reservationId);
  const existing = await ref.get();
  if (existing.exists) return null;

  const pin = String(randomInt(0, 10_000)).padStart(4, '0');
  const { createHash } = await import('node:crypto');
  const hash = createHash('sha256')
    .update(`${reservationId}:${pin}:${signingKey.value()}`, 'utf8')
    .digest('base64url');

  await ref.set({ hash, createdAt: FieldValue.serverTimestamp() });
  return pin;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}
