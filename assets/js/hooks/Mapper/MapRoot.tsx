import { ErrorBoundary } from 'react-error-boundary';
import { PrimeReactProvider } from 'primereact/api';
import { ReactFlowProvider } from 'reactflow';
import { MapHandlers } from '@/hooks/Mapper/types/mapHandlers.ts';
import { ErrorInfo, useCallback, useEffect, useRef } from 'react';
import { useMapperHandlers } from './useMapperHandlers';

import './common-styles/main.scss';
import { MapRootProvider } from '@/hooks/Mapper/mapRootProvider';
import { MapRootContent } from '@/hooks/Mapper/components/mapRootContent/MapRootContent.tsx';
import { MapperHooks, MapEventHandlers, PhoenixEventName } from './types/events';

const ErrorFallback = () => {
  return <div className="!z-100 absolute w-screen h-screen bg-transparent"></div>;
};

export default function MapRoot({ hooks }: { hooks: MapperHooks }) {
  const providerRef = useRef<MapHandlers>(null);
  const hooksRef = useRef<MapperHooks>(hooks);
  const eventHandlersRef = useRef<MapEventHandlers>({
    handleShowActivity: () => {},
    handleUpdateActivity: () => {},
    handleShowTracking: () => {},
    handleUpdateTracking: () => {},
    handleHideTracking: () => {},
    handleRefreshCharacters: () => {},
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
    hooksRef.current.handleEvent(PhoenixEventName.MAP_EVENT, handleMapEvent);
    hooksRef.current.handleEvent(PhoenixEventName.MAP_EVENTS, handleMapEvents);

    // Set up handlers for activity and tracking events
    const eventMap = {
      // Activity events
      [PhoenixEventName.SHOW_ACTIVITY]: () => eventHandlersRef.current?.handleShowActivity(),
      [PhoenixEventName.UPDATE_ACTIVITY]: (payload) => eventHandlersRef.current?.handleUpdateActivity(payload),
      
      // Tracking events
      [PhoenixEventName.SHOW_TRACKING]: () => eventHandlersRef.current?.handleShowTracking(),
      [PhoenixEventName.UPDATE_TRACKING]: (payload) => eventHandlersRef.current?.handleUpdateTracking(payload),
      [PhoenixEventName.HIDE_TRACKING]: () => eventHandlersRef.current?.handleHideTracking(),
      [PhoenixEventName.REFRESH_CHARACTERS]: () => eventHandlersRef.current?.handleRefreshCharacters(),
    };

    // Register all events with both prefixed and non-prefixed versions
    Object.entries(eventMap).forEach(([eventName, handler]) => {
      // Register with phx: prefix
      hooksRef.current?.handleEvent(`phx:${eventName}`, handler);
      
      // Also register without prefix for backward compatibility
      hooksRef.current?.handleEvent(eventName, handler);
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
