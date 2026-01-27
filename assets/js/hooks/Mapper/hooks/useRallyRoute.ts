import { useMemo } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { SolarSystemConnection } from '@/hooks/Mapper/types';

export interface RallyRouteData {
  // Systems that are part of the rally route
  highlightedSystems: Set<string>;
  // Connections that are part of the rally route
  highlightedConnections: Set<string>;
  // Whether a rally route is active
  isActive: boolean;
  // The rally point system ID
  rallySystemId: string | null;
  // The followed character's current system ID
  followedCharacterSystemId: string | null;
}

/**
 * Hook to calculate and provide data for highlighting the route from
 * the followed character to the active rally point
 */
export function useRallyRoute(): RallyRouteData {
  const {
    data: { 
      followingCharacterEveId, 
      characters, 
      pings, 
      systems, 
      connections 
    },
  } = useMapRootState();

  return useMemo(() => {
    // Find the active rally point (type 1)
    const rallyPing = pings.find(ping => ping.type === 1);
    
    if (!rallyPing) {
      return {
        highlightedSystems: new Set(),
        highlightedConnections: new Set(),
        isActive: false,
        rallySystemId: null,
        followedCharacterSystemId: null,
      };
    }

    // Find the followed character - try both string and number comparison
    const followedCharacter = characters.find(
      char => char.eve_id === String(followingCharacterEveId) || 
              char.eve_id === followingCharacterEveId ||
              String(char.eve_id) === String(followingCharacterEveId)
    );
    
    
    // We'll show the route even if the character is offline, as long as they have a location
    if (!followedCharacter || !followedCharacter.location || !followedCharacter.location.solar_system_id) {
      return {
        highlightedSystems: new Set(),
        highlightedConnections: new Set(),
        isActive: false,
        rallySystemId: rallyPing.solar_system_id,
        followedCharacterSystemId: null,
      };
    }

    const followedCharacterSystemId = followedCharacter.location.solar_system_id.toString();

    // If the followed character is already at the rally point
    if (followedCharacterSystemId === rallyPing.solar_system_id) {
      return {
        highlightedSystems: new Set([rallyPing.solar_system_id]),
        highlightedConnections: new Set(),
        isActive: true,
        rallySystemId: rallyPing.solar_system_id,
        followedCharacterSystemId: followedCharacterSystemId,
      };
    }

    // Calculate the route using BFS (Breadth-First Search)
    const route = findRoute(
      followedCharacterSystemId,
      rallyPing.solar_system_id,
      connections,
      systems.map(s => s.id)
    );

    if (!route) {
      return {
        highlightedSystems: new Set(),
        highlightedConnections: new Set(),
        isActive: false,
        rallySystemId: rallyPing.solar_system_id,
        followedCharacterSystemId: followedCharacterSystemId,
      };
    }

    // Create sets for highlighted systems and connections
    const highlightedSystems = new Set(route.path);
    const highlightedConnections = new Set<string>();

    // Add connections to the highlighted set
    for (let i = 0; i < route.path.length - 1; i++) {
      const source = route.path[i];
      const target = route.path[i + 1];
      
      // Find the connection between these systems
      const connection = connections.find(
        conn => 
          (conn.source === source && conn.target === target) ||
          (conn.source === target && conn.target === source)
      );
      
      if (connection) {
        // Create a normalized connection ID
        const connectionId = [connection.source, connection.target].sort().join('-');
        highlightedConnections.add(connectionId);
      }
    }

    return {
      highlightedSystems,
      highlightedConnections,
      isActive: true,
      rallySystemId: rallyPing.solar_system_id,
      followedCharacterSystemId: followedCharacterSystemId,
    };
  }, [followingCharacterEveId, characters, pings, systems, connections]);
}

/**
 * Find the shortest route between two systems using BFS
 */
function findRoute(
  startSystemId: string,
  endSystemId: string,
  connections: SolarSystemConnection[],
  validSystems: string[]
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
  const queue: { systemId: string; path: string[] }[] = [
    { systemId: startSystemId, path: [startSystemId] }
  ];
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
        queue.push({
          systemId: neighbor,
          path: [...current.path, neighbor]
        });
      }
    }
  }

  return null;
}