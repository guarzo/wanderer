import { useMemo } from 'react';


// useNodeNaming.ts
export function useZooNames(nodeVars: any) {
  return useMemo(() => {
  // 1. Booleans for clarity
  const hasTempName = Boolean(nodeVars.temporaryName);
  const isWormhole = Boolean(nodeVars.isWormhole);

  // 2. Primary names
  // systemName: if temporary name is present, use it; otherwise, fall back to solarSystemName
  const systemName = hasTempName
    ? nodeVars.temporaryName
    : nodeVars.solarSystemName;

  // 3. Labels for custom display
  // hsCustomLabel: if temp name is present, use regionName; otherwise, use labelCustom
  const hsCustomLabel = hasTempName
    ? nodeVars.regionName
    : nodeVars.labelCustom;

  // whCustomLabel: if solarSystemName is available, use that; otherwise, labelCustom
  const whCustomLabel = nodeVars.solarSystemName || nodeVars.labelCustom;

  // Final label depends on wormhole or not
  const customLabel = isWormhole
    ? whCustomLabel
    : hsCustomLabel;

  // 4. Custom naming for wormhole vs. non-wormhole
  // whCustomName: if systemName is not the solarSystemName, use nodeVars.name; otherwise, empty
  const whCustomName = (systemName !== nodeVars.solarSystemName)
    ? nodeVars.name
    : '';

  // hsSuffix: if nodeVars.name != solarSystemName, we suffix with nodeVars.name
  const needsHsSuffix = (nodeVars.name !== nodeVars.solarSystemName);
  const hsSuffix = needsHsSuffix
    ? nodeVars.name
    : '';

  // hsCustomName: if temp name is present, use "solarSystemName + suffix"; else "regionName + suffix"
  const hsCustomName = hasTempName
    ? `${nodeVars.solarSystemName} ${hsSuffix}`
    : `${nodeVars.regionName} ${hsSuffix}`;

  // customName: final name displayed to user
  const customName = isWormhole
    ? whCustomName
    : hsCustomName;

  // Return whichever pieces of data your component needs
  return { systemName, customLabel, customName};
  }, [nodeVars]);
}
