import { useCallback, useEffect, useState, useMemo } from 'react';
import debounce from 'lodash.debounce';
import { OutCommand, Commands } from '@/hooks/Mapper/types/mapHandlers';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { DetailedKill } from '@/hooks/Mapper/types/kills';

interface UseSystemKillsProps {
  systemId?: string;
  visibleSystemIds?: string[];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  outCommand: (payload: any) => Promise<any>;
  showAllVisible: boolean;
}

export function useSystemKills({ systemId, visibleSystemIds = [], outCommand, showAllVisible }: UseSystemKillsProps) {
  const [killsMap, setKillsMap] = useState<Record<string, DetailedKill[]>>({});
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchKills = useCallback(async () => {
    if (!showAllVisible && !systemId) {
      setKillsMap({});
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      let eventType: OutCommand;
      let data: Record<string, unknown>;

      if (showAllVisible) {
        eventType = OutCommand.getSystemsKills;
        data = {
          system_ids: visibleSystemIds,
          since_hours: 24,
        };
      } else {
        eventType = OutCommand.getSystemKills;
        data = {
          system_id: systemId,
          since_hours: 24,
        };
      }

      const resp = await outCommand({
        type: eventType,
        data,
      });

      if (showAllVisible) {
        if (resp.systems_kills) {
          const newMap = resp.systems_kills as Record<string, DetailedKill[]>;
          setKillsMap(prev => ({ ...prev, ...newMap }));
        } else {
          console.warn('Unexpected response shape for multiple kills =>', resp);
        }
      } else {
        if (resp.kills) {
          const fetched: DetailedKill[] = resp.kills;
          const nextMap: Record<string, DetailedKill[]> = {};

          for (const kill of fetched) {
            const sid = String(kill.solar_system_id);
            if (!nextMap[sid]) {
              nextMap[sid] = [];
            }
            nextMap[sid].push(kill);
          }
          setKillsMap(prev => ({ ...prev, ...nextMap }));
        } else {
          console.warn('Unexpected response shape for single kills =>', resp);
        }
      }
    } catch (err) {
      console.error('[useSystemKills] Failed to get kills:', err);
      setError('Error fetching kills');
    } finally {
      setIsLoading(false);
    }
  }, [systemId, visibleSystemIds, showAllVisible, outCommand]);

  const debouncedFetchKills = useMemo(() => debounce(fetchKills, 2000), [fetchKills]);

  useEffect(() => {
    debouncedFetchKills();
    return () => debouncedFetchKills.cancel();
  }, [systemId, visibleSystemIds, showAllVisible, debouncedFetchKills]);

  useMapEventListener(event => {
    if (event.name === Commands.detailedKillsUpdated) {
      const updatedData = event.data as Record<string, DetailedKill[]>;
      setKillsMap(prev => {
        const next = { ...prev };
        for (const [sid, kills] of Object.entries(updatedData)) {
          next[sid] = kills;
        }
        return next;
      });
    }
  });

  let finalKills: DetailedKill[] = [];
  if (showAllVisible) {
    for (const vid of visibleSystemIds) {
      finalKills = finalKills.concat(killsMap[vid] || []);
    }
  } else if (systemId) {
    finalKills = killsMap[systemId] || [];
  }

  const effectiveIsLoading = isLoading && finalKills.length === 0;

  return {
    kills: finalKills,
    isLoading: effectiveIsLoading,
    error,
    refetch: fetchKills,
  };
}
