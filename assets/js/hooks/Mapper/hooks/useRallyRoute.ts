import { useMemo } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { RallyRouteData, resolveRallyRoute } from './resolveRallyRoute';

export type { RallyRouteData };

/**
 * Hook to calculate and provide data for highlighting the route to the active rally point.
 *
 * The route is drawn from the main character when it is on the map, online, and has a route to the
 * rally point, and from the followed character otherwise — see resolveRallyRoute.
 */
export function useRallyRoute(): RallyRouteData {
  const {
    data: { mainCharacterEveId, followingCharacterEveId, characters, pings, systems, connections },
  } = useMapRootState();

  return useMemo(
    () =>
      resolveRallyRoute({
        characters,
        mainCharacterEveId,
        followingCharacterEveId,
        pings,
        systems,
        connections,
      }),
    [mainCharacterEveId, followingCharacterEveId, characters, pings, systems, connections],
  );
}
