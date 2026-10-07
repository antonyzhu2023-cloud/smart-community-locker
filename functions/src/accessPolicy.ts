import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * The rules that decide whether a presented credential opens a locker.
 *
 * FR4 and FR5, and the whole of evaluation criterion E4.
 *
 * This is the authoritative copy. The Dart class of the same name in
 * `app/lib/domain/access_policy.dart` is a development stand-in, so the
 * application can be built and demonstrated without a backend running. The two
 * exist because the Milestone 1 stack put the app in Dart and the backend in
 * TypeScript, and the two cannot share a module. Both are tested against the
 * same table of cases, which is the only thing keeping them in step.
 *
 * The cabinet never runs any of this. It publishes what it scanned and waits to
 * be told. A cabinet that could decide for itself would need the signing key on
 * a device sitting in a building lobby.
 */

/** The standard life of a token. FR4. */
export const TOKEN_TTL_SECONDS = 120;

/**
 * Allowance for the difference between the issuing clock and the checking one.
 * E4 requires the 120 second life to hold to within 2 seconds, so this stays
 * small: a generous skew quietly extends the life of every token.
 */
export const DEFAULT_CLOCK_SKEW_SECONDS = 2;

export type AccessDecision =
  | 'accepted'
  | 'expired'
  | 'alreadyUsed'
  | 'invalidSignature'
  | 'unknownToken'
  | 'bookingNotOpenable'
  | 'notYours';

export interface AccessTokenClaims {
  /** Token id. */
  tid: string;
  /** Reservation id. */
  rid: string;
  /** Station id. */
  sid: string;
  /** Compartment id. */
  cid: string;
  /** Issued at, milliseconds since the epoch, UTC. */
  iat: number;
  /** Expires at, milliseconds since the epoch, UTC. */
  exp: number;
}

export interface StoredToken {
  id: string;
  reservationId: string;
  issuedAt: number;
  expiresAt: number;
  singleUse: boolean;
  used: boolean;
  /** Set when this token was handed to another user (FR7). */
  delegatedTo?: string | null;
}

/** Only these two states may open a locker. Milestone 1, booking state machine. */
export type ReservationState =
  | 'requested'
  | 'confirmed'
  | 'active'
  | 'overdue'
  | 'completed'
  | 'cancelled'
  | 'expired';

export interface StoredReservation {
  id: string;
  userId: string;
  stationId: string;
  compartmentId: string;
  state: ReservationState;
}

export interface DecideInput {
  payload: string;
  /** Milliseconds since the epoch. Passed in so there is no hidden clock. */
  now: number;
  storedToken?: StoredToken | null;
  reservation?: StoredReservation | null;
  /**
   * Who is presenting. Comes from the Firebase ID token on the call, which the
   * holder of a credential cannot forge.
   */
  presentedBy?: string | null;
}

/**
 * Base64url with padding.
 *
 * Node's built-in 'base64url' encoding strips the `=` padding and Dart's
 * `base64Url.encode` keeps it. The two implementations of this policy would
 * therefore produce different strings for the same claims, and a token signed
 * by one would fail verification by the other. Padding is added back here so
 * the two agree. This is the kind of thing that only shows up when the same
 * rule is written twice in two languages.
 */
function b64u(buffer: Buffer): string {
  const raw = buffer.toString('base64url');
  const remainder = raw.length % 4;
  return remainder === 0 ? raw : raw + '='.repeat(4 - remainder);
}

function b64uDecode(value: string): Buffer {
  return Buffer.from(value.replace(/=+$/, ''), 'base64url');
}

export class AccessPolicy {
  constructor(
    private readonly secret: string,
    private readonly clockSkewSeconds: number = DEFAULT_CLOCK_SKEW_SECONDS,
  ) {
    if (!secret) {
      throw new Error('AccessPolicy needs a signing key');
    }
  }

  /**
   * Builds the payload that goes into the QR code.
   *
   * The signature covers every field, so changing any of them invalidates it.
   * That is what makes the "altered payload" case in E4 fail closed rather than
   * being a check somebody has to remember to write.
   */
  sign(claims: AccessTokenClaims): string {
    const body = b64u(Buffer.from(JSON.stringify(claims), 'utf8'));
    return `${body}.${this.mac(body)}`;
  }

  private mac(body: string): string {
    return b64u(createHmac('sha256', this.secret).update(body, 'utf8').digest());
  }

  /** Returns the claims if the signature is intact, or null. */
  verify(payload: string): AccessTokenClaims | null {
    const dot = payload.lastIndexOf('.');
    if (dot <= 0 || dot === payload.length - 1) return null;

    const body = payload.slice(0, dot);
    const signature = payload.slice(dot + 1);
    if (!this.signatureMatches(signature, this.mac(body))) return null;

    try {
      const parsed: unknown = JSON.parse(b64uDecode(body).toString('utf8'));
      return isClaims(parsed) ? parsed : null;
    } catch {
      return null;
    }
  }

  /**
   * Constant-time comparison, so a caller cannot learn the correct signature
   * one byte at a time by measuring how long a rejection takes.
   */
  private signatureMatches(a: string, b: string): boolean {
    const left = Buffer.from(a, 'utf8');
    const right = Buffer.from(b, 'utf8');
    // timingSafeEqual throws on a length mismatch, which would itself leak the
    // length, so the lengths are compared first and the rest is still constant
    // time for equal-length inputs.
    if (left.length !== right.length) return false;
    return timingSafeEqual(left, right);
  }

  /**
   * Decides what to do with a presented payload.
   *
   * Everything the decision depends on is an argument, including the clock, so
   * there is no hidden state and nothing to stub in a test.
   */
  decide(input: DecideInput): AccessDecision {
    const { payload, now, storedToken, reservation, presentedBy } = input;

    const claims = this.verify(payload);
    if (!claims) return 'invalidSignature';

    // Identity before anything else. A valid signature only proves the server
    // minted this token, not that the person holding it should have it.
    if (!storedToken) return 'unknownToken';
    if (storedToken.id !== claims.tid) return 'unknownToken';

    if (storedToken.used && storedToken.singleUse) return 'alreadyUsed';

    // The stored expiry wins over the one in the payload. They should agree,
    // but only one of them is out of the holder's reach.
    const skewMs = this.clockSkewSeconds * 1000;
    if (now >= storedToken.expiresAt + skewMs) return 'expired';

    if (!reservation) return 'unknownToken';
    if (reservation.id !== storedToken.reservationId) return 'unknownToken';

    // The single rule from Milestone 1 that FR4 exists to enforce.
    if (!canIssueToken(reservation.state)) return 'bookingNotOpenable';

    if (presentedBy && !belongsTo(storedToken, reservation, presentedBy)) {
      return 'notYours';
    }

    return 'accepted';
  }
}

/** A token may be issued while confirmed or active, and at no other time. */
export function canIssueToken(state: ReservationState): boolean {
  return state === 'confirmed' || state === 'active';
}

/**
 * A token opens a locker for the person who booked it, or for the one person it
 * was handed to (FR7). Nobody else, including other verified residents.
 */
function belongsTo(
  token: StoredToken,
  reservation: StoredReservation,
  userId: string,
): boolean {
  if (token.delegatedTo) return token.delegatedTo === userId;
  return reservation.userId === userId;
}

function isClaims(value: unknown): value is AccessTokenClaims {
  if (typeof value !== 'object' || value === null) return false;
  const c = value as Record<string, unknown>;
  return (
    typeof c.tid === 'string' &&
    typeof c.rid === 'string' &&
    typeof c.sid === 'string' &&
    typeof c.cid === 'string' &&
    typeof c.iat === 'number' &&
    typeof c.exp === 'number'
  );
}

/**
 * What the user is told.
 *
 * Deliberately vague about which check a credential tripped, beyond what helps
 * a legitimate user act. Telling somebody holding a forgery that the signature
 * failed is free help for the next attempt.
 */
export function userMessage(decision: AccessDecision): string {
  switch (decision) {
    case 'accepted':
      return 'Opening the locker.';
    case 'expired':
      return 'That code has expired. Get a new one.';
    case 'alreadyUsed':
      return 'That code has already been used.';
    case 'bookingNotOpenable':
      return 'That booking is no longer active, so it cannot open a locker.';
    case 'invalidSignature':
    case 'unknownToken':
    case 'notYours':
      return 'That code was not accepted.';
  }
}
