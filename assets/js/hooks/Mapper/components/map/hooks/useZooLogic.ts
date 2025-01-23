import { useMemo } from 'react';
import { SolarSystemNodeVars } from './useSolarSystemLogic';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';

export function useZooNames(nodeVars: SolarSystemNodeVars, props: NodeProps<MapSolarSystemType>) {
  const { data } = props;
  const { custom_flags } = data;

  return useMemo(() => {
    const hasTempName = Boolean(nodeVars.temporaryName);
    const isWormhole = Boolean(nodeVars.isWormhole);

    // systemName: if temporary name is present, use it; otherwise, fall back to solarSystemName
    const systemName = hasTempName ? nodeVars.temporaryName : nodeVars.solarSystemName;

    // hsCustomLabel: if temp name is present, use regionName; otherwise, use labelCustom
    const hsCustomLabel = hasTempName ? nodeVars.regionName : nodeVars.labelCustom;

    // whCustomLabel: if solarSystemName is available, use that; otherwise, labelCustom
    const whCustomLabel = nodeVars.solarSystemName || nodeVars.labelCustom;

    // Final label depends on wormhole or not
    const customLabel = isWormhole ? whCustomLabel : hsCustomLabel;

    // whCustomName: if systemName is not the solarSystemName, use nodeVars.name; otherwise, empty
    const whCustomName = hasTempName ? `${nodeVars.ownerTicker} ${custom_flags}` : '';

    // hsSuffix: if nodeVars.name != solarSystemName, we suffix with nodeVars.name
    const needsHsSuffix = hasTempName;
    const hsSuffix = needsHsSuffix ? nodeVars.labelCustom : '';

    // hsCustomName: if temp name is present, use "solarSystemName + suffix"; else "regionName + suffix"
    const hsCustomName = hasTempName ? `${nodeVars.solarSystemName} ${hsSuffix}` : `${nodeVars.regionName} ${hsSuffix}`;

    // customName: final name displayed to user
    const customName = isWormhole ? whCustomName : hsCustomName;

    return { systemName, customLabel, customName };
  }, [custom_flags, nodeVars]);
}

export function useLocalCounter(nodeVars: SolarSystemNodeVars) {
  const sortedCharacters = useMemo(() => {
    return [...nodeVars.charactersInSystem].sort((a, b) => a.name.localeCompare(b.name));
  }, [nodeVars.charactersInSystem]);

  return { sortedCharacters };
}
