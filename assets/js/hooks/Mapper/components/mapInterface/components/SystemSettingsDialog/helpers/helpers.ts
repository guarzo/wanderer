// customSystemSettingsHelpers.ts

export function parseTagString(str: string): string[] {
  if (!str) return [];
  return str
    .trim()
    .split(/\s+/)
    .map(item => item.replace(/^\*/, ''))
    .filter(Boolean);
}

export function toTagString(arr: string[]): string {
  return arr.map(code => `*${code}`).join(' ');
}
