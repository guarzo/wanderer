import Topbar from '@/hooks/Mapper/components/topbar/Topbar.tsx';
import { MapInterface } from '@/hooks/Mapper/components/mapInterface/MapInterface.tsx';
import Layout from '@/hooks/Mapper/components/layout/Layout.tsx';
import { MapWrapper } from '@/hooks/Mapper/components/mapWrapper/MapWrapper.tsx';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useCallback, useState, useEffect, MutableRefObject } from 'react';
import { OnTheMap, RightBar } from '@/hooks/Mapper/components/mapRootContent/components';
import { MapContextMenu } from '@/hooks/Mapper/components/mapRootContent/components/MapContextMenu/MapContextMenu.tsx';
import { useSkipContextMenu } from '@/hooks/Mapper/hooks/useSkipContextMenu';
import { MapSettings } from '@/hooks/Mapper/components/mapRootContent/components/MapSettings';
import { CharacterActivity, ActivitySummary } from '@/hooks/Mapper/components/map/components/CharacterActivity';
import TrackAndFollow from '@/hooks/Mapper/components/map/components/TrackAndFollow/TrackAndFollow';
import { TrackingCharacter } from '@/hooks/Mapper/components/map/components/TrackAndFollow/TrackAndFollow';
import { OutCommand, MapEventHandlers, CommandData, Commands } from '@/hooks/Mapper/types/mapHandlers';

// Create a global object to hold our direct access functions
declare global {
  interface Window {
    MapperDirectAccess: {
      showCharacterActivity: () => void;
      showTrackAndFollow: () => void;
      forceShowTrackAndFollow: () => void;
      forceShowCharacterActivity: () => void;
    };
  }
}

export interface MapRootContentProps {
  eventHandlers?: MutableRefObject<MapEventHandlers>;
}

export const MapRootContent = ({ eventHandlers }: MapRootContentProps) => {
  const { interfaceSettings, outCommand, data, update } = useMapRootState();
  const { isShowMenu } = interfaceSettings;
  const { showCharacterActivity, characterActivityData, showTrackAndFollow, trackingCharactersData } = data;

  const themeClass = `${interfaceSettings.theme ?? 'default'}-theme`;

  const [showOnTheMap, setShowOnTheMap] = useState(false);
  const [showMapSettings, setShowMapSettings] = useState(false);
  const mapInterface = <MapInterface />;

  const handleShowOnTheMap = useCallback(() => setShowOnTheMap(true), []);
  const handleShowMapSettings = useCallback(() => setShowMapSettings(true), []);

  const handleHideCharacterActivity = useCallback(() => {
    update(state => ({ ...state, showCharacterActivity: false }));
    outCommand({
      type: OutCommand.hideActivity,
      data: {},
    });
  }, [outCommand, update]);

  const handleHideTracking = useCallback(() => {
    update(state => ({ ...state, showTrackAndFollow: false }));
    outCommand({
      type: OutCommand.hideTracking,
      data: {},
    });
  }, [outCommand, update]);

  const handleToggleTrack = useCallback(
    (characterId: string) => {
      outCommand({
        type: OutCommand.toggleTrack,
        data: { 'character-id': characterId },
      });
    },
    [outCommand],
  );

  const handleToggleFollow = useCallback(
    (characterId: string) => {
      outCommand({
        type: OutCommand.toggleFollow,
        data: { 'character-id': characterId },
      });
    },
    [outCommand],
  );

  const handleSetFollow = useCallback(
    (characterId: string) => {
      outCommand({
        type: OutCommand.toggleFollow,
        data: { 'character-id': characterId },
      });
    },
    [outCommand],
  );

  const handleShowActivity = useCallback(() => {
    update(state => ({ ...state, showCharacterActivity: true }));
    outCommand({
      type: OutCommand.showActivity,
      data: {},
    });
  }, [outCommand, update]);

  const handleUpdateActivity = useCallback(
    (activityData: { activity: ActivitySummary[] }) => {
      if (activityData && activityData.activity) {
        // Make a deep copy of the activity data to ensure it's properly updated
        const activityCopy = JSON.parse(JSON.stringify(activityData.activity));
        update(state => ({
          ...state,
          characterActivityData: activityCopy,
          showCharacterActivity: true,
        }));
      }
    },
    [update],
  );

  const handleShowTracking = useCallback(() => {
    // First, update the local state to show the dialog
    update(state => ({ ...state, showTrackAndFollow: true }));

    // Then, send the command to the server to get the latest tracking data
    outCommand({
      type: OutCommand.showTracking,
      data: {},
    });
  }, [outCommand, update]);

  const handleUpdateTracking = useCallback(
    (trackingData: { characters: TrackingCharacter[] }) => {
      if (trackingData && trackingData.characters) {
        // Make a deep copy of the tracking data to ensure it's properly updated
        const trackingCopy = JSON.parse(JSON.stringify(trackingData.characters));

        update(state => ({
          ...state,
          trackingCharactersData: trackingCopy,
          showTrackAndFollow: true,
        }));
      }
    },
    [update],
  );

  const handleRefreshCharacters = useCallback(() => {
    outCommand({
      type: OutCommand.refreshCharacters,
      data: {},
    });

    // Also send the showTracking command to ensure we get the latest data
    outCommand({
      type: OutCommand.showTracking,
      data: {},
    });
  }, [outCommand]);

  const handleUserSettingsUpdated = useCallback(
    (settingsData: CommandData[Commands.userSettingsUpdated]) => {
      if (settingsData && settingsData.settings) {
        // If we have tracking data and primary character ID was updated
        if (trackingCharactersData && trackingCharactersData.length > 0 && settingsData.settings.primary_character_id) {
          const primaryCharacterId = settingsData.settings.primary_character_id as string;

          // Update the tracking data with the new primary character
          const updatedTrackingData = trackingCharactersData.map(char => ({
            ...char,
            is_primary: char.id === primaryCharacterId,
          }));

          update(prevState => ({
            ...prevState,
            trackingCharactersData: updatedTrackingData,
          }));
        }
      }
    },
    [trackingCharactersData, update],
  );

  // Expose the event handlers through the ref
  useEffect(() => {
    if (eventHandlers && eventHandlers.current) {
      eventHandlers.current = {
        handleShowActivity,
        handleUpdateActivity,
        handleHideActivity: handleHideCharacterActivity,
        handleShowTracking,
        handleUpdateTracking,
        handleHideTracking,
        handleRefreshCharacters,
        handleUserSettingsUpdated,
      };
    }

    // Expose direct access functions to the window object
    if (typeof window !== 'undefined') {
      window.MapperDirectAccess = {
        showCharacterActivity: handleShowActivity,
        showTrackAndFollow: handleShowTracking,
        forceShowTrackAndFollow: () => {
          update(state => ({
            ...state,
            showTrackAndFollow: true,
          }));
        },
        forceShowCharacterActivity: () => {
          update(state => ({
            ...state,
            showCharacterActivity: true,
          }));
        },
      };
    }
  }, [
    handleShowActivity,
    handleUpdateActivity,
    handleHideCharacterActivity,
    handleShowTracking,
    handleUpdateTracking,
    handleHideTracking,
    handleRefreshCharacters,
    handleUserSettingsUpdated,
    eventHandlers,
    update,
  ]);

  useSkipContextMenu();

  return (
    <div className={themeClass}>
      <Layout map={<MapWrapper />}>
        {!isShowMenu ? (
          <div className="absolute top-0 left-14 w-[calc(100%-3.5rem)] h-[calc(100%-3.5rem)] pointer-events-none">
            <div className="absolute top-0 left-0 w-[calc(100%-3.5rem)] h-full pointer-events-none">
              <Topbar />
              {mapInterface}
            </div>
            <div className="absolute top-0 right-0 w-14 h-[calc(100%+3.5rem)] pointer-events-auto">
              <RightBar onShowOnTheMap={handleShowOnTheMap} onShowMapSettings={handleShowMapSettings} />
            </div>
          </div>
        ) : (
          <div className="absolute top-0 left-14 w-[calc(100%-3.5rem)] h-[calc(100%-3.5rem)] pointer-events-none">
            <Topbar>
              <MapContextMenu onShowOnTheMap={handleShowOnTheMap} onShowMapSettings={handleShowMapSettings} />
            </Topbar>
            {mapInterface}
          </div>
        )}
        <OnTheMap show={showOnTheMap} onHide={() => setShowOnTheMap(false)} />
        <MapSettings show={showMapSettings} onHide={() => setShowMapSettings(false)} />
        <CharacterActivity
          show={showCharacterActivity}
          onHide={handleHideCharacterActivity}
          activity={characterActivityData || []}
        />
        <div className="pointer-events-auto">
          <TrackAndFollow
            visible={showTrackAndFollow}
            onHide={handleHideTracking}
            characters={trackingCharactersData || []}
            onTrackChange={handleToggleTrack}
            onFollowChange={handleToggleFollow}
            onRefresh={handleRefreshCharacters}
          />
        </div>
      </Layout>
    </div>
  );
};
