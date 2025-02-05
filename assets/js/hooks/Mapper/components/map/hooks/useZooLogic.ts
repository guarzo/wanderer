import { useMemo } from 'react';
import { SolarSystemNodeVars } from './useSolarSystemLogic';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';

/**
 * Ensures that a given value is a string.
 * If the value is not a string, returns the provided fallback.
 */
function safeString(value?: string | null, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

/**
 * Hook to compute zoo names for a node.
 * It derives systemName, customLabel, and customName based on various node variables.
 *
 * Changes made:
 * - Removed all conditionals around the temporary name.
 * - The temporary name is now always considered to be present.
 */
export function useZooNames(nodeVars: SolarSystemNodeVars, props: NodeProps<MapSolarSystemType>) {
  const { data } = props;
  const { custom_flags } = data;

  // Destructure properties from nodeVars to ensure stable dependencies
  const { temporaryName, solarSystemName, regionName, labelCustom, ownerTicker, isWormhole: nodeIsWormhole } = nodeVars;

  return useMemo(() => {
    // Convert potential null/undefined to safe values
    const safeSolarSystemName = safeString(solarSystemName);
    const safeTemporaryName = safeString(temporaryName, safeSolarSystemName);
    const safeRegionName = safeString(regionName);
    const safeLabelCustom = safeString(labelCustom);
    const safeOwnerTicker = safeString(ownerTicker);
    const safeFlags = safeString(custom_flags);

    // Convert to boolean explicitly for wormhole status
    const isWormhole = Boolean(nodeIsWormhole);

    /**
     * systemName:
     *   - Always use temporaryName.
     */
    const computedSystemName = safeTemporaryName;

    /**
     * customLabel:
     *   - If wormhole: use solarSystemName (if non-empty) otherwise fallback to labelCustom.
     *   - If not wormhole: always use regionName.
     */
    const computedCustomLabel = isWormhole
      ? safeSolarSystemName || safeLabelCustom
      : safeTemporaryName !== safeSolarSystemName
        ? safeRegionName
        : '';

    /**
     * customName:
     *   - For wormholes: always show "ownerTicker custom_flags".
     *   - For non-wormholes: always show "solarSystemName labelCustom".
     */
    const computedCustomName = isWormhole
      ? `${safeOwnerTicker} ${safeFlags}`
      : safeTemporaryName !== safeSolarSystemName
        ? `${safeSolarSystemName} ${safeLabelCustom}`
        : `${safeRegionName} ${safeLabelCustom}`;

    return { systemName: computedSystemName, customLabel: computedCustomLabel, customName: computedCustomName };
  }, [custom_flags, temporaryName, solarSystemName, regionName, labelCustom, ownerTicker, nodeIsWormhole]);
}
