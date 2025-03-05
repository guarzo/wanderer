import { useCallback, useEffect, useState } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand } from '@/hooks/Mapper/types';
import { RoutesType, useRouteProvider } from '../RoutesProvider';

export type RoutesData = {
  routes: {
    destination: number;
    jumps: number;
    route: number[];
    security_status: number;
  }[];
  systems_static_data: Record<string, unknown>;
};

interface RoutesEventDetail {
  loading: boolean;
  routes: RoutesData['routes'];
  systems_static_data: RoutesData['systems_static_data'];
  solar_system_id: string;
}

interface RoutesEvent extends CustomEvent {
  detail: RoutesEventDetail;
}

export const useLoadRoutes = () => {
  const [routes, setRoutes] = useState<RoutesData | null>(null);
  const [loading, setLoading] = useState(false);
  const { outCommand } = useMapRootState();
  const { data: routesSettings } = useRouteProvider();

  // Track the previous system ID for reloading routes when settings change
  const [prevSys, setPrevSys] = useState<string | null>(null);

  useEffect(() => {
    const handleRoutes = (e: RoutesEvent) => {
      if (e.detail.loading === false) {
        setLoading(false);
        setRoutes({
          routes: e.detail.routes,
          systems_static_data: e.detail.systems_static_data,
        });
      } else {
        setLoading(true);
      }
    };

    window.addEventListener('phx:routes', handleRoutes as EventListener);
    return () => window.removeEventListener('phx:routes', handleRoutes as EventListener);
  }, []);

  const loadRoutes = useCallback(
    (systemId: string, routesSettings: RoutesType) => {
      // For wormhole systems (IDs starting with "31"), always set avoid_wormholes to false
      const isWormhole = systemId.startsWith('31');
      const finalSettings = isWormhole ? { ...routesSettings, avoid_wormholes: false } : routesSettings;

      // Store the current system ID to track for settings changes
      setPrevSys(systemId);

      // Set loading state to true when we start loading routes
      setLoading(true);

      // Send command to load routes
      // Note: Loading state will be set to false by the event listener when server responds
      outCommand({
        type: OutCommand.getRoutes,
        data: {
          system_id: systemId,
          routes_settings: finalSettings,
        },
      }).catch(error => {
        console.error('Error loading routes:', error);
        // Set loading to false on error to prevent UI from being stuck in loading state
        setLoading(false);
      });
    },
    [outCommand],
  );

  // Reload routes when settings change
  useEffect(() => {
    if (prevSys) {
      loadRoutes(prevSys, routesSettings);
    }
  }, [routesSettings, loadRoutes, prevSys]);

  return { routes, loading, loadRoutes, setLoading };
};
