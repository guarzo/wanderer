import { SignatureGroup, SignatureKind, SystemSignature } from '@/hooks/Mapper/types/signatures';
import { computeSignatureAge, formatSignatureAge, getSignatureAgeColor, SIGNATURE_AGE_COLORS } from './signatureAge';

const HOUR = 1000 * 60 * 60;
const NOW = Date.parse('2026-08-09T12:00:00Z');

const sig = (overrides: Partial<SystemSignature> = {}): SystemSignature => ({
  eve_id: 'ABC-123',
  kind: SignatureKind.CosmicSignature,
  name: '',
  group: SignatureGroup.CosmicSignature,
  type: '',
  ...overrides,
});

const hoursAgo = (h: number) => new Date(NOW - h * HOUR).toISOString();

describe('computeSignatureAge', () => {
  it('reports no age when the system has no signatures at all', () => {
    expect(computeSignatureAge([], NOW).signatureAgeHours).toBe(-1);
    expect(computeSignatureAge(null, NOW).signatureAgeHours).toBe(-1);
  });

  // The reported bug: signatures pasted straight from the probe scanner have no
  // resolved group, and were filtered out entirely, so a freshly scanned system
  // showed no age until at least one signature resolved to a wormhole.
  it('counts unscanned signatures whose group is still Cosmic Signature', () => {
    const sigs = [sig({ group: SignatureGroup.CosmicSignature, updated_at: hoursAgo(2) })];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(2);
  });

  it('counts non-wormhole site signatures', () => {
    const sigs = [sig({ group: SignatureGroup.CombatSite, name: 'Perimeter Ambush Point', updated_at: hoursAgo(5) })];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(5);
  });

  it('counts wormhole signatures already linked to a mapped system', () => {
    const sigs = [
      sig({
        group: SignatureGroup.Wormhole,
        updated_at: hoursAgo(3),
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        linked_system: { solar_system_id: 31000001 } as any,
      }),
    ];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(3);
  });

  it('uses the newest timestamp across all signatures', () => {
    const sigs = [
      sig({ eve_id: 'AAA-111', updated_at: hoursAgo(9) }),
      sig({ eve_id: 'BBB-222', updated_at: hoursAgo(1) }),
      sig({ eve_id: 'CCC-333', updated_at: hoursAgo(6) }),
    ];

    const { signatureAgeHours, newestUpdatedAt } = computeSignatureAge(sigs, NOW);

    expect(signatureAgeHours).toBe(1);
    expect(newestUpdatedAt).toBe(NOW - HOUR);
  });

  it('falls back to inserted_at when a signature has never been updated', () => {
    const sigs = [sig({ inserted_at: hoursAgo(7) })];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(7);
  });

  // An unparseable updated_at yields NaN, and `NaN > max` is false, so the
  // signature used to collapse to 0 and take its perfectly good inserted_at
  // down with it.
  it('falls back to inserted_at when updated_at will not parse', () => {
    const sigs = [sig({ updated_at: 'not-a-date', inserted_at: hoursAgo(7) })];

    const { signatureAgeHours, newestUpdatedAt } = computeSignatureAge(sigs, NOW);

    expect(signatureAgeHours).toBe(7);
    expect(newestUpdatedAt).toBe(NOW - 7 * HOUR);
  });

  it('still reads an ISO-8601 timestamp with an explicit zone', () => {
    const sigs = [sig({ updated_at: hoursAgo(6) })];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(6);
  });

  it('reports no age when neither timestamp will parse', () => {
    const sigs = [sig({ updated_at: 'not-a-date', inserted_at: 'also-not-a-date' })];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(-1);
  });

  it('ignores a signature with unparseable timestamps without losing its neighbours', () => {
    const sigs = [
      sig({ eve_id: 'AAA-111', updated_at: 'not-a-date' }),
      sig({ eve_id: 'BBB-222', updated_at: hoursAgo(2) }),
    ];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(2);
  });

  it('reports no age when signatures exist but carry no usable timestamp', () => {
    expect(computeSignatureAge([sig()], NOW).signatureAgeHours).toBe(-1);
  });

  it('never reports a negative age for a clock skewed into the future', () => {
    const sigs = [sig({ updated_at: new Date(NOW + 2 * HOUR).toISOString() })];

    expect(computeSignatureAge(sigs, NOW).signatureAgeHours).toBe(0);
  });

  // The 12h cliff used to reuse -1 to mean "too old to display", which made a
  // stale system indistinguishable from one that was never scanned.
  it('keeps reporting an age well past twelve hours', () => {
    const { signatureAgeHours, bookmarkColor } = computeSignatureAge([sig({ updated_at: hoursAgo(72) })], NOW);

    expect(signatureAgeHours).toBe(72);
    expect(bookmarkColor).toBe(SIGNATURE_AGE_COLORS.ancient);
  });
});

describe('getSignatureAgeColor', () => {
  it.each([
    [0, SIGNATURE_AGE_COLORS.fresh],
    [3, SIGNATURE_AGE_COLORS.fresh],
    [4, SIGNATURE_AGE_COLORS.aging],
    [8, SIGNATURE_AGE_COLORS.aging],
    [9, SIGNATURE_AGE_COLORS.stale],
    [12, SIGNATURE_AGE_COLORS.stale],
    [13, SIGNATURE_AGE_COLORS.ancient],
    [500, SIGNATURE_AGE_COLORS.ancient],
  ])('maps %ih to the expected colour', (hours, expected) => {
    expect(getSignatureAgeColor(hours)).toBe(expected);
  });
});

describe('formatSignatureAge', () => {
  it('shows hours below a day', () => {
    expect(formatSignatureAge(0)).toBe('0h');
    expect(formatSignatureAge(23)).toBe('23h');
  });

  it('switches to whole days at twenty-four hours so the bookmark stays narrow', () => {
    expect(formatSignatureAge(24)).toBe('1d');
    expect(formatSignatureAge(47)).toBe('1d');
    expect(formatSignatureAge(72)).toBe('3d');
  });
});
