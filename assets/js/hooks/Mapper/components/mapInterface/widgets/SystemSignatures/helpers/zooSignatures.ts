/** zooSignatures.ts */

import { SystemSignature, SignatureKind, SignatureGroup } from '@/hooks/Mapper/types';
import {
  MAPPING_TYPE_TO_ENG,
  GROUPS_LIST,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { getState } from './getState.ts';

/**
 * Regex-based parser for a single wormhole line/string.
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
  // an optional number, and an optional trailing sequence of 1–2 letters from [EeCc].
  let match = value.match(/^(\d+)-([A-Za-z]{3})(?:\s+(\d+))?(?:\s*([EeCc]{1,2}))?$/);
  if (match) {
    wormholeSignature = match[2]; // e.g. "ERU"
    description = match[3] || ''; // e.g. "2"
    name = match[2]; // default name equals the signature
    const trailing = match[4] || '';
    isEOL = /E/i.test(trailing);
    isCrit = /C/i.test(trailing);
    console.debug(
      `parseWormholeLine (regex1): value="${value}" | wormholeSignature="${wormholeSignature}", description="${description}", trailing="${trailing}" => isEOL:${isEOL}, isCrit:${isCrit}`,
    );
    return { wormholeSignature, description, name, isEOL, isCrit };
  }

  // Second regex: matches a letter/number prefix, a hyphen, a 3-letter token,
  // a required token (e.g., "NS" or 1–2 letters), and optional trailing letters (E/e or C/c in any order).
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
 * Parses a single line representing a system signature in bookmark format
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
  // Ignore lines starting with "xx" or "zz"
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
    // Process "z" lines.
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
    // Check if remainder matches a legacy site pattern.
    const siteMatch = remainder.match(/^([A-Za-z]+-\d+)\s+(.+)$/);
    if (siteMatch) {
      const fullId = siteMatch[1]; // e.g. "IEB-620"
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
      // Otherwise, process remainder as a wormhole token.
      const wormholeData = parseWormholeLine(remainder);
      if (!wormholeData.wormholeSignature) {
        console.debug(`parseSignatureLine ("z" wormhole): Failed to parse wormhole data from remainder "${remainder}"`);
        return null; // Skip if no valid ID.
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
        full_id: id.indexOf('-') !== -1 && id.length === 7 ? id : null,
      });
      console.debug(
        `parseSignatureLine ("z" wormhole): id="${id}", description="${wormholeData.description}", isEOL:${wormholeData.isEOL}, isCrit:${wormholeData.isCrit}`,
      );
    }
  } else {
    // Process non-"z" lines as wormhole tokens.
    const wormholeData = parseWormholeLine(rawValue);
    if (!wormholeData.wormholeSignature) {
      console.debug(`parseSignatureLine: Failed to parse wormhole token from rawValue "${rawValue}"`);
      return null; // Skip if lacking id.
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
      full_id: id.indexOf('-') !== -1 && id.length === 7 ? id : null,
    });
    console.debug(
      `parseSignatureLine: Processed non-"z" line: id="${id}", description="${wormholeData.description}", isEOL:${wormholeData.isEOL}, isCrit:${wormholeData.isCrit}`,
    );
  }

  if (timestampToken !== '-' && timestampToken.trim() !== '') {
    // Convert e.g. "2023.05.10 10:39" to "2023-05-10T10:39:00"
    const isoTimestamp = timestampToken.trim().replace(/\./g, '-').replace(' ', 'T') + ':00';
    signature.inserted_at = isoTimestamp;
    console.debug(`parseSignatureLine: Timestamp processed as "${isoTimestamp}"`);
  }
  return signature;
}

/**
 * Group candidates by the first three characters of their `eve_id` and
 * then merges fields from multiple entries, preferring a probe scanner candidate if available.
 */
export function mergeSignatures(existing: SystemSignature[], incoming: SystemSignature[]): SystemSignature[] {
  const combined = existing.concat(incoming);
  const nonWormholes: SystemSignature[] = [];
  const wormholeGroups = new Map<string, SystemSignature[]>();

  for (const sig of combined) {
    const id = sig.eve_id;
    if ((id.length === 3 || id.length === 7) && /^[A-Z]{3}/.test(id.toUpperCase())) {
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
    // Prefer a probe scanner candidate: one with a '-' and length === 7.
    let base = group.find(s => s.eve_id.indexOf('-') !== -1 && s.eve_id.length === 7);
    if (!base) {
      base = { ...group[0] };
    } else {
      base = { ...base };
    }
    for (const cand of group) {
      if (cand === base) continue;
      // Merge other fields
      if (cand.group && cand.group.trim() !== '') {
        base.group = cand.group;
      }
      if (cand.name && cand.name.trim() !== '') {
        base.name = cand.name;
      }
      if (cand.description && cand.description.trim() !== '') {
        base.description = cand.description;
      }
      try {
        const baseInfo = JSON.parse(base.custom_info || '{}');
        const candInfo = JSON.parse(cand.custom_info || '{}');
        for (const key in candInfo) {
          if (candInfo[key] !== undefined && candInfo[key] !== null) {
            baseInfo[key] = candInfo[key];
          }
        }
        base.custom_info = JSON.stringify(baseInfo);
      } catch (e) {
        console.debug(`mergeSignatures: JSON parse error while merging signature ${cand.eve_id}`, e);
      }
    }
    mergedWormholes.push(base);
  }

  const merged = nonWormholes.concat(mergedWormholes);

  // Final filtering: for any wormhole record with a bookmark (3-character) eve_id,
  // if there exists a matching record with a probe scanner id (7 characters containing a dash),
  // then drop the bookmark.
  const final = merged.filter(sig => {
    if (
      sig.kind === SignatureKind.CosmicSignature &&
      sig.group === SignatureGroup.Wormhole &&
      sig.eve_id.length === 3
    ) {
      const prefix = sig.eve_id.substring(0, 3).toUpperCase();
      return !merged.some(
        other =>
          other !== sig &&
          other.kind === SignatureKind.CosmicSignature &&
          other.group === SignatureGroup.Wormhole &&
          other.eve_id.substring(0, 3).toUpperCase() === prefix &&
          other.eve_id.length === 7 &&
          other.eve_id.indexOf('-') !== -1,
      );
    }
    return true;
  });

  // Ensure every signature has a valid custom_info with at least the "dest" property.
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
 * Supports both the bookmark (3-token) format and the probe scanner (6-token) format.
 * Optionally, an existing signatures array can be provided to merge with new data.
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
    const tokens = row.split('\t');
    if (tokens.length === 6) {
      // probe scanner.
      const [eve_id, kindToken, groupToken, nameToken] = tokens;
      const mappedKind = MAPPING_TYPE_TO_ENG[kindToken as SystemSignature['kind']];
      const kind = availableKeys && availableKeys.includes(mappedKind) ? mappedKind : SignatureKind.CosmicSignature;
      newArr.push({
        eve_id: eve_id,
        kind: kind,
        group: groupToken as SignatureGroup,
        name: nameToken,
        type: '',
        custom_info: JSON.stringify({ dest: eve_id, full_id: eve_id }),
      });
      console.debug(`parseSignatures: Processed probe scanner line for eve_id="${eve_id}"`);
    } else if (tokens.length === 3) {
      // bookmark format.
      const parsed = parseSignatureLine(row);
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
 * An updated version of getActualSigs that merges not only group / name
 * but also custom_info, description, and any other relevant fields.
 */
export const getActualSigs = (
  oldSignatures: SystemSignature[],
  newSignatures: SystemSignature[],
  updateOnly: boolean,
  skipUpdateUntouched?: boolean,
): { added: SystemSignature[]; updated: SystemSignature[]; removed: SystemSignature[] } => {
  const updated: SystemSignature[] = [];
  const removed: SystemSignature[] = [];

  // For each old signature, try to find a matching new signature.
  oldSignatures.forEach(oldSig => {
    let newSig: SystemSignature | undefined;

    // For wormhole entries, if the old signature is a bookmark (3-character),
    // check if a new signature exists that is a full probe scanner record (7 chars with dash) matching on prefix.
    if (
      oldSig.kind === SignatureKind.CosmicSignature &&
      oldSig.group === SignatureGroup.Wormhole &&
      oldSig.eve_id.length === 3
    ) {
      newSig = newSignatures.find(
        s =>
          s.kind === SignatureKind.CosmicSignature &&
          s.group === SignatureGroup.Wormhole &&
          s.eve_id.substring(0, 3).toUpperCase() === oldSig.eve_id.toUpperCase() &&
          s.eve_id.length === 7 &&
          s.eve_id.indexOf('-') !== -1,
      );
      // If such a signature exists, mark the bookmark record as removed.
      if (newSig) {
        removed.push(oldSig);
        console.debug(
          `getActualSigs: Removing bookmark signature "${oldSig.eve_id}" in favor of probe scanner "${newSig.eve_id}"`,
        );
        return; // done with oldSig
      }
    } else {
      // For non-wormhole or wormhole full-IDs, do an exact match.
      newSig = newSignatures.find(s => s.eve_id === oldSig.eve_id);
    }

    if (newSig) {
      // Check if there's a 'group upgrade'
      const isNeedUpgrade = getState(GROUPS_LIST, newSig) > getState(GROUPS_LIST, oldSig);

      // Instead of only updating group + name, merge everything that might have changed.
      // Start with a clone of oldSig so we can track changes.
      const mergedSig = { ...oldSig };
      let changed = false;

      // If group is "upgraded", carry new group/name.
      if (isNeedUpgrade) {
        mergedSig.group = newSig.group;
        mergedSig.name = newSig.name;
        changed = true;
        console.debug(`getActualSigs: Upgrading signature "${oldSig.eve_id}" -> group: ${newSig.group}`);
      }

      // Merge `description` if changed
      if (newSig.description && newSig.description !== oldSig.description) {
        mergedSig.description = newSig.description;
        changed = true;
      }

      // Merge custom_info
      try {
        const oldInfo = JSON.parse(oldSig.custom_info || '{}');
        const newInfo = JSON.parse(newSig.custom_info || '{}');
        let infoChanged = false;
        for (const [key, val] of Object.entries(newInfo)) {
          if (oldInfo[key] !== val) {
            oldInfo[key] = val;
            infoChanged = true;
          }
        }
        if (infoChanged) {
          mergedSig.custom_info = JSON.stringify(oldInfo);
          changed = true;
        }
      } catch (err) {
        console.debug('getActualSigs: Error merging custom_info:', err);
      }

      // If we made changes, push to updated. Otherwise, re-push the oldSig if skipUpdateUntouched is false.
      if (changed) {
        updated.push(mergedSig);
      } else if (!skipUpdateUntouched) {
        updated.push({ ...oldSig });
      }
    } else {
      // If updateOnly is false, we remove old signatures not in newSignatures
      if (!updateOnly) {
        removed.push(oldSig);
        console.debug(`getActualSigs: Removing signature "${oldSig.eve_id}" (not found in new signatures)`);
      }
    }
  });

  // Everything in newSignatures that is truly new (no oldSig match)
  const oldSignaturesIds = oldSignatures.map(x => x.eve_id);
  const added = newSignatures.filter(s => !oldSignaturesIds.includes(s.eve_id));
  console.debug(`getActualSigs: Added signatures count: ${added.length}`);

  return { added, updated, removed };
};
