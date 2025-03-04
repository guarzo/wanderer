import Topbar from '@/hooks/Mapper/components/topbar/Topbar.tsx';
import { MapInterface } from '@/hooks/Mapper/components/mapInterface/MapInterface.tsx';
import Layout from '@/hooks/Mapper/components/layout/Layout.tsx';
import { MapWrapper } from '@/hooks/Mapper/components/mapWrapper/MapWrapper.tsx';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useState, useEffect, MutableRefObject } from 'react';
import { OnTheMap, RightBar } from '@/hooks/Mapper/components/mapRootContent/components';
import { MapContextMenu } from '@/hooks/Mapper/components/mapRootContent/components/MapContextMenu/MapContextMenu.tsx';
import { useSkipContextMenu } from '@/hooks/Mapper/hooks/useSkipContextMenu';
import { MapSettings } from '@/hooks/Mapper/components/mapRootContent/components/MapSettings';
import { CharacterActivity } from '@/hooks/Mapper/components/mapRootContent/components/CharacterActivity/CharacterActivity';
import { TrackAndFollow } from '@/hooks/Mapper/components/mapRootContent/components/TrackAndFollow/TrackAndFollow';
import { MapEventHandlers } from '@/hooks/Mapper/types/mapHandlers';
import { useCharacterActivityHandlers } from './hooks/useCharacterActivityHandlers';
import { useTrackAndFollowHandlers } from './hooks/useTrackAndFollowHandlers';

export interface MapRootContentProps {
  eventHandlers?: MutableRefObject<MapEventHandlers>;
}

/**
 * Main content component for the map root
 * This component is responsible for rendering the map interface and various dialogs
 */
export const MapRootContent = ({ eventHandlers }: MapRootContentProps) => {
  const { interfaceSettings, data } = useMapRootState();
  const { isShowMenu } = interfaceSettings;
  const { showCharacterActivity, characterActivityData, showTrackAndFollow, trackingCharactersData } = data;

  const themeClass = `${interfaceSettings.theme ?? 'default'}-theme`;

  const [showOnTheMap, setShowOnTheMap] = useState(false);
  const [showMapSettings, setShowMapSettings] = useState(false);
  const mapInterface = <MapInterface />;

  // Use custom hooks for handlers
  const { handleHideCharacterActivity, handleShowActivity, handleUpdateActivity } = useCharacterActivityHandlers();

  const {
    handleHideTracking,
    handleShowTracking,
    handleUpdateTracking,
    handleToggleTrack,
    handleToggleFollow,
    handleRefreshCharacters,
    handleUserSettingsUpdated,
  } = useTrackAndFollowHandlers();

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
  }, [
    eventHandlers,
    handleShowActivity,
    handleUpdateActivity,
    handleHideCharacterActivity,
    handleShowTracking,
    handleUpdateTracking,
    handleHideTracking,
    handleRefreshCharacters,
    handleUserSettingsUpdated,
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
                onShowOnTheMap={() => setShowOnTheMap(true)}
                onShowMapSettings={() => setShowMapSettings(true)}
              />
            </div>
          </div>
        ) : (
          <div className="absolute top-0 left-14 w-[calc(100%-3.5rem)] h-[calc(100%-3.5rem)] pointer-events-none">
            <Topbar>
              <MapContextMenu
                onShowOnTheMap={() => setShowOnTheMap(true)}
                onShowMapSettings={() => setShowMapSettings(true)}
              />
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
        <TrackAndFollow
          visible={showTrackAndFollow}
          onHide={() => {
            handleHideTracking();
          }}
          characters={trackingCharactersData || []}
          onTrackChange={characterId => {
            handleToggleTrack(characterId);
          }}
          onFollowChange={characterId => {
            handleToggleFollow(characterId);
          }}
          onRefresh={() => {
            handleRefreshCharacters();
          }}
        />
      </Layout>
    </div>
  );
};
