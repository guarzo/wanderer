import { SystemSignature, SignatureKind, SignatureGroup } from '@/hooks/Mapper/types';
import { MAPPING_TYPE_TO_ENG, GROUPS_LIST } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { getState } from './getState.ts';


export function parseWormholeLine(
  value: string
): { wormholeSignature: string; description: string; name: string; isEOL: boolean } {
  let wormholeSignature = "";
  let description = "";
  let name = "";
  let isEOL = false;

  let match = value.match(/^(\d+)-([A-Za-z]{3})(?:\s+(\d+))?(?:\s*([Ee]))?$/);
  if (match) {
    wormholeSignature = match[2];       // e.g. "ERU"
    description = match[3] || "";         // e.g. "2"
    name = match[2];                      // default name equals the signature
    isEOL = !!(match[4] && /E/i.test(match[4]));
    return { wormholeSignature, description, name, isEOL };
  }
  // Try letter-based regex.
  match = value.match(/^([A-Za-z0-9]+)-([A-Za-z]{3})\s+((?:NS)|(?:[A-Za-z]{1,2}))\s*([Ee])?$/);
  if (match) {
    name = match[1].trim();
    wormholeSignature = match[2];
    description = match[3] || "";
    isEOL = !!(match[4] && /E/i.test(match[4]));
    return { wormholeSignature, description, name, isEOL };
  }

  return { wormholeSignature: "", description: "", name: "", isEOL: false };
}

/**
 * Parses a single line representing a system signature in bookmark format
 */
export function parseSignatureLine(line: string): SystemSignature | null {
  if (!line) return null;
  const trimmedLine = line.trim();
  if (!trimmedLine) return null;
  // Ignore lines starting with "xx" or "zz"
  const lower = trimmedLine.toLowerCase();
  if (lower.startsWith("xx") || lower.startsWith("zz")) return null;

  const parts = trimmedLine.split('\t');
  if (parts.length < 3) return null;
  const [rawValue, tokenType, timestampToken] = parts;
  if (tokenType.includes("LTURN")) return null;

  let group: SignatureGroup = SignatureGroup.Wormhole;
  let signature: SystemSignature;

  if (rawValue.startsWith("z")) {
    // Process "z" lines.
    const zMatch = rawValue.match(/^z\s*([A-Za-z])\s+(.*)$/);
    if (!zMatch) return null;
    const siteTypeLetter = zMatch[1].toUpperCase();
    const remainder = zMatch[2];
    switch (siteTypeLetter) {
      case 'R': group = SignatureGroup.RelicSite; break;
      case 'D': group = SignatureGroup.DataSite; break;
      case 'G': group = SignatureGroup.GasSite; break;
      default: group = SignatureGroup.CosmicSignature; break;
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
        type: ""
      };
      signature.custom_info = JSON.stringify({ dest: fullId, full_id: fullId });
    } else {
      // Otherwise, process remainder as a wormhole token.
      const wormholeData = parseWormholeLine(remainder);
      if (!wormholeData.wormholeSignature) return null; // Skip if no valid ID.
      const id = wormholeData.wormholeSignature;
      signature = {
        eve_id: id,
        kind: SignatureKind.CosmicSignature,
        name: wormholeData.name || id,
        group: group,
        type: ""
      };
      signature.description = wormholeData.description;
      signature.custom_info = JSON.stringify({
        dest: id,
        isEOL: wormholeData.isEOL,
        full_id: (id.indexOf('-') !== -1 && id.length === 7) ? id : null
      });
    }
  } else {
    // Process non-"z" lines as wormhole tokens.
    const wormholeData = parseWormholeLine(rawValue);
    if (!wormholeData.wormholeSignature) return null; // Skip if lacking id
    const id = wormholeData.wormholeSignature;
    signature = {
      eve_id: id,
      kind: SignatureKind.CosmicSignature,
      name: wormholeData.name || id,
      group: SignatureGroup.Wormhole,
      type: ""
    };
    signature.description = wormholeData.description;
    signature.custom_info = JSON.stringify({
      dest: id,
      isEOL: wormholeData.isEOL,
      full_id: (id.indexOf('-') !== -1 && id.length === 7) ? id : null
    });
  }

  if (timestampToken !== '-' && timestampToken.trim() !== '') {
    const isoTimestamp = timestampToken.trim().replace(/\./g, '-').replace(' ', 'T') + ":00";
    signature.inserted_at = isoTimestamp;
  }
  return signature;
}

/**
 * Group candidates by the first three characters of their `eve_id` and
 * then merges fields from multiple entries, preferring a probe scanner candidate if available.
 */
export function mergeSignatures(
  existing: SystemSignature[],
  incoming: SystemSignature[]
): SystemSignature[] {
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
      if (cand.group && cand.group.trim() !== "") {
        base.group = cand.group;
      }
      if (cand.name && cand.name.trim() !== "") {
        base.name = cand.name;
      }
      if (cand.description && cand.description.trim() !== "") {
        base.description = cand.description;
      }
      try {
        const baseInfo = JSON.parse(base.custom_info || "{}");
        const candInfo = JSON.parse(cand.custom_info || "{}");
        for (const key in candInfo) {
          if (candInfo[key] !== undefined && candInfo[key] !== null) {
            baseInfo[key] = candInfo[key];
          }
        }
        base.custom_info = JSON.stringify(baseInfo);
      } catch (e) {
        // Ignore JSON parsing errors.
      }
    }
    mergedWormholes.push(base);
  }

  const merged = nonWormholes.concat(mergedWormholes);

  // Final filtering: for any wormhole record with a bookmark (3-character) eve_id,
  // if there exists a matching record with a probe scanner id ID (7 characters containing a dash),
  // then drop the bookmark.
  const final = merged.filter(sig => {
    if (
      sig.kind === SignatureKind.CosmicSignature &&
      sig.group === SignatureGroup.Wormhole &&
      sig.eve_id.length === 3
    ) {
      const prefix = sig.eve_id.substring(0, 3).toUpperCase();
      return !merged.some(other =>
        other !== sig &&
        other.kind === SignatureKind.CosmicSignature &&
        other.group === SignatureGroup.Wormhole &&
        other.eve_id.substring(0, 3).toUpperCase() === prefix &&
        other.eve_id.length === 7 &&
        other.eve_id.indexOf('-') !== -1
      );
    }
    return true;
  });

  // Ensure every signature has a valid custom_info with at least the "dest" property.
  for (const sig of final) {
    try {
      const info = JSON.parse(sig.custom_info || "{}");
      if (typeof info !== "object" || info === null || !("dest" in info)) {
        sig.custom_info = JSON.stringify({ dest: sig.eve_id, full_id: sig.eve_id });
      }
    } catch (e) {
      sig.custom_info = JSON.stringify({ dest: sig.eve_id, full_id: sig.eve_id });
    }
  }

  return final;
}

/**
 * Parses multiple lines of system signature data.
 * Supports both the bookmark (3-token) format and the prob scanner (6-token) format.
 * Optionally, an existing signatures array can be provided to merge with new data.
 */
export function parseSignatures(
  value: string,
  availableKeys?: string[],
  existingSignatures?: SystemSignature[]
): SystemSignature[] {
  const newArr: SystemSignature[] = [];
  const rows = value.split('\n');
  for (const row of rows) {
    if (!row.trim()) continue;
    const tokens = row.split('\t');
    if (tokens.length === 6) {
      // probe scanner.
      const [eve_id, kindToken, groupToken, nameToken] = tokens;
      const mappedKind = MAPPING_TYPE_TO_ENG[kindToken as SystemSignature["kind"]];
      const kind = availableKeys && availableKeys.includes(mappedKind)
        ? mappedKind
        : SignatureKind.CosmicSignature;
      newArr.push({
        eve_id: eve_id,
        kind: kind,
        group: groupToken as SignatureGroup,
        name: nameToken,
        type: '',
        custom_info: JSON.stringify({ dest: eve_id, full_id: eve_id })
      });
    } else if (tokens.length === 3) {
      // bookmark format.
      const parsed = parseSignatureLine(row);
      if (parsed) newArr.push(parsed);
    }
  }
  // console.debug("Newly parsed signatures:", newArr);
  // const combined = existingSignatures ? existingSignatures.concat(newArr) : newArr;
  // console.debug("Combined signatures (existing + new):", combined);
  const merged = mergeSignatures(existingSignatures || [], newArr);
  // console.debug("Final merged signatures:", merged);
  return merged;
}



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

    // For wormhole entries, if the old signature is a bookmark (3-character) record,
    // check if a new signature exists that is a full probe scanner record (7 characters with a dash)
    // and matches on the prefix.
    if (
      oldSig.kind === SignatureKind.CosmicSignature &&
      oldSig.group === SignatureGroup.Wormhole &&
      oldSig.eve_id.length === 3
    ) {
      newSig = newSignatures.find(s =>
        s.kind === SignatureKind.CosmicSignature &&
        s.group === SignatureGroup.Wormhole &&
        s.eve_id.substring(0, 3).toUpperCase() === oldSig.eve_id.toUpperCase() &&
        s.eve_id.length === 7 &&
        s.eve_id.indexOf('-') !== -1
      );
      // If such a probe scanner exists, mark the bookmark record as removed and do not try to update it.
      if (newSig) {
        removed.push(oldSig);
        return; // skip further processing for this oldSig.
      }
    } else {
      // For non-wormhole entries (or wormhole entries that already have a full ID),
      // use an exact match.
      newSig = newSignatures.find(s => s.eve_id === oldSig.eve_id);
    }

    if (newSig) {
      const isNeedUpgrade = getState(GROUPS_LIST, newSig) > getState(GROUPS_LIST, oldSig);
      if (isNeedUpgrade) {
        updated.push({ ...oldSig, group: newSig.group, name: newSig.name });
      } else if (!skipUpdateUntouched) {
        updated.push({ ...oldSig });
      }
    } else {
      if (!updateOnly) {
        removed.push(oldSig);
      }
    }
  });

  const oldSignaturesIds = oldSignatures.map(x => x.eve_id);
  const added = newSignatures.filter(s => !oldSignaturesIds.includes(s.eve_id));

  return { added, updated, removed };
};
