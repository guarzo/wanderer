import { SystemSignature, SignatureKind, SignatureGroup } from '@/hooks/Mapper/types';
import { MAPPING_TYPE_TO_ENG } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';

/**
 * Parses a wormhole line.
 */
export function parseWormholeLine(value: string): {
  wormholeSignature: string;
  description: string;
  name: string;
  isEOL: boolean;
  isCrit: boolean;
} {
  let wormholeSignature = '';
  let description = '';
  let name = '';
  let isEOL = false;
  let isCrit = false;

  // First regex.
  let match = value.match(/^(\d+)-([A-Za-z]{3})(?:\s+(\d+))?(?:\s*([EeCc]{1,2}))?$/);
  if (match) {
    wormholeSignature = match[2];
    description = match[3] || '';
    name = match[2];
    const trailing = match[4] || '';
    isEOL = /E/i.test(trailing);
    isCrit = /C/i.test(trailing);
    console.debug(
      `parseWormholeLine (regex1): value="${value}" | wormholeSignature="${wormholeSignature}", description="${description}", trailing="${trailing}" => isEOL:${isEOL}, isCrit:${isCrit}`,
    );
    return { wormholeSignature, description, name, isEOL, isCrit };
  }

  // Second regex.
  match = value.match(/^([A-Za-z0-9]+)-([A-Za-z]{3})\s+((?:NS)|(?:[A-Za-z]{1,2}))\s*([EeCc]{1,2})?$/);
  if (match) {
    name = match[1].trim();
    wormholeSignature = match[2];
    description = match[3] || '';
    const trailing = match[4] || '';
    isEOL = /E/i.test(trailing);
    isCrit = /C/i.test(trailing);
    console.debug(
      `parseWormholeLine (regex2): value="${value}" | name="${name}", wormholeSignature="${wormholeSignature}", description="${description}", trailing="${trailing}" => isEOL:${isEOL}, isCrit:${isCrit}`,
    );
    return { wormholeSignature, description, name, isEOL, isCrit };
  }

  console.debug(`parseWormholeLine: Unable to parse value "${value}"`);
  return { wormholeSignature: '', description: '', name: '', isEOL: false, isCrit: false };
}

/**
 * Parses a single line representing a system signature in bookmark format.
 */
export function parseSignatureLine(line: string): SystemSignature | null {
  if (!line) {
    console.debug('parseSignatureLine: Empty line');
    return null;
  }
  const trimmedLine = line.trim();
  if (!trimmedLine) {
    console.debug('parseSignatureLine: Line is blank after trimming');
    return null;
  }
  const lower = trimmedLine.toLowerCase();
  if (lower.startsWith('xx') || lower.startsWith('zz')) {
    console.debug(`parseSignatureLine: Ignored line starting with xx/zz: "${trimmedLine}"`);
    return null;
  }
  const parts = trimmedLine.split('\t');
  if (parts.length < 3) {
    console.debug(`parseSignatureLine: Insufficient tokens in line: "${trimmedLine}"`);
    return null;
  }
  const [rawValue, tokenType, timestampToken] = parts;
  if (tokenType.includes('LTURN')) {
    console.debug(`parseSignatureLine: Ignored line due to LTURN token: "${trimmedLine}"`);
    return null;
  }

  let group: SignatureGroup = SignatureGroup.Wormhole;
  let signature: SystemSignature;

  if (rawValue.startsWith('z')) {
    const zMatch = rawValue.match(/^z\s*([A-Za-z])\s+(.*)$/);
    if (!zMatch) {
      console.debug(`parseSignatureLine: "z" line did not match expected pattern: "${rawValue}"`);
      return null;
    }
    const siteTypeLetter = zMatch[1].toUpperCase();
    const remainder = zMatch[2];
    switch (siteTypeLetter) {
      case 'R':
        group = SignatureGroup.RelicSite;
        break;
      case 'D':
        group = SignatureGroup.DataSite;
        break;
      case 'G':
        group = SignatureGroup.GasSite;
        break;
      default:
        group = SignatureGroup.CosmicSignature;
        break;
    }
    const siteMatch = remainder.match(/^([A-Za-z]+-\d+)\s+(.+)$/);
    if (siteMatch) {
      const fullId = siteMatch[1];
      const siteName = siteMatch[2].trim();
      signature = {
        eve_id: fullId,
        kind: SignatureKind.CosmicSignature,
        name: siteName,
        group: group,
        type: '',
      };
      signature.custom_info = JSON.stringify({ dest: fullId, full_id: fullId });
      console.debug(`parseSignatureLine ("z" legacy): fullId="${fullId}", siteName="${siteName}"`);
    } else {
      const wormholeData = parseWormholeLine(remainder);
      if (!wormholeData.wormholeSignature) {
        console.debug(`parseSignatureLine ("z" wormhole): Failed to parse wormhole data from remainder "${remainder}"`);
        return null;
      }
      const id = wormholeData.wormholeSignature;
      signature = {
        eve_id: id,
        kind: SignatureKind.CosmicSignature,
        name: wormholeData.name || id,
        group: group,
        type: '',
      };
      signature.description = wormholeData.description;
      signature.custom_info = JSON.stringify({
        dest: id,
        isEOL: wormholeData.isEOL,
        isCrit: wormholeData.isCrit,
        full_id: id.indexOf('-') !== -1 && id.length >= 7 ? id : null,
      });
      console.debug(
        `parseSignatureLine ("z" wormhole): id="${id}", description="${wormholeData.description}", isEOL:${wormholeData.isEOL}, isCrit:${wormholeData.isCrit}`,
      );
    }
  } else {
    const wormholeData = parseWormholeLine(rawValue);
    if (!wormholeData.wormholeSignature) {
      console.debug(`parseSignatureLine: Failed to parse wormhole token from rawValue "${rawValue}"`);
      return null;
    }
    const id = wormholeData.wormholeSignature;
    signature = {
      eve_id: id,
      kind: SignatureKind.CosmicSignature,
      name: wormholeData.name || id,
      group: SignatureGroup.Wormhole,
      type: '',
    };
    signature.description = wormholeData.description;
    signature.custom_info = JSON.stringify({
      dest: id,
      isEOL: wormholeData.isEOL,
      isCrit: wormholeData.isCrit,
      full_id: id.indexOf('-') !== -1 && id.length >= 7 ? id : null,
    });
    console.debug(
      `parseSignatureLine: Processed non-"z" line: id="${id}", description="${wormholeData.description}", isEOL:${wormholeData.isEOL}, isCrit:${wormholeData.isCrit}`,
    );
  }

  if (timestampToken !== '-' && timestampToken.trim() !== '') {
    const isoTimestamp = timestampToken.trim().replace(/\./g, '-').replace(' ', 'T') + ':00';
    signature.inserted_at = isoTimestamp;
    console.debug(`parseSignatureLine: Timestamp processed as "${isoTimestamp}"`);
  }
  return signature;
}

/**
 * Groups and merges signatures.
 */
export function mergeSignatures(existing: SystemSignature[], incoming: SystemSignature[]): SystemSignature[] {
  const combined = existing.concat(incoming);
  const nonWormholes: SystemSignature[] = [];
  const wormholeGroups = new Map<string, SystemSignature[]>();

  for (const sig of combined) {
    const id = sig.eve_id;
    if ((id.length === 3 || id.length >= 7) && /^[A-Z]{3}/.test(id.toUpperCase())) {
      const prefix = id.substring(0, 3).toUpperCase();
      if (!wormholeGroups.has(prefix)) {
        wormholeGroups.set(prefix, []);
      }
      wormholeGroups.get(prefix)!.push(sig);
    } else {
      nonWormholes.push(sig);
    }
  }

  const mergedWormholes: SystemSignature[] = [];
  for (const [, group] of wormholeGroups.entries()) {
    let full = group.find(s => /^[A-Za-z]{3}-[A-Za-z0-9]{3}$/.test(s.eve_id));
    if (!full) {
      full = { ...group[0] };
    } else {
      full = { ...full };
    }
    for (const cand of group) {
      if (cand.eve_id.length !== 7 && cand.eve_id.toUpperCase() === full.eve_id.substring(0, 3).toUpperCase()) {
        full.kind = cand.kind;
        full.name = cand.name;
        continue;
      }
      if (cand.group && cand.group.trim() !== '') {
        full.group = cand.group;
      }
      if (cand.name && cand.name.trim() !== '') {
        full.name = cand.name;
      }
      if (cand.description && cand.description.trim() !== '') {
        full.description = cand.description;
      }
      try {
        const fullInfo = JSON.parse(full.custom_info || '{}');
        const candInfo = JSON.parse(cand.custom_info || '{}');
        for (const key in candInfo) {
          if (candInfo[key] !== undefined && candInfo[key] !== null) {
            fullInfo[key] = candInfo[key];
          }
        }
        full.custom_info = JSON.stringify(fullInfo);
      } catch (e) {
        console.debug(`mergeSignatures: Error merging custom_info for ${cand.eve_id}`, e);
      }
    }
    mergedWormholes.push(full);
  }

  const merged = nonWormholes.concat(mergedWormholes);

  const final = merged.filter(sig => {
    if (
      sig.kind === SignatureKind.CosmicSignature &&
      sig.group === SignatureGroup.Wormhole &&
      sig.eve_id.length !== 7
    ) {
      const prefix = sig.eve_id.substring(0, 3).toUpperCase();
      return !merged.some(
        other =>
          other !== sig &&
          other.kind === SignatureKind.CosmicSignature &&
          other.group === SignatureGroup.Wormhole &&
          other.eve_id.substring(0, 3).toUpperCase() === prefix &&
          /^[A-Za-z]{3}-[A-Za-z0-9]{3}$/.test(other.eve_id),
      );
    }
    return true;
  });

  for (const sig of final) {
    try {
      const info = JSON.parse(sig.custom_info || '{}');
      if (typeof info !== 'object' || info === null || !('dest' in info)) {
        sig.custom_info = JSON.stringify({ dest: sig.eve_id, full_id: sig.eve_id });
      }
    } catch (e) {
      sig.custom_info = JSON.stringify({ dest: sig.eve_id, full_id: sig.eve_id });
      console.debug(`mergeSignatures: JSON parse error for signature ${sig.eve_id}`, e);
    }
  }

  return final;
}

/**
 * Parses multiple lines of system signature data.
 * For probe scanner format, if the first token matches the pattern and the final token ends with "AU", use that.
 * Otherwise, assume bookmark format.
 */
export function parseSignatures(
  value: string,
  availableKeys?: string[],
  existingSignatures?: SystemSignature[],
): SystemSignature[] {
  const newArr: SystemSignature[] = [];
  const rows = value.split('\n');
  for (const row of rows) {
    if (!row.trim()) continue;
    const tokens = row.split('\t').map(t => t.trim());
    // Check if the first token matches the probe scanner pattern and the final token ends with "AU/K/M"
    if (/^[A-Za-z]{3}-[A-Za-z0-9]{3}$/.test(tokens[0]) && /(?:AU|K|M)$/i.test(tokens[tokens.length - 1])) {
      // Probe scanner format.
      const [eve_id, kindToken, groupToken, nameToken] = tokens;
      const mappedKind = MAPPING_TYPE_TO_ENG[kindToken as SystemSignature['kind']];
      const kind = availableKeys && availableKeys.includes(mappedKind) ? mappedKind : SignatureKind.CosmicSignature;
      newArr.push({
        eve_id: eve_id,
        kind: kind,
        group: groupToken ? (groupToken as SignatureGroup) : SignatureGroup.CosmicSignature,
        name: nameToken || eve_id,
        type: '',
        custom_info: JSON.stringify({ dest: eve_id, full_id: eve_id }),
      });
      console.debug(`parseSignatures: Processed probe scanner line for eve_id="${eve_id}"`);
    } else {
      // Assume bookmark format. Use only the first three tokens.
      const relevantTokens = tokens.slice(0, 3);
      const newLine = relevantTokens.join('\t');
      const parsed = parseSignatureLine(newLine);
      if (parsed) {
        newArr.push(parsed);
        console.debug(`parseSignatures: Processed bookmark line for eve_id="${parsed.eve_id}"`);
      } else {
        console.debug(`parseSignatures: Failed to parse bookmark line: "${row}"`);
      }
    }
  }
  const merged = mergeSignatures(existingSignatures || [], newArr);
  console.debug(`parseSignatures: Merged signatures count: ${merged.length}`);
  return merged;
}

/**
 * Merges an existing bookmark signature with a new full id signature.
 */
function mergeBookmarkSignature(existing: SystemSignature, fullSig: SystemSignature): SystemSignature {
  const merged = { ...fullSig };
  if (existing.kind !== SignatureKind.CosmicSignature) {
    merged.kind = existing.kind;
  }
  if (existing.name && existing.name !== existing.eve_id) {
    merged.name = existing.name;
  }
  try {
    const existingInfo = JSON.parse(existing.custom_info || '{}');
    const fullInfo = JSON.parse(fullSig.custom_info || '{}');
    merged.custom_info = JSON.stringify({ ...fullInfo, ...existingInfo });
  } catch (e) {
    merged.custom_info = fullSig.custom_info;
  }
  return merged;
}

/**
 * Parses multiple lines of system signature data in bookmark format only.
 * Assumes each line is in bookmark format (tab-separated, first three tokens).
 * Merges entries among themselves (without taking existing signatures into account).
 */
export function parseBookmarkFormatSignatures(value: string): SystemSignature[] {
  const newArr: SystemSignature[] = [];
  const rows = value.split('\n');
  for (const row of rows) {
    if (!row.trim()) continue;
    const tokens = row.split('\t').map(t => t.trim());
    if (tokens.length < 3) continue;
    const newLine = tokens.slice(0, 3).join('\t');
    const parsed = parseSignatureLine(newLine);
    if (parsed) {
      newArr.push(parsed);
    }
  }
  // Merge among the bookmark entries.
  const mergedMap: { [id: string]: SystemSignature } = {};
  for (const sig of newArr) {
    // Use the full 7-character ID if available.
    if (sig.eve_id.length === 7) {
      const prefix = sig.eve_id.substring(0, 3);
      let merged = sig;
      // Look for an existing bookmark entry with a 3-character id that matches the prefix.
      for (const existingId in mergedMap) {
        if (existingId.length === 3 && existingId.toUpperCase() === prefix.toUpperCase()) {
          merged = mergeBookmarkSignature(mergedMap[existingId], sig);
          delete mergedMap[existingId];
          break;
        }
      }
      mergedMap[merged.eve_id] = merged;
    } else {
      // For entries that already have a 3-character id.
      if (!mergedMap[sig.eve_id]) {
        mergedMap[sig.eve_id] = sig;
      } else {
        mergedMap[sig.eve_id] = mergeBookmarkSignature(mergedMap[sig.eve_id], sig);
      }
    }
  }
  // Return only valid signature objects.
  return Object.values(mergedMap).filter(sig => sig && typeof sig === 'object' && sig.eve_id);
}
