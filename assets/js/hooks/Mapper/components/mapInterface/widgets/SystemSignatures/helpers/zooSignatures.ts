import { SystemSignature, SignatureKind, SignatureGroup } from '@/hooks/Mapper/types';
import {
  MAPPING_TYPE_TO_ENG,
  GROUPS_LIST,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { getState } from './getState';

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

  // First regex: matches a numeric prefix, a hyphen, then a 3-letter token,
  // an optional number, and an optional trailing sequence of 1–2 letters.
  let match = value.match(/^(\d+)-([A-Za-z]{3})(?:\s+(\d+))?(?:\s*([EeCc]{1,2}))?$/);
  if (match) {
    wormholeSignature = match[2]; // e.g. "ERU"
    description = match[3] || '';
    name = match[2]; // default name equals the signature
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
 * For wormhole bookmarks, if there exists a full record (with a hyphen),
 * then the full record is preferred and the bookmark's signature kind and name are preserved.
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
    // Prefer a probe scanner candidate: one whose eve_id matches the pattern AAA-BBB.
    let full = group.find(s => /^[A-Za-z]{3}-[A-Za-z0-9]{3}$/.test(s.eve_id));
    if (!full) {
      full = { ...group[0] };
    } else {
      full = { ...full };
    }
    // For merging: if there are any bookmark entries (IDs not matching the probe pattern)
    // whose prefix matches the full record's prefix, then:
    // • We want to send a deletion for the bookmark record.
    // • And send an addition for the merged record, using the full record’s fields but preserving the bookmark’s kind and name.
    for (const cand of group) {
      if (cand.eve_id.length !== 7 && cand.eve_id.toUpperCase() === full.eve_id.substring(0, 3).toUpperCase()) {
        // Preserve bookmark's signature kind and name.
        full.kind = cand.kind;
        full.name = cand.name;
        // Mark this bookmark for deletion later.
        // (We won’t add it to the final merged output.)
        continue;
      }
      // Otherwise, merge other fields.
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

  // Final filtering: Remove any leftover bookmark entries (IDs not matching the probe pattern)
  // that have a matching full record.
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

  // Ensure valid custom_info.
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
 * If the first token matches the probe scanner pattern (AAA-BBB) and the final token ends with "AU" (case-insensitive),
 * the row is assumed to be in the probe scanner format.
 * Otherwise, the line is assumed to be in bookmark format.
 * For bookmark lines, we use only the first three tokens.
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
      // Token order: [full ID, kind, group, name, ...]
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
 * Computes differences between old and new signatures.
 * For wormhole bookmarks (IDs not matching the probe scanner pattern) that have a matching full record
 * (i.e. whose ID starts with the bookmark plus '-'),
 * this function creates a merged record that uses the full record’s ID and fields
 * (but preserves the bookmark’s signature kind and name),
 * and **sends an explicit deletion for the bookmark record**.
 */
export const getActualSigs = (
  oldSignatures: SystemSignature[],
  newSignatures: SystemSignature[],
  updateOnly: boolean,
  skipUpdateUntouched?: boolean,
): { added: SystemSignature[]; updated: SystemSignature[]; removed: SystemSignature[] } => {
  console.debug('getActualSigs: Starting merge process');
  console.debug('Old signatures:', oldSignatures);
  console.debug('New signatures:', newSignatures);

  const updated: SystemSignature[] = [];
  const removed: SystemSignature[] = [];
  const added: SystemSignature[] = [];
  const mergedNewIds = new Set<string>();

  oldSignatures.forEach(oldSig => {
    let newSig: SystemSignature | undefined;
    // For wormhole bookmarks (IDs not matching the probe scanner pattern, i.e. length !== 7).
    if (
      oldSig.kind === SignatureKind.CosmicSignature &&
      oldSig.group === SignatureGroup.Wormhole &&
      oldSig.eve_id.length !== 7
    ) {
      console.debug(`getActualSigs: Processing bookmark signature: ${oldSig.eve_id}`);
      newSig = newSignatures.find(
        s =>
          s.kind === SignatureKind.CosmicSignature &&
          s.group === SignatureGroup.Wormhole &&
          s.eve_id.toUpperCase().startsWith(oldSig.eve_id.toUpperCase() + '-'),
      );
      if (newSig) {
        console.debug(`getActualSigs: Found full record ${newSig.eve_id} matching bookmark ${oldSig.eve_id}`);
        // Create merged record: use newSig's fields but preserve the bookmark's signature kind and name.
        const mergedSig: SystemSignature = { ...newSig, kind: oldSig.kind, name: oldSig.name };
        console.debug('getActualSigs: Merged record (to be added):', mergedSig);
        // Instead of updating, we will add the merged record and remove the bookmark.
        added.push(mergedSig);
        removed.push(oldSig);
        mergedNewIds.add(newSig.eve_id);
        return;
      } else {
        console.debug(`getActualSigs: No full record found for bookmark ${oldSig.eve_id}`);
      }
    } else {
      newSig = newSignatures.find(s => s.eve_id === oldSig.eve_id);
    }
    if (newSig) {
      const needUpgrade = getState(GROUPS_LIST, newSig) > getState(GROUPS_LIST, oldSig);
      const mergedSig = { ...oldSig };
      let changed = false;
      if (needUpgrade) {
        mergedSig.group = newSig.group;
        mergedSig.name = newSig.name;
        changed = true;
        console.debug(`getActualSigs: Upgrading signature ${oldSig.eve_id} -> group: ${newSig.group}`);
      }
      if (newSig.description && newSig.description !== oldSig.description) {
        mergedSig.description = newSig.description;
        changed = true;
        console.debug(`getActualSigs: Updating description for ${oldSig.eve_id}`);
      }
      try {
        const oldInfo = JSON.parse(oldSig.custom_info || '{}');
        const newInfo = JSON.parse(newSig.custom_info || '{}');
        let infoChanged = false;
        for (const key in newInfo) {
          if (oldInfo[key] !== newInfo[key]) {
            oldInfo[key] = newInfo[key];
            infoChanged = true;
            console.debug(`getActualSigs: Updating custom_info field ${key} for ${oldSig.eve_id}`);
          }
        }
        if (infoChanged) {
          mergedSig.custom_info = JSON.stringify(oldInfo);
          changed = true;
        }
      } catch (e) {
        console.debug(`getActualSigs: Error merging custom_info for ${oldSig.eve_id}`, e);
      }
      if (changed) {
        updated.push(mergedSig);
      } else if (!skipUpdateUntouched) {
        updated.push({ ...oldSig });
      }
    } else {
      if (!updateOnly) {
        removed.push(oldSig);
        console.debug(`getActualSigs: Removing signature ${oldSig.eve_id} (not found in new signatures)`);
      }
    }
  });

  // Now, add any new signatures that do not match any old signature.
  const oldIds = new Set(oldSignatures.map(x => x.eve_id));
  newSignatures.forEach(s => {
    if (!oldIds.has(s.eve_id) && !mergedNewIds.has(s.eve_id)) {
      added.push(s);
    }
  });

  console.debug(`getActualSigs: Added signatures count: ${added.length}`);
  console.debug('getActualSigs: Final output:', { added, updated, removed });
  return { added, updated, removed };
};
