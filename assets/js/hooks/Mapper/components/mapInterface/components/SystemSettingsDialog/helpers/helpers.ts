// customSystemSettingsHelpers.ts

export const VALID_FLAG_CODES = new Set([
  'B',   // Blobber
  'MB',  // Marauder Blobber
  'C',   // Check Notes
  'F',   // Farm
  'PW',  // Prewarp Sites
  'PT',  // POS Trash
  'DNP', // Do Not Pod
]);

export function parseTagString(str: string): string[] {
  if (!str) return [];
  return str
    .trim()
    .split(/\s+/)
    .map(item => item.replace(/^\*/, ''))
    .filter(code => code && VALID_FLAG_CODES.has(code));
}

export function toTagString(arr: string[]): string {
  return arr.map(code => `*${code}`).join(' ');
}
