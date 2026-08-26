import { CharacterTypeRaw, PingType, SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { PingData } from '@/hooks/Mapper/types/ping';
import { rallySourceCandidates } from './rallySourceCandidates';

export interface RallyRouteData {
  // Systems that are part of the rally route
  highlightedSystems: Set<string>;
  // Connections that are part of the rally route
  highlightedConnections: Set<string>;
  // Whether a rally route is active
  isActive: boolean;
  // The rally point system ID
  rallySystemId: string | null;
  // The source character's current system, if one was selected. Populated even when no route was
  // found, so it says where we routed *from*, not that anything is drawn.
  sourceCharacterSystemId: string | null;
  // eve_id of the character the route was actually drawn from (or the best candidate we tried, in
  // the unreachable case). Null whenever no candidate was ever selected.
  sourceCharacterEveId: string | null;
  // Why no route is showing. Null when a route drew successfully.
  reason: 'no-ping' | 'no-source' | 'unreachable' | null;
}

export interface ResolveRallyRouteParams {
  characters: CharacterTypeRaw[];
  mainCharacterEveId: string | null;
  followingCharacterEveId: string | null;
  pings: PingData[];
  systems: SolarSystemRawType[];
  connections: SolarSystemConnection[];
}

const inactive = (
  rallySystemId: string | null,
  sourceCharacterSystemId: string | null,
  sourceCharacterEveId: string | null,
  reason: RallyRouteData['reason'],
): RallyRouteData => ({
  highlightedSystems: new Set(),
  highlightedConnections: new Set(),
  isActive: false,
  rallySystemId,
  sourceCharacterSystemId,
  sourceCharacterEveId,
  reason,
});

/**
 * Work out which systems and connections make up the highlighted rally route.
 *
 * Pure on purpose: the character preference and the fallback below are the whole point of the
 * feature, and a hook cannot be tested without a provider.
 */
export function resolveRallyRoute({
  characters,
  mainCharacterEveId,
  followingCharacterEveId,
  pings,
  systems,
  connections,
}: ResolveRallyRouteParams): RallyRouteData {
  // Find the active rally point
  const rallyPing = pings.find(ping => ping.type === PingType.Rally);

  if (!rallyPing) {
    return inactive(null, null, null, 'no-ping');
  }

  const candidates = rallySourceCandidates(characters, {
    mainEveId: mainCharacterEveId,
    followingEveId: followingCharacterEveId,
  });

  const systemIds = systems.map(s => s.id);
  let firstSourceSystemId: string | null = null;
  let firstSourceEveId: string | null = null;

  // Candidates are ordered best-first. Walk them rather than committing to the first, so a main
  // character with no path to the rally hands off to the followed character instead of blanking a
  // route that would otherwise be drawn.
  for (const candidate of candidates) {
    // The route is shown even when the character is offline, as long as they have a location — the
    // online check only decides whether the *main* character is preferred, in rallySourceCandidates.
    if (!candidate.location?.solar_system_id) {
      continue;
    }

    const sourceCharacterSystemId = candidate.location.solar_system_id.toString();
    firstSourceSystemId ??= sourceCharacterSystemId;
    firstSourceEveId ??= candidate.eve_id;

    // Already at the rally point
    if (sourceCharacterSystemId === rallyPing.solar_system_id) {
      return {
        highlightedSystems: new Set([rallyPing.solar_system_id]),
        highlightedConnections: new Set(),
        isActive: true,
        rallySystemId: rallyPing.solar_system_id,
        sourceCharacterSystemId,
        sourceCharacterEveId: candidate.eve_id,
        reason: null,
      };
    }

    const route = findRoute(sourceCharacterSystemId, rallyPing.solar_system_id, connections, systemIds);

    if (!route) {
      continue;
    }

    const highlightedSystems = new Set(route.path);
    const highlightedConnections = new Set<string>();

    for (let i = 0; i < route.path.length - 1; i++) {
      const source = route.path[i];
      const target = route.path[i + 1];

      const connection = connections.find(
        conn =>
          (conn.source === source && conn.target === target) || (conn.source === target && conn.target === source),
      );

      if (connection) {
        // Normalized connection ID, matching what SolarSystemEdge looks up
        highlightedConnections.add([connection.source, connection.target].sort().join('-'));
      }
    }

    return {
      highlightedSystems,
      highlightedConnections,
      isActive: true,
      rallySystemId: rallyPing.solar_system_id,
      sourceCharacterSystemId,
      sourceCharacterEveId: candidate.eve_id,
      reason: null,
    };
  }

  // No candidate ever produced a usable location: there was nothing to route from at all. At least
  // one candidate had a location but couldn't reach the rally point: both main and followed failed.
  return firstSourceSystemId === null
    ? inactive(rallyPing.solar_system_id, null, null, 'no-source')
    : inactive(rallyPing.solar_system_id, firstSourceSystemId, firstSourceEveId, 'unreachable');
}

/**
 * Find the shortest route between two systems using BFS
 */
function findRoute(
  startSystemId: string,
  endSystemId: string,
  connections: SolarSystemConnection[],
  validSystems: string[],
): { path: string[] } | null {
  // Build adjacency list
  const adjacencyList = new Map<string, string[]>();

  for (const system of validSystems) {
    adjacencyList.set(system, []);
  }

  for (const connection of connections) {
    const sourceList = adjacencyList.get(connection.source);
    const targetList = adjacencyList.get(connection.target);

    if (sourceList && targetList) {
      sourceList.push(connection.target);
      targetList.push(connection.source);
    }
  }

  // BFS to find shortest path
  const queue: { systemId: string; path: string[] }[] = [{ systemId: startSystemId, path: [startSystemId] }];
  const visited = new Set<string>([startSystemId]);

  while (queue.length > 0) {
    const current = queue.shift()!;

    if (current.systemId === endSystemId) {
      return { path: current.path };
    }

    const neighbors = adjacencyList.get(current.systemId) || [];

    for (const neighbor of neighbors) {
      if (!visited.has(neighbor)) {
        visited.add(neighbor);
        queue.push({ systemId: neighbor, path: [...current.path, neighbor] });
      }
    }
  }

  return null;
}
