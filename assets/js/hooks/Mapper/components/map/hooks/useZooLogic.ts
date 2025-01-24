import { useMemo } from 'react';
import { SolarSystemNodeVars } from './useSolarSystemLogic';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';

function safeString(value?: string | null, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

export function useZooNames(nodeVars: SolarSystemNodeVars, props: NodeProps<MapSolarSystemType>) {
  const { data } = props;
  const { custom_flags } = data;

  return useMemo(() => {
    // Convert potential null/undefined to safe values
    const temporaryName = safeString(nodeVars.temporaryName);
    const solarSystemName = safeString(nodeVars.solarSystemName);
    const regionName = safeString(nodeVars.regionName);
    const labelCustom = safeString(nodeVars.labelCustom);
    const ownerTicker = safeString(nodeVars.ownerTicker);
    const flags = safeString(custom_flags);

    const isWormhole = Boolean(nodeVars.isWormhole);

    /**
     * systemName:
     *   - Use temporaryName if present
     *   - Otherwise, use solarSystemName
     */
    const hasTempName = Boolean(temporaryName);
    const systemName = hasTempName ? temporaryName : solarSystemName;

    /**
     * customLabel:
     *   - If wormhole, prefer solarSystemName; else fallback to labelCustom
     *   - If not wormhole but has temp name, prefer regionName
     */
    const customLabel = isWormhole ? solarSystemName || labelCustom : hasTempName ? regionName : labelCustom;

    /**
     * customName:
     *   - For wormholes: if there's a temp name, show "ownerTicker + custom_flags", else empty
     *   - Otherwise (HS/non-wormhole): if temp name, "solarSystemName labelCustom"; else "regionName labelCustom"
     */
    const customName = isWormhole
      ? hasTempName
        ? `${ownerTicker} ${flags}`
        : ''
      : hasTempName
        ? `${solarSystemName} ${labelCustom}`
        : `${regionName} ${labelCustom}`;

    return { systemName, customLabel, customName };
  }, [custom_flags, nodeVars]);
}
