import { useCallback, useEffect, useMemo, useState } from 'react';
import { NodeProps } from 'reactflow';
import { MapSolarSystemType } from '../map.types';
import { Commands, SystemSignature } from '@/hooks/Mapper/types';
import { OutCommand } from '@/hooks/Mapper/types';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { useMapState } from '../MapProvider';
import { useUnsplashedSignatures } from './useUnsplashedSignatures';

const zkillboardBaseURL = 'https://zkillboard.com';

/**
 * Safely returns a string value or a fallback.
 */
function safeString(value?: string | null, fallback = ''): string {
  return value ?? fallback;
}

/**
 * Custom hook to listen for signature updates.
 *
 * @param systemId - The ID of the system to listen for.
 * @param onUpdate - Callback when new signatures are available.
 */
function useSignatureUpdateListener(systemId: string, onUpdate: (newSignatures: SystemSignature[]) => void): void {
  useMapEventListener(({ name, data }) => {
    if (name === Commands.signaturesUpdated && data?.toString() === systemId.toString()) {
      const dataRecord = data as Record<string, SystemSignature[]>;
      const newSignatures = dataRecord[systemId];
      if (Array.isArray(newSignatures)) {
        onUpdate(newSignatures);
      }
      return true;
    }
    return false;
  });
}

/**
 * Computes display names based on the provided values.
 */
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
    ownerId?: string | null;
    ownerType?: string | null;
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
  }, [solarSystemName, temporaryName, regionName, labelCustom, ownerTicker, custom_flags, isWormhole]);
}

/**
 * Computes the number of unsplashed signatures adjusted by the number of connections.
 */
export function useZooLabels(connectionCount: number, systemSigs?: SystemSignature[] | null) {
  const { unsplashedLeft, unsplashedRight } = useUnsplashedSignatures(systemSigs ?? [], true);
  const unsplashedCount = useMemo(
    () => unsplashedLeft.length + unsplashedRight.length - connectionCount,
    [unsplashedLeft, unsplashedRight, connectionCount],
  );
  return { unsplashedCount };
}

/**
 * Fetches and maintains the ticker and URL for a node owner.
 */
export function useNodeOwnerTicker(ownerId?: string | null, ownerType?: string | null) {
  const [ownerTicker, setOwnerTicker] = useState<string | null>(null);
  const [ownerURL, setOwnerURL] = useState('');
  const { outCommand } = useMapState();

  useEffect(() => {
    let isMounted = true;
    if (!ownerId || !ownerType) {
      setOwnerTicker(null);
      setOwnerURL('');
      return;
    }
    if (ownerType === 'corp') {
      outCommand({
        type: OutCommand.getCorporationTicker,
        data: { corp_id: ownerId },
      }).then(({ ticker }) => {
        if (isMounted) {
          setOwnerTicker(ticker);
          setOwnerURL(`${zkillboardBaseURL}/corporation/${ownerId}`);
        }
      });
    } else if (ownerType === 'alliance') {
      outCommand({
        type: OutCommand.getAllianceTicker,
        data: { alliance_id: ownerId },
      }).then(({ ticker }) => {
        if (isMounted) {
          setOwnerTicker(ticker);
          setOwnerURL(`${zkillboardBaseURL}/alliance/${ownerId}`);
        }
      });
    }
    return () => {
      isMounted = false;
    };
  }, [outCommand, ownerId, ownerType]);

  return { ownerTicker, ownerURL };
}

/**
 * Fetches and maintains signatures for a given system.
 */
export function useNodeSignatures(systemId: string): SystemSignature[] {
  const { outCommand } = useMapRootState();
  const [signatures, setSignatures] = useState<SystemSignature[]>([]);

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

  useEffect(() => {
    // Optionally, you might clear signatures when systemId changes:
    // setSignatures([]);
    fetchSignatures();
  }, [fetchSignatures]);

  useSignatureUpdateListener(systemId, newSignatures => {
    setSignatures(newSignatures);
  });

  return signatures;
}

/**
 * Helper to map signature age (in hours) to a bookmark color.
 */
function getBookmarkColor(signatureAgeHours: number): { color: string; age: number } {
  if (signatureAgeHours < 4) {
    return { color: '#388E3C', age: signatureAgeHours };
  } else if (signatureAgeHours >= 4 && signatureAgeHours <= 8) {
    return { color: '#E65100', age: signatureAgeHours };
  } else if (signatureAgeHours > 8 && signatureAgeHours <= 12) {
    return { color: '#B71C1C', age: signatureAgeHours };
  } else {
    return { color: '#388E3C', age: -1 };
  }
}

/**
 * Computes the age of the most recently updated wormhole signature.
 */
export function useSignatureAge(systemSigs?: SystemSignature[] | null) {
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const interval = setInterval(() => {
      setNow(Date.now());
    }, 3600000); // update every hour
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

    // Filter for wormhole signatures that aren’t linked to another system.
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
      // Adjust for timezone offset.
      const adjustedNow = now + new Date().getTimezoneOffset() * 60000;
      const ageMs = adjustedNow - newestTimestamp;
      signatureAgeHours = Math.round(ageMs / (1000 * 60 * 60));
      signatureAgeHours = Math.max(0, signatureAgeHours);
    }

    const { color: bookmarkColor, age: computedAge } = getBookmarkColor(signatureAgeHours);

    return {
      newestUpdatedAt: newestTimestamp,
      signatureAgeHours: computedAge,
      bookmarkColor,
      now,
    };
  }, [systemSigs, now]);
}
