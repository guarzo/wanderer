import { getRowBackgroundColor } from './getRowBackgroundColor';

const NOW = Date.parse('2026-08-09T12:00:00Z');
const SECOND = 1000;
const MINUTE = 60 * SECOND;

// The row highlight and `TimeLeft` both used to add `getTimezoneOffset()` to
// *now*, cancelling out the fact that signature timestamps arrived as zone-less
// UTC that `new Date` had read as local. Now that the server sends ISO-8601, the
// timestamps are real instants and the correction has to be gone: west of UTC it
// would push every age hours into the past and no row would ever highlight.
describe('getRowBackgroundColor', () => {
  it('highlights a signature added seconds ago', () => {
    expect(getRowBackgroundColor(new Date(NOW - 5 * SECOND), NOW)).toContain('amber-300');
  });

  it('uses the ten-minute colour for a signature a few minutes old', () => {
    expect(getRowBackgroundColor(new Date(NOW - 5 * MINUTE), NOW)).toContain('amber-500');
  });

  it('stops highlighting past ten minutes', () => {
    expect(getRowBackgroundColor(new Date(NOW - 11 * MINUTE), NOW)).toBe('');
  });

  it('returns nothing without a date', () => {
    expect(getRowBackgroundColor(undefined, NOW)).toBe('');
  });
});
