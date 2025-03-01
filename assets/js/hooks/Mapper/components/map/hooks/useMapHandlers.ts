import { ForwardedRef, useImperativeHandle, useRef } from 'react';
import {
  CommandAddConnections,
  CommandAddSystems,
  CommandCharacterAdded,
  CommandCharacterRemoved,
  CommandCharactersUpdated,
  CommandCharacterUpdated,
  CommandInit,
  CommandKillsUpdated,
  CommandMapUpdated,
  CommandPresentCharacters,
  CommandRemoveConnections,
  CommandRemoveSystems,
  Commands,
  CommandSelectSystem,
  CommandUpdateConnection,
  CommandUpdateSystems,
  MapHandlers,
  OutCommand,
  CommandUpdateActivity,
  CommandUpdateTracking,
  CommandCenterSystem,
  CommandEmptyData,
} from '@/hooks/Mapper/types/mapHandlers.ts';

import {
  useCommandsCharacters,
  useCommandsConnections,
  useMapAddSystems,
  useMapCommands,
  useMapInit,
  useMapRemoveSystems,
  useMapUpdateSystems,
  useCenterSystem,
  useSelectSystem,
} from './api';
import { OnMapSelectionChange } from '@/hooks/Mapper/components/map/map.types.ts';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';

export const useMapHandlers = (ref: ForwardedRef<MapHandlers>, onSelectionChange: OnMapSelectionChange) => {
  const mapInit = useMapInit();
  const mapAddSystems = useMapAddSystems();
  const mapUpdateSystems = useMapUpdateSystems();
  const removeSystems = useMapRemoveSystems(onSelectionChange);
  const centerSystem = useCenterSystem();
  const selectSystem = useSelectSystem();

  const selectRef = useRef({ onSelectionChange });
  selectRef.current = { onSelectionChange };

  const { addConnections, removeConnections, updateConnection } = useCommandsConnections();
  const { mapUpdated, killsUpdated } = useMapCommands();
  const { charactersUpdated, presentCharacters, characterAdded, characterRemoved, characterUpdated } =
    useCommandsCharacters();

  const { update, outCommand } = useMapRootState();

  useImperativeHandle(
    ref,
    () => {
      return {
        command(type, data) {
          switch (type) {
            case Commands.init:
              mapInit(data as CommandInit);
              break;
            case Commands.addSystems:
              setTimeout(() => mapAddSystems(data as CommandAddSystems), 100);
              break;
            case Commands.updateSystems:
              mapUpdateSystems(data as CommandUpdateSystems);
              break;
            case Commands.removeSystems:
              setTimeout(() => removeSystems(data as CommandRemoveSystems), 100);
              break;
            case Commands.addConnections:
              setTimeout(() => addConnections(data as CommandAddConnections), 100);
              break;
            case Commands.removeConnections:
              setTimeout(() => removeConnections(data as CommandRemoveConnections), 100);
              break;
            case Commands.charactersUpdated:
              charactersUpdated(data as CommandCharactersUpdated);
              break;
            case Commands.characterAdded:
              characterAdded(data as CommandCharacterAdded);
              break;
            case Commands.characterRemoved:
              characterRemoved(data as CommandCharacterRemoved);
              break;
            case Commands.characterUpdated:
              characterUpdated(data as CommandCharacterUpdated);
              break;
            case Commands.presentCharacters:
              presentCharacters(data as CommandPresentCharacters);
              break;
            case Commands.updateConnection:
              updateConnection(data as CommandUpdateConnection);
              break;
            case Commands.mapUpdated:
              mapUpdated(data as CommandMapUpdated);
              break;
            case Commands.killsUpdated:
              killsUpdated(data as CommandKillsUpdated);
              break;

            case Commands.centerSystem:
              setTimeout(() => {
                centerSystem(data as CommandCenterSystem);
              }, 100);
              break;

            case Commands.selectSystem:
              setTimeout(() => {
                const systemId = data as CommandSelectSystem;
                if (systemId) {
                  selectRef.current.onSelectionChange({
                    systems: [systemId],
                    connections: [],
                  });
                  selectSystem(systemId);
                }
              }, 500);
              break;

            case Commands.show_activity:
              update(state => ({ ...state, showCharacterActivity: true }));
              break;

            case Commands.update_activity:
              update(state => ({
                ...state,
                characterActivityData: (data as CommandUpdateActivity).activity,
                showCharacterActivity: true,
              }));
              break;

            case Commands.show_tracking:
              update(state => ({ ...state, showTrackAndFollow: true }));
              outCommand({
                type: OutCommand.refreshCharacters,
                data: {} as CommandEmptyData,
              });
              break;

            case Commands.update_tracking:
              update(state => ({
                ...state,
                trackingCharactersData: (data as CommandUpdateTracking).characters,
                showTrackAndFollow: true,
              }));
              break;

            case Commands.hide_tracking:
              update(state => ({ ...state, showTrackAndFollow: false }));
              break;

            case Commands.refresh_characters:
              outCommand({
                type: OutCommand.refreshCharacters,
                data: {} as CommandEmptyData,
              });
              break;

            case Commands.routes:
              // do nothing here
              break;

            case Commands.signaturesUpdated:
              // do nothing here
              break;

            case Commands.linkSignatureToSystem:
              // do nothing here
              break;

            case Commands.detailedKillsUpdated:
              // do nothing here
              break;

            default:
              console.warn(`Map handlers: Unknown command: ${type}`, data);
              break;
          }
        },
      };
    },
    [
      mapInit,
      mapAddSystems,
      mapUpdateSystems,
      removeSystems,
      addConnections,
      removeConnections,
      charactersUpdated,
      characterAdded,
      characterRemoved,
      characterUpdated,
      presentCharacters,
      updateConnection,
      mapUpdated,
      killsUpdated,
      centerSystem,
      selectSystem,
      update,
      outCommand,
    ],
  );
};
