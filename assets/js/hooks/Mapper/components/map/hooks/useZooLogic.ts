import { useCallback, useEffect, useMemo, useState } from 'react';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';
import { Commands, OutCommand, SystemSignature } from '@/hooks/Mapper/types';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useMapEventListener } from '@/hooks/Mapper/events';

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
  { data: { custom_flags } }: NodeProps<MapSolarSystemType>,
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
  }, [temporaryName, solarSystemName, regionName, labelCustom, ownerTicker, isWormhole, custom_flags]);
}

export function useZooLabels(
  connectionCount: number,
  {
    unsplashedLeft,
    unsplashedRight,
  }: {
    unsplashedLeft: SystemSignature[];
    unsplashedRight: SystemSignature[];
  },
) {
  const unsplashedCount = unsplashedLeft.length + unsplashedRight.length - connectionCount;
  return { unsplashedCount };
}

export function useNodeSignatures(systemId: string): SystemSignature[] {
  const { outCommand } = useMapRootState();
  const [signatures, setSignatures] = useState<SystemSignature[]>([]);

  // Define a function to fetch the signatures for a system.
  const fetchSignatures = useCallback(async () => {
    try {
      const response = await outCommand({
        type: OutCommand.getSignatures,
        data: { system_id: systemId },
      });
      setSignatures(response.signatures ?? []);
    } catch (error) {
      console.error('Failed to fetch signatures', error);
    }
  }, [outCommand, systemId]);

  // Fetch signatures once when the systemId changes.
  useEffect(() => {
    fetchSignatures();
  }, [fetchSignatures]);

  // Listen for a signaturesUpdated event for this system.
  useMapEventListener(event => {
    if (event.name === Commands.signaturesUpdated && event.data?.toString() === systemId.toString()) {
      const data = event.data as Record<string, SystemSignature[]>;
      if (data && data[systemId]) {
        const newSignatures = data[systemId];
        if (Array.isArray(newSignatures)) {
          setSignatures(newSignatures);
        }
      }
      return true;
    }
    return false;
  });

  return signatures;
}

export function useSignatureAge(systemSigs?: SystemSignature[] | null) {
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const interval = setInterval(() => {
      setNow(Date.now());
    }, 3600000);
    return () => clearInterval(interval);
  }, []);

  return useMemo(() => {
    if (!systemSigs || systemSigs.length === 0) {
      return {
        newestUpdatedAt: 0,
        signatureAgeHours: 0,
        bookmarkColor: '#388E3C',
      };
    }

    const filteredSignatures = systemSigs.filter(s => s.group === 'Wormhole' && !s.linked_system);

    const getSignatureTimestamp = (s: SystemSignature): number => {
      if (s.updated_at) {
        return new Date(s.updated_at).getTime();
      } else if (s.inserted_at) {
        return new Date(s.inserted_at).getTime();
      }
      return 0;
    };

    const newestTimestamp = filteredSignatures.reduce((max, s) => {
      const ts = getSignatureTimestamp(s);
      return ts > max ? ts : max;
    }, 0);

    let signatureAgeHours = 0;
    if (newestTimestamp > 0) {
      const adjustedNow = now + new Date().getTimezoneOffset() * 60000;
      const ageMs = adjustedNow - newestTimestamp;
      signatureAgeHours = Math.round(ageMs / (1000 * 60 * 60));
      signatureAgeHours = Math.max(0, signatureAgeHours);
    }

    let bookmarkColor = '#388E3C';
    if (signatureAgeHours < 4) {
      bookmarkColor = '#388E3C';
    } else if (signatureAgeHours >= 4 && signatureAgeHours <= 8) {
      bookmarkColor = '#E65100';
    } else if (signatureAgeHours > 8 && signatureAgeHours <= 12) {
      bookmarkColor = '#B71C1C';
    } else {
      signatureAgeHours = -1;
    }

    return {
      newestUpdatedAt: newestTimestamp,
      signatureAgeHours,
      bookmarkColor,
      now,
    };
  }, [systemSigs, now]);
}
