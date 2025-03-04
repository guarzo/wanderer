import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useCallback, useRef } from 'react';
import {
  CommandCharacterActivityData,
  CommandTrackingCharactersData,
  Commands,
} from '@/hooks/Mapper/types/mapHandlers';
import { ActivitySummary } from '@/hooks/Mapper/components/mapRootContent/components/CharacterActivity/CharacterActivity';
import { TrackingCharacter } from '@/hooks/Mapper/components/mapRootContent/components/TrackAndFollow/types';
import { MapRootData } from '@/hooks/Mapper/mapRootProvider/MapRootProvider';
import { emitMapEvent } from '@/hooks/Mapper/events';

export const useCommandsActivity = () => {
  const { update } = useMapRootState();

  const ref = useRef({ update });
  ref.current = { update };

  const characterActivityData = useCallback((data: CommandCharacterActivityData) => {
    try {
      if (data && typeof data === 'object' && 'activity' in data && Array.isArray(data.activity)) {
        ref.current.update((state: MapRootData) => ({
          ...state,
          characterActivityData: data.activity as ActivitySummary[],
          showCharacterActivity: true,
        }));
      } else {
        console.error('Invalid character activity data format:', data);
      }
    } catch (error) {
      console.error('Failed to process character activity data:', error);
    }
  }, []);

  const trackingCharactersData = useCallback((data: CommandTrackingCharactersData) => {
    if (data && typeof data === 'object' && 'characters' in data && Array.isArray(data.characters)) {
      ref.current.update((state: MapRootData) => ({
        ...state,
        trackingCharactersData: data.characters as TrackingCharacter[],
        showTrackAndFollow: true,
      }));
    } else {
      console.error('Invalid tracking characters data format:', data);
    }
  }, []);

  const userSettingsUpdated = useCallback((data: Record<string, unknown>) => {
    if (data && typeof data === 'object') {
      emitMapEvent({ name: Commands.userSettingsUpdated, data });
    } else {
      console.error('Invalid user settings data format:', data);
    }
  }, []);

  return { characterActivityData, trackingCharactersData, userSettingsUpdated };
};
