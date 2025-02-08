import { useEffect, useMemo, useRef } from 'react';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';
import { parseSignatureCustomInfo } from '@/hooks/Mapper/helpers/parseSignatureCustomInfo';
import { useCommandsSystems } from '@/hooks/Mapper/mapRootProvider/hooks/api/useCommandsSystems';
import { SystemSignature } from '@/hooks/Mapper/types';
import { LabelInfo } from './useSolarSystemLogic';

function safeString(value?: string | null, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

export function useZooNames(
  {
    temporaryName,
    solarSystemName,
    regionName,
    labelCustom,
    ownerTicker,
    isWormhole,
  }: {
    temporaryName?: string | null;
    solarSystemName?: string | null;
    regionName?: string | null;
    labelCustom?: string | null;
    ownerTicker?: string | null;
    isWormhole?: boolean;
  },
  { data: { custom_flags } }: NodeProps<MapSolarSystemType>
) {
  return useMemo(() => {
    const safeSolarSystemName = safeString(solarSystemName);
    const safeTemporaryName = safeString(temporaryName, safeSolarSystemName);
    const safeRegionName = safeString(regionName);
    const safeLabelCustom = safeString(labelCustom);
    const safeOwnerTicker = safeString(ownerTicker);
    const safeFlags = safeString(custom_flags);


    const computedSystemName = safeTemporaryName;
    const computedCustomLabel = isWormhole
      ? safeSolarSystemName || safeLabelCustom
      : safeTemporaryName !== safeSolarSystemName
        ? safeRegionName
        : '';
    const computedCustomName = isWormhole
      ? `${safeOwnerTicker} ${safeFlags}`
      : safeTemporaryName !== safeSolarSystemName
        ? `${safeSolarSystemName} ${safeLabelCustom}`
        : `${safeRegionName} ${safeLabelCustom}`;

    return {
      systemName: computedSystemName,
      customLabel: computedCustomLabel,
      customName: computedCustomName,
    };
  }, [
    temporaryName,
    solarSystemName,
    regionName,
    labelCustom,
    ownerTicker,
    isWormhole,
    custom_flags,
  ]);
}

export function useZooLabels(
  connectionCount: number,
  {
    unsplashedLeft,
    unsplashedRight,
    systemSigs,
    labelInfo,
  }: {
    unsplashedLeft: any[];  // ideally, type these properly
    unsplashedRight: any[];
    systemSigs?: SystemSignature[] | null;
    labelInfo: LabelInfo[];
  }
) {
  const unsplashedCount =
    unsplashedLeft.length + unsplashedRight.length - connectionCount;

  const hasGasLabel = labelInfo.some(label => label.id === 'gas');

  let hasEol = false;
  let isDeadEnd = true;
  let hasGas = false;
  let hasCrit = false;

  if (systemSigs) {
    for (const s of systemSigs) {
      const customInfo = parseSignatureCustomInfo(s.custom_info);
      if (s.group === 'Wormhole' || s.group === 'Cosmic Signature') {
        isDeadEnd = false;
      }
      if (s.group === 'Wormhole' && customInfo?.isEOL) {
        hasEol = true;
      }
      if (s.group === 'Wormhole' && customInfo?.isCrit) {
        hasCrit = true;
      }
      // Option 1: Check for exact match
      // if (s.group?.toLowerCase() === 'gas site') {
      // Option 2: More flexible check (allows "gas cloud", "gas site", etc.)
      if (!hasGasLabel && s.group && s.group.trim().toLowerCase().includes('gas')) {
        hasGas = true;
      }

      // If all are true, we can break early.
      if (!isDeadEnd && hasEol && hasGas && hasCrit) {
        break;
      }
    }
  }



  return { unsplashedCount, hasEol, hasGas, isDeadEnd, hasCrit };
}

export function useUpdateSignatures(systemId: string): void {
  const { updateSystemSignatures } = useCommandsSystems();

  useEffect(() => {
    // Trigger update every time the systemId changes.
    updateSystemSignatures(systemId);
  }, [systemId, updateSystemSignatures]);
}
