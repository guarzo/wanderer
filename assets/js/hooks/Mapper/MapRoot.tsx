import { ErrorBoundary } from 'react-error-boundary';
import { PrimeReactProvider } from 'primereact/api';
import { ReactFlowProvider } from 'reactflow';
import { MapHandlers, MapperHooks, MapEventHandlers, Commands, CommandData } from '@/hooks/Mapper/types/mapHandlers.ts';
import { ErrorInfo, useCallback, useEffect, useRef } from 'react';
import { useMapperHandlers } from './useMapperHandlers';
import './common-styles/main.scss';
import { MapRootProvider } from '@/hooks/Mapper/mapRootProvider';
import { MapRootContent } from '@/hooks/Mapper/components/mapRootContent/MapRootContent.tsx';

const ErrorFallback = () => {
  return <div className="!z-100 absolute w-screen h-screen bg-transparent"></div>;
};

export default function MapRoot({ hooks }: { hooks: MapperHooks }) {
  const providerRef = useRef<MapHandlers>(null);
  const hooksRef = useRef<MapperHooks>(hooks);
  const eventHandlersRef = useRef<MapEventHandlers>({
    handleShowActivity: () => {},
    handleUpdateActivity: () => {},
    handleHideActivity: () => {},
    handleShowTracking: () => {},
    handleUpdateTracking: () => {},
    handleHideTracking: () => {},
    handleRefreshCharacters: () => {},
    handleUserSettingsUpdated: () => {},
  });

  const mapperHandlerRefs = useRef([providerRef]);

  const { handleCommand, handleMapEvent, handleMapEvents } = useMapperHandlers(mapperHandlerRefs.current, hooksRef);

  const logError = useCallback((error: Error, info: ErrorInfo) => {
    if (!hooksRef.current) {
      return;
    }
    hooksRef.current.onError(error, info.componentStack || '');
  }, []);

  useEffect(() => {
    if (!hooksRef.current) {
      return;
    }

    // Set up handlers for map events
    hooksRef.current.handleEvent(Commands.mapEvent, (payload: unknown) => {
      if (payload && typeof payload === 'object' && 'type' in payload && 'body' in payload) {
        handleMapEvent(payload as { type: string; body: unknown });
      }
    });

    hooksRef.current.handleEvent(Commands.mapEvents, (payload: unknown) => {
      if (Array.isArray(payload)) {
        handleMapEvents(payload);
      }
    });

    // Set up handlers for activity and tracking events
    // Activity events
    hooksRef.current.handleEvent(Commands.showActivity, () => eventHandlersRef.current?.handleShowActivity());

    hooksRef.current.handleEvent(Commands.updateActivity, (payload: unknown) => {
      if (payload && typeof payload === 'object' && 'activity' in payload) {
        eventHandlersRef.current?.handleUpdateActivity(payload as CommandData[typeof Commands.updateActivity]);
      }
    });

    hooksRef.current.handleEvent(Commands.hideActivity, () => eventHandlersRef.current?.handleHideActivity());

    // Tracking events
    hooksRef.current.handleEvent(Commands.showTracking, () => eventHandlersRef.current?.handleShowTracking());

    hooksRef.current.handleEvent(Commands.updateTracking, (payload: unknown) => {
      if (payload && typeof payload === 'object' && 'characters' in payload) {
        eventHandlersRef.current?.handleUpdateTracking(payload as CommandData[typeof Commands.updateTracking]);
      }
    });

    hooksRef.current.handleEvent(Commands.hideTracking, () => eventHandlersRef.current?.handleHideTracking());

    hooksRef.current.handleEvent(Commands.refreshCharacters, () => eventHandlersRef.current?.handleRefreshCharacters());

    // User settings events
    hooksRef.current.handleEvent(Commands.userSettingsUpdated, (payload: unknown) => {
      if (payload && typeof payload === 'object' && 'settings' in payload) {
        eventHandlersRef.current?.handleUserSettingsUpdated(
          payload as CommandData[typeof Commands.userSettingsUpdated],
        );
      }
    });
  }, [handleMapEvent, handleMapEvents]);

  return (
    <PrimeReactProvider>
      <MapRootProvider fwdRef={providerRef} outCommand={handleCommand}>
        <ErrorBoundary FallbackComponent={ErrorFallback} onError={logError}>
          <ReactFlowProvider>
            <MapRootContent eventHandlers={eventHandlersRef} />
          </ReactFlowProvider>
        </ErrorBoundary>
      </MapRootProvider>
    </PrimeReactProvider>
  );
}
