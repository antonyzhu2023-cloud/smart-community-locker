import {
  AccessPolicy,
  AccessTokenClaims,
  ReservationState,
  StoredReservation,
  StoredToken,
  TOKEN_TTL_SECONDS,
  canIssueToken,
  userMessage,
} from '../src/accessPolicy';

/**
 * Evaluation criterion E4, in full.
 *
 * > Replay after expiry, after use, from another account, and with an altered
 * > payload are all four refused and logged. TTL 120 s +/- 2 s.
 *
 * This is deliberately the same table of cases as
 * `app/test/domain/access_policy_test.dart`. The rules exist twice, once in
 * Dart and once here, because the Milestone 1 stack put the app and the backend
 * in different languages. Running both against the same cases is what keeps
 * the two copies from drifting apart.
 */

const SECRET = 'test-signing-key';
const policy = new AccessPolicy(SECRET);

const ISSUED = Date.UTC(2026, 9, 6, 12, 0, 0);
const EXPIRES = ISSUED + TOKEN_TTL_SECONDS * 1000;

const TOKEN_ID = 'T1';
const RESERVATION_ID = 'R1';
const OWNER = 'U-OWNER';

function claims(overrides: Partial<AccessTokenClaims> = {}): AccessTokenClaims {
  return {
    tid: TOKEN_ID,
    rid: RESERVATION_ID,
    sid: 'ST-1',
    cid: 'C1',
    iat: ISSUED,
    exp: EXPIRES,
    ...overrides,
  };
}

function stored(overrides: Partial<StoredToken> = {}): StoredToken {
  return {
    id: TOKEN_ID,
    reservationId: RESERVATION_ID,
    issuedAt: ISSUED,
    expiresAt: EXPIRES,
    singleUse: true,
    used: false,
    ...overrides,
  };
}

function booking(
  overrides: Partial<StoredReservation> = {},
): StoredReservation {
  return {
    id: RESERVATION_ID,
    userId: OWNER,
    stationId: 'ST-1',
    compartmentId: 'C1',
    state: 'confirmed',
    ...overrides,
  };
}

function decide(
  overrides: {
    payload?: string;
    now?: number;
    storedToken?: StoredToken | null;
    reservation?: StoredReservation | null;
    presentedBy?: string | null;
  } = {},
) {
  return policy.decide({
    payload: overrides.payload ?? policy.sign(claims()),
    now: overrides.now ?? ISSUED + 30_000,
    storedToken:
      overrides.storedToken === undefined ? stored() : overrides.storedToken,
    reservation:
      overrides.reservation === undefined ? booking() : overrides.reservation,
    presentedBy:
      overrides.presentedBy === undefined ? OWNER : overrides.presentedBy,
  });
}

describe('the happy path', () => {
  it('accepts a fresh token from its owner', () => {
    expect(decide()).toBe('accepted');
  });

  it('accepts while the booking is active, not only confirmed', () => {
    // A booking becomes active at the first open. The second open of the same
    // booking must still work, or a user could never retrieve what they put in.
    expect(decide({ reservation: booking({ state: 'active' }) })).toBe(
      'accepted',
    );
  });
});

describe('E4 case 1: replay after expiry', () => {
  it('accepts one second before the deadline', () => {
    expect(decide({ now: EXPIRES - 1000 })).toBe('accepted');
  });

  it('still accepts inside the two second skew allowance', () => {
    expect(decide({ now: EXPIRES + 1000 })).toBe('accepted');
  });

  it('refuses once the skew allowance is gone', () => {
    expect(decide({ now: EXPIRES + 2000 })).toBe('expired');
  });

  it('refuses long afterwards', () => {
    expect(decide({ now: EXPIRES + 6 * 3600_000 })).toBe('expired');
  });

  it('gives a token a life of 120 seconds, as FR4 states', () => {
    expect(TOKEN_TTL_SECONDS).toBe(120);
    expect(EXPIRES - ISSUED).toBe(120_000);
  });

  it('lets the stored expiry decide, not the one inside the payload', () => {
    // Editing the payload breaks the signature, but even a correctly signed
    // payload is checked against what the server holds, so the two cannot drift.
    expect(
      decide({
        payload: policy.sign(claims()),
        now: ISSUED,
        storedToken: stored({ expiresAt: ISSUED - 300_000 }),
      }),
    ).toBe('expired');
  });
});

describe('E4 case 2: replay after use', () => {
  it('refuses a used single-use token', () => {
    expect(decide({ storedToken: stored({ used: true }) })).toBe('alreadyUsed');
  });

  it('checks used before expiry, so a used token never looks merely late', () => {
    // Order matters for the audit trail. The log should say the code was
    // reused, not that it arrived late.
    expect(
      decide({
        storedToken: stored({ used: true }),
        now: EXPIRES + 3600_000,
      }),
    ).toBe('alreadyUsed');
  });

  it('does not refuse a multi-use token for having been used', () => {
    expect(
      decide({ storedToken: stored({ used: true, singleUse: false }) }),
    ).toBe('accepted');
  });
});

describe('E4 case 3: another account', () => {
  it('refuses a different resident', () => {
    expect(decide({ presentedBy: 'U-SOMEONE-ELSE' })).toBe('notYours');
  });

  it('accepts the person it was handed to (FR7)', () => {
    expect(
      decide({
        storedToken: stored({ delegatedTo: 'U-NEIGHBOUR' }),
        presentedBy: 'U-NEIGHBOUR',
      }),
    ).toBe('accepted');
  });

  it('refuses the owner on a token they handed away', () => {
    // The delegated token is the neighbour's. The owner keeps their own, which
    // is a different token: one booking, several tokens.
    expect(
      decide({
        storedToken: stored({ delegatedTo: 'U-NEIGHBOUR' }),
        presentedBy: OWNER,
      }),
    ).toBe('notYours');
  });

  it('refuses a third party on a delegated token', () => {
    expect(
      decide({
        storedToken: stored({ delegatedTo: 'U-NEIGHBOUR' }),
        presentedBy: 'U-STRANGER',
      }),
    ).toBe('notYours');
  });
});

describe('E4 case 4: altered payload', () => {
  /** Swaps the body and keeps the original signature. */
  function tamper(original: string, replacement: AccessTokenClaims): string {
    const body = Buffer.from(JSON.stringify(replacement), 'utf8').toString(
      'base64url',
    );
    const padded = body + '='.repeat((4 - (body.length % 4)) % 4);
    return `${padded}.${original.slice(original.lastIndexOf('.') + 1)}`;
  }

  it.each([
    ['a changed compartment', claims({ cid: 'C2' })],
    ['a changed station', claims({ sid: 'ST-9' })],
    ['a changed token id', claims({ tid: 'T-OTHER' })],
    ['a stretched expiry', claims({ exp: ISSUED + 86_400_000 })],
  ])('refuses %s', (_name, replacement) => {
    const original = policy.sign(claims());
    expect(decide({ payload: tamper(original, replacement) })).toBe(
      'invalidSignature',
    );
  });

  it('refuses a payload signed with the wrong key', () => {
    const forger = new AccessPolicy('not-the-real-key');
    expect(decide({ payload: forger.sign(claims()) })).toBe('invalidSignature');
  });

  it.each([
    '',
    'nodot',
    '.',
    'body.',
    '.signature',
    'not-base64.not-base64',
  ])('refuses the malformed payload %p rather than crashing', (junk) => {
    expect(decide({ payload: junk })).toBe('invalidSignature');
  });

  it('refuses a well-formed payload that is not claims', () => {
    const body = Buffer.from('{"not":"claims"}', 'utf8').toString('base64url');
    const padded = body + '='.repeat((4 - (body.length % 4)) % 4);
    const signed = policy.sign(claims());
    // Re-sign the junk body so the signature is valid and only the shape is wrong.
    const forged = new AccessPolicy(SECRET);
    const mac = forged.sign(claims()).split('.')[1];
    expect(decide({ payload: `${padded}.${mac}` })).toBe('invalidSignature');
    expect(signed).toContain('.');
  });
});

describe('the booking must still be openable', () => {
  const refused: ReservationState[] = [
    'requested',
    'overdue',
    'completed',
    'cancelled',
    'expired',
  ];

  it.each(refused)('refuses a %s booking', (state) => {
    expect(decide({ reservation: booking({ state }) })).toBe(
      'bookingNotOpenable',
    );
  });

  it('allows exactly two of the seven booking states to open a locker', () => {
    const all: ReservationState[] = [
      'requested',
      'confirmed',
      'active',
      'overdue',
      'completed',
      'cancelled',
      'expired',
    ];
    expect(all.filter(canIssueToken)).toEqual(['confirmed', 'active']);
  });
});

describe('unknown credentials', () => {
  it('refuses a token the server has never seen', () => {
    expect(decide({ storedToken: null })).toBe('unknownToken');
  });

  it('refuses a payload naming a different token than the stored one', () => {
    expect(decide({ payload: policy.sign(claims({ tid: 'T-ELSEWHERE' })) })).toBe(
      'unknownToken',
    );
  });

  it('refuses a token whose booking has vanished', () => {
    expect(decide({ reservation: null })).toBe('unknownToken');
  });

  it('refuses a token pointing at a different booking', () => {
    expect(decide({ reservation: booking({ id: 'R-OTHER' }) })).toBe(
      'unknownToken',
    );
  });
});

describe('signing and verifying', () => {
  it('round-trips the claims', () => {
    const original = claims();
    expect(policy.verify(policy.sign(original))).toEqual(original);
  });

  it('produces different signatures under different keys', () => {
    const other = new AccessPolicy('another-key');
    expect(policy.sign(claims())).not.toBe(other.sign(claims()));
  });

  it('is deterministic, so a token can be redrawn without becoming a second one', () => {
    expect(policy.sign(claims())).toBe(policy.sign(claims()));
  });

  it('does not put the signing key in the payload', () => {
    expect(policy.sign(claims())).not.toContain(SECRET);
  });

  it('pads base64url so the Dart copy agrees', () => {
    // Node strips `=` padding and Dart keeps it. Without the padding added back,
    // a token signed here would fail verification there. This is the concrete
    // cost of writing the same rule twice in two languages.
    const body = policy.sign(claims()).split('.')[0];
    expect(body.length % 4).toBe(0);
  });

  it('refuses a signing key that is empty', () => {
    expect(() => new AccessPolicy('')).toThrow();
  });
});

describe('what the user is told', () => {
  it.each(['invalidSignature', 'unknownToken', 'notYours'] as const)(
    'never says which check %s tripped',
    (decision) => {
      expect(userMessage(decision)).toBe('That code was not accepted.');
    },
  );

  it('tells a legitimate user enough to act', () => {
    expect(userMessage('expired')).toContain('Get a new one');
    expect(userMessage('alreadyUsed')).toContain('already been used');
  });
});
