import { useCallback, useEffect, useRef, useState } from 'react';
import { OutCommand } from '@/hooks/Mapper/types';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { RoutesType, useRouteProvider } from '../RoutesProvider.tsx';

function usePrevious<T>(value: T): T | undefined {
  const ref = useRef<T>();

  useEffect(() => {
    ref.current = value;
  }, [value]);

  return ref.current;
}

export const useLoadRoutes = () => {
  const [loading, setLoading] = useState(false);
  const { data: routesSettings } = useRouteProvider();

  const {
    outCommand,
    data: { selectedSystems, hubs, systems, connections, routes },
  } = useMapRootState();

  // Add debug logging for hubs
  useEffect(() => {
    console.log('useLoadRoutes - hubs changed:', hubs);
  }, [hubs]);

  const prevSys = usePrevious(systems);
  const ref = useRef({ prevSys, selectedSystems });
  ref.current = { prevSys, selectedSystems };

  // Extract complex expression to a separate variable
  const routesSettingsString = JSON.stringify(routesSettings);

  const loadRoutes = useCallback(
    (systemId: string, routesSettings: RoutesType) => {
      console.log('loadRoutes called with hubs:', hubs);
      setLoading(true);
      outCommand({
        type: OutCommand.getRoutes,
        data: {
          system_id: systemId,
          routes_settings: routesSettings,
        },
      }).finally(() => {
        setLoading(false);
      });
    },
    [outCommand, hubs],
  );

  useEffect(() => {
    if (selectedSystems.length !== 1) {
      return;
    }

    const [systemId] = selectedSystems;
    console.log('Triggering loadRoutes with hubs:', hubs);
    loadRoutes(systemId, routesSettings);
  }, [loadRoutes, selectedSystems, systems?.length, connections, hubs, routesSettings, routesSettingsString]);

  return { loading, loadRoutes, routes };
};
