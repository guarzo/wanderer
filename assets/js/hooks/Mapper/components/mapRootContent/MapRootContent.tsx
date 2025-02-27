import Topbar from '@/hooks/Mapper/components/topbar/Topbar.tsx';
import { MapInterface } from '@/hooks/Mapper/components/mapInterface/MapInterface.tsx';
import Layout from '@/hooks/Mapper/components/layout/Layout.tsx';
import { MapWrapper } from '@/hooks/Mapper/components/mapWrapper/MapWrapper.tsx';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useCallback, useState, useEffect } from 'react';
import { OnTheMap, RightBar } from '@/hooks/Mapper/components/mapRootContent/components';
import { MapContextMenu } from '@/hooks/Mapper/components/mapRootContent/components/MapContextMenu/MapContextMenu.tsx';
import { useSkipContextMenu } from '@/hooks/Mapper/hooks/useSkipContextMenu';
import { MapSettings } from '@/hooks/Mapper/components/mapRootContent/components/MapSettings';
import { CharacterActivity, ActivitySummary } from '@/hooks/Mapper/components/map/components/CharacterActivity';
import { TrackAndFollow, CharacterTrackingData } from '@/hooks/Mapper/components/map/components/TrackAndFollow';
import { OutCommand, CommandEmptyData } from '@/hooks/Mapper/types/mapHandlers';

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

export interface MapEventHandlers {
  handleShowActivity: () => void;
  handleUpdateActivity: (activityData: { activity: ActivitySummary[] }) => void;
  handleShowTracking: () => void;
  handleUpdateTracking: (trackingData: { characters: CharacterTrackingData[] }) => void;
  handleHideTracking: () => void;
  handleRefreshCharacters: () => void;
}

export interface MapRootContentProps {
  eventHandlers?: React.MutableRefObject<MapEventHandlers | null>;
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
      data: {} as CommandEmptyData,
    });
  }, [outCommand, update]);

  const handleHideTracking = useCallback(() => {
    update(state => ({ ...state, showTrackAndFollow: false }));
    outCommand({
      type: OutCommand.hideTracking,
      data: {} as CommandEmptyData,
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

  const handleShowActivity = useCallback(() => {
    update(state => ({ ...state, showCharacterActivity: true }));
  }, [update]);

  const handleUpdateActivity = useCallback(
    (activityData: { activity: ActivitySummary[] }) => {
      console.log('handleUpdateActivity called with:', activityData);
      
      if (activityData && activityData.activity) {
        console.log('Activity data received:', activityData.activity);
        console.log('Activity data length:', activityData.activity.length);
        
        if (activityData.activity.length > 0) {
          console.log('First activity item:', activityData.activity[0]);
        }
        
        update(state => ({
          ...state,
          characterActivityData: activityData.activity,
          showCharacterActivity: true,
        }));
      } else {
        console.warn('Activity data is missing or invalid:', activityData);
      }
    },
    [update],
  );

  const handleShowTracking = useCallback(() => {
    update(state => ({ ...state, showTrackAndFollow: true }));
    outCommand({
      type: OutCommand.refreshCharacters,
      data: {} as CommandEmptyData,
    });
  }, [outCommand, update]);

  const handleUpdateTracking = useCallback(
    (trackingData: { characters: CharacterTrackingData[] }) => {
      if (trackingData && trackingData.characters) {
        update(state => ({
          ...state,
          trackingCharactersData: trackingData.characters,
          showTrackAndFollow: true,
        }));
      }
    },
    [update],
  );

  const handleAddCharacter = useCallback(() => {
    update(state => ({ ...state, showTrackAndFollow: true }));
    outCommand({
      type: OutCommand.addCharacter,
      data: {} as CommandEmptyData,
    });
  }, [outCommand, update]);

  const handleRefreshCharacters = useCallback(() => {
    outCommand({
      type: OutCommand.refreshCharacters,
      data: {} as CommandEmptyData,
    });
  }, [outCommand]);

  // Expose the event handlers through the ref
  useEffect(() => {
    if (eventHandlers && eventHandlers.current) {
      eventHandlers.current = {
        handleShowActivity,
        handleUpdateActivity,
        handleShowTracking,
        handleUpdateTracking,
        handleHideTracking,
        handleRefreshCharacters,
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
    handleShowTracking,
    handleUpdateTracking,
    handleHideTracking,
    handleRefreshCharacters,
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
              <RightBar
                onShowOnTheMap={handleShowOnTheMap}
                onShowMapSettings={handleShowMapSettings}
                onShowTrackAndFollow={handleShowTracking}
                onAddCharacter={handleAddCharacter}
              />
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
          activity={characterActivityData}
        />
        <div className="pointer-events-auto">
          <TrackAndFollow
            show={showTrackAndFollow}
            onHide={handleHideTracking}
            characters={trackingCharactersData || []}
            onToggleTrack={handleToggleTrack}
            onToggleFollow={handleToggleFollow}
          />
        </div>
      </Layout>
    </div>
  );
};
