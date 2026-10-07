import { Node, useReactFlow } from 'reactflow';
import { useCallback, useRef } from 'react';
import { CommandAddSystems, OutCommand } from '@/hooks/Mapper/types/mapHandlers.ts';
import { convertSystem2Node } from '../../helpers';
import { useMapState } from '../../MapProvider';
import { autoPlaceSpawnedSystems, readSnapGridFromDom } from '@/hooks/Mapper/helpers/autoPlaceSystems';
import { useLoadSystemStatic } from '@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic';

export const useMapAddSystems = () => {
  const rf = useReactFlow();
  const {
    outCommand,
    data: { options, userPermissions },
  } = useMapState();

  const { addSystemStatic } = useLoadSystemStatic({ systems: [] });

  const ref = useRef({ rf, outCommand, options, userPermissions, addSystemStatic });
  ref.current = { rf, outCommand, options, userPermissions, addSystemStatic };

  return useCallback((systems: CommandAddSystems) => {
    const { rf, outCommand, options, userPermissions, addSystemStatic } = ref.current;
    const nodes = rf.getNodes();

    const newSystems = systems.filter(x => !nodes.some(y => x.id === y.id));
    newSystems.forEach(x => addSystemStatic(x.system_static_info));

    // Spawned systems arrive at the server's ring position, which knows nothing
    // about the theme grid and lets siblings scatter. Re-slot them onto the
    // theme grid before they render. The placement is deterministic, so every
    // client converges on the same positions; persisting it keeps reloads and
    // API consumers in sync (best effort - needs the update permission).
    const placements = autoPlaceSpawnedSystems(newSystems, nodes, {
      snap: readSnapGridFromDom(),
      layout: typeof options?.layout === 'string' ? options.layout : undefined,
    });

    const prepared: Node[] = newSystems.map(system => {
      const position = placements.get(`${system.id}`);

      return convertSystem2Node(position ? { ...system, position } : system);
    });
    rf.addNodes(prepared);

    if (placements.size > 0 && userPermissions?.update_system) {
      outCommand({
        type: OutCommand.updateSystemPositions,
        data: [...placements].map(([solar_system_id, position]) => ({ solar_system_id, position })),
      });
    }
  }, []);
};
