import { useCallback, useMemo, useState, useEffect, useRef } from 'react';
import debounce from 'lodash.debounce';
import { OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { DetailedKill } from '@/hooks/Mapper/types/kills';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useKillsWidgetSettings } from './useKillsWidgetSettings';

interface UseSystemKillsProps {
  systemId?: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  outCommand: (payload: { type: OutCommand; data: Record<string, unknown> }) => Promise<Record<string, unknown>>;
  showAllVisible?: boolean;
  sinceHours?: number;
}

/**
 * Combines existing and incoming kills, filtering by the time cutoff
 * and removing duplicates by killmail_id
 */
function combineKills(existing: DetailedKill[], incoming: DetailedKill[], sinceHours: number): DetailedKill[] {
  const cutoff = Date.now() - sinceHours * 60 * 60 * 1000;
  const byId: Record<string, DetailedKill> = {};

  for (const kill of [...existing, ...incoming]) {
    if (!kill.kill_time) {
      continue;
    }
    const killTimeMs = new Date(kill.kill_time).valueOf();

    if (killTimeMs >= cutoff) {
      byId[kill.killmail_id] = kill;
    }
  }

  return Object.values(byId);
}

/**
 * Hook to fetch and manage kill data for a system or multiple systems
 */
export function useSystemKills({ systemId, outCommand, showAllVisible = false, sinceHours = 24 }: UseSystemKillsProps) {
  // Global state
  const { data, update } = useMapRootState();
  const { detailedKills = {}, systems = [] } = data;
  const [settings] = useKillsWidgetSettings();
  const excludedSystems = settings.excludedSystems;

  // Local state
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const initialFetchDone = useRef(Object.keys(detailedKills).length !== 0);

  // When showing all visible kills, filter out excluded systems;
  // when showAllVisible is false, ignore the exclusion filter.
  const effectiveSystemIds = useMemo(() => {
    if (showAllVisible) {
      return systems.map(s => s.id).filter(id => !excludedSystems.includes(Number(id)));
    }
    return systems.map(s => s.id);
  }, [systems, excludedSystems, showAllVisible]);

  /**
   * Merges new kill data into the global state
   */
  const mergeKillsIntoGlobal = useCallback(
    (killsMap: Record<string, DetailedKill[]>) => {
      update(prev => {
        const oldMap = prev.detailedKills ?? {};
        const updated: Record<string, DetailedKill[]> = { ...oldMap };

        for (const [sid, newKills] of Object.entries(killsMap)) {
          const existing = updated[sid] ?? [];
          const combined = combineKills(existing, newKills, sinceHours);
          updated[sid] = combined;
        }

        return {
          ...prev,
          detailedKills: updated,
        };
      });
    },
    [update, sinceHours],
  );

  /**
   * Fetches kill data from the server
   */
  const fetchKills = useCallback(
    async (forceFallback = false) => {
      setIsLoading(true);
      setError(null);

      try {
        let eventType: OutCommand;
        let requestData: Record<string, unknown>;

        // Determine which API endpoint to use based on mode
        if (showAllVisible || forceFallback) {
          eventType = OutCommand.getSystemsKills;
          requestData = {
            system_ids: effectiveSystemIds,
            since_hours: sinceHours,
          };
        } else if (systemId) {
          eventType = OutCommand.getSystemKills;
          requestData = {
            system_id: systemId,
            since_hours: sinceHours,
          };
        } else {
          // If there's no system and not showing all, do nothing
          setIsLoading(false);
          return;
        }

        const resp = await outCommand({
          type: eventType,
          data: requestData,
        });

        // Process the response
        if (resp?.kills) {
          // Single system response
          const arr = resp.kills as DetailedKill[];
          const sid = systemId ?? 'unknown';
          mergeKillsIntoGlobal({ [sid]: arr });
        } else if (resp?.systems_kills) {
          // Multiple systems response
          mergeKillsIntoGlobal(resp.systems_kills as Record<string, DetailedKill[]>);
        } else {
          console.warn('[useSystemKills] Unexpected kills response =>', resp);
        }
      } catch (err) {
        console.error('[useSystemKills] Failed to fetch kills:', err);
        setError(err instanceof Error ? err.message : 'Error fetching kills');
      } finally {
        setIsLoading(false);
      }
    },
    [showAllVisible, systemId, outCommand, effectiveSystemIds, sinceHours, mergeKillsIntoGlobal],
  );

  // Debounce fetch to avoid hammering the server during rapid changes
  const debouncedFetchKills = useMemo(
    () => debounce(fetchKills, 500, { leading: true, trailing: false }),
    [fetchKills],
  );

  // Compute the final list of kills to display
  const finalKills = useMemo(() => {
    if (showAllVisible) {
      // Show kills from all visible systems
      return effectiveSystemIds.flatMap(sid => detailedKills[sid] ?? []);
    } else if (systemId) {
      // Show kills from a specific system
      return detailedKills[systemId] ?? [];
    } else if (initialFetchDone.current) {
      // If we already did a fallback, we may have data for multiple systems
      return effectiveSystemIds.flatMap(sid => detailedKills[sid] ?? []);
    }
    return [];
  }, [showAllVisible, systemId, effectiveSystemIds, detailedKills]);

  // Only show loading indicator if we don't have any kills yet
  const effectiveIsLoading = isLoading && finalKills.length === 0;

  // Initial fetch for all systems if no specific system is selected
  useEffect(() => {
    if (!systemId && !showAllVisible && !initialFetchDone.current) {
      initialFetchDone.current = true;
      // Cancel any queued debounced calls, then do the fallback
      debouncedFetchKills.cancel();
      fetchKills(true); // forceFallback => fetch as though showAllVisible is true
    }
  }, [systemId, showAllVisible, debouncedFetchKills, fetchKills]);

  // Fetch kills when system ID or visibility changes
  useEffect(() => {
    if (effectiveSystemIds.length === 0) return;

    if (showAllVisible || systemId) {
      debouncedFetchKills();
      // Clean up the debounce on unmount or changes
      return () => debouncedFetchKills.cancel();
    }
  }, [showAllVisible, systemId, effectiveSystemIds, debouncedFetchKills]);

  // Public method to manually refresh data
  const refetch = useCallback(() => {
    debouncedFetchKills.cancel();
    fetchKills(); // immediate (non-debounced) call
  }, [debouncedFetchKills, fetchKills]);

  return {
    kills: finalKills,
    isLoading: effectiveIsLoading,
    error,
    refetch,
  };
}
