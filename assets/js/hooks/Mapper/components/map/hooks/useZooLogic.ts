import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';
import { parseSignatureCustomInfo } from '@/hooks/Mapper/helpers/parseSignatureCustomInfo';
import { useCommandsSystems } from '@/hooks/Mapper/mapRootProvider/hooks/api/useCommandsSystems';
import { OutCommand, SystemSignature } from '@/hooks/Mapper/types';
import { LabelInfo } from './useSolarSystemLogic';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';

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

export function useGetSignatures(systemId: string): SystemSignature[] {
  const { outCommand } = useMapRootState();
  const [signatures, setSignatures] = useState<SystemSignature[]>([]);

  const handleGetSignatures = useCallback(async () => {
    try {
      const { signatures } = await outCommand({
        type: OutCommand.getSignatures,
        data: { system_id: systemId },
      });
      setSignatures(signatures);
    } catch (error) {
      console.error('Failed to fetch signatures', error);
    }
  }, [outCommand, systemId]);

  useEffect(() => {
    const timer = setTimeout(() => {
      handleGetSignatures();
    }, 10);
    return () => clearTimeout(timer);
  }, [handleGetSignatures]);

  return signatures;
}


export function useSignatureAge(systemSigs?: SystemSignature[] | null) {
  return useMemo(() => {
    // If there are no signatures, return defaults.
    if (!systemSigs || systemSigs.length === 0) {
      return {
        newestUpdatedAt: 0,
        signatureAgeHours: 0,
        bookmarkColor: '#F57C00', // default to dark orange
      };
    }

    // Filter to signatures you care about (e.g., group "Wormhole" and not linked)
    const filteredSignatures = systemSigs.filter(
      s => s.group === 'Wormhole' && !s.linked_system
    );

    // Helper function to get a timestamp from a signature.
    const getSignatureTimestamp = (s: SystemSignature): number => {
      if (s.updated_at) {
        return new Date(s.updated_at).getTime();
      } else if (s.inserted_at) {
        return new Date(s.inserted_at).getTime();
      }
      return 0;
    };

    // Compute the newest timestamp using updated_at as primary, inserted_at as secondary.
    const newestTimestamp = filteredSignatures.reduce((max, s) => {
      const ts = getSignatureTimestamp(s);
      return ts > max ? ts : max;
    }, 0);

    // Calculate the age in hours (rounded to the nearest hour)
    let signatureAgeHours = 0;
    if (newestTimestamp > 0) {
      const ageMs = Date.now() - newestTimestamp;
      signatureAgeHours = Math.round(ageMs / (1000 * 60 * 60));
      // Clamp negative values to 0 (so a future timestamp doesn't yield a negative age)
      signatureAgeHours = Math.max(0, signatureAgeHours);
    }

    // Choose the bookmark color:
    // - Dark orange for less than 5 hours.
    // - Deep red for 5 hours or more.
    const bookmarkColor = signatureAgeHours < 5 ? '#F57C00' : '#D32F2F';

    return {
      newestUpdatedAt: newestTimestamp,
      signatureAgeHours,
      bookmarkColor,
    };
  }, [systemSigs]);
}
