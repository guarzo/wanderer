import { StructureStatus, StructureItem, STRUCTURE_TYPE_MAP } from './types';

export const statusesRequiringTimer: StructureStatus[] = ['Anchoring', 'Reinforced'];

export function parseFormatOneLine(line: string): StructureItem | null {
  const columns = line
    .split('\t')
    .map(c => c.trim())
    .filter(Boolean);

  if (columns.length < 4) {
    return null;
  }

  const [typeId, rawName, typeName] = columns;

  if (!STRUCTURE_TYPE_MAP[typeId]) {
    return null;
  }

  const name = rawName.replace(/^J\d{6}\s*-\s*/, '').trim();

  return {
    id: crypto.randomUUID(),
    typeId,
    type: typeName,
    name,
    notes: '',
    owner: '',
    status: 'Powered',
  };
}

export function matchesThreeLineSnippet(lines: string[]): boolean {
  if (lines.length < 3) return false;
  return /until\s+\d{4}\.\d{2}\.\d{2}/i.test(lines[2]);
}

export function parseThreeLineSnippet(lines: string[]): StructureItem {
  const [line1, line2, line3] = lines;

  let status: StructureStatus = 'Reinforced';
  let endTime: string | undefined;

  const match = line3.match(/^(?<stat>\w+)\s+until\s+(?<dateTime>[\d.]+\s+[\d:]+)/i);
  console.log('[parseThreeLineSnippet] match =>', match);

  if (match?.groups?.stat) {
    const st = match.groups.stat as StructureStatus;
    if (statusesRequiringTimer.includes(st)) {
      status = st;
    }
  }
  if (match?.groups?.dateTime) {
    // e.g. "2025.01.13 18:51" => after your replace => "2025-01-13 18:51"
    let dt = match.groups.dateTime.trim().replace(/\./g, '-'); // => "2025-01-13 18:51"

    // If dt has no seconds, we add ":00"
    // e.g. "2025-01-13T18:51" => "2025-01-13T18:51:00"
    // or "2025-01-13 18:51" => "2025-01-13 18:51:00"
    if (!dt.match(/:\d{2}:/)) {
      // means we have only HH:MM, so add :00
      dt = dt.replace(/(\d{2})$/, '$1:00');
      // e.g. "2025-01-13 18:51" => "2025-01-13 18:51:00"
    }

    // Now convert space to "T" if present
    // "2025-01-13 18:51:00" => "2025-01-13T18:51:00"
    dt = dt.replace(' ', 'T');

    // Finally add a 'Z' (UTC)
    // => "2025-01-13T18:51:00Z"
    const iso = dt + 'Z';
    endTime = iso;
    console.log('[parseThreeLineSnippet] endTime =>', endTime);
  }

  const snippetItem = {
    id: crypto.randomUUID(),
    typeId: '',
    type: 'Unknown',
    name: line1.replace(/^J\d{6}\s*-\s*/, '').trim(),
    owner: '',
    notes: line2,
    status,
    endTime,
  };

  console.log('[parseThreeLineSnippet] final snippetItem =>', snippetItem);

  return snippetItem;
}
