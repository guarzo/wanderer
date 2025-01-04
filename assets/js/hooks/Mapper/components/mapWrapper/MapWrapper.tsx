import { Map } from '@/hooks/Mapper/components/map/Map.tsx';
import { useCallback, useRef, useState } from 'react';
import { OutCommand, OutCommandHandler, SolarSystemConnection } from '@/hooks/Mapper/types';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OnMapAddSystemCallback, OnMapSelectionChange } from '@/hooks/Mapper/components/map/map.types.ts';
import isEqual from 'lodash.isequal';
import { ContextMenuSystem, useContextMenuSystemHandlers } from '@/hooks/Mapper/components/contexts';
import {
  SystemCustomLabelDialog,
  SystemLinkSignatureDialog,
  SystemSettingsDialog,
} from '@/hooks/Mapper/components/mapInterface/components';
import classes from './MapWrapper.module.scss';
import { Connections } from '@/hooks/Mapper/components/mapRootContent/components/Connections';
import { ContextMenuSystemMultiple, useContextMenuSystemMultipleHandlers } from '../contexts/ContextMenuSystemMultiple';
import { getSystemById } from '@/hooks/Mapper/helpers';
import { Node, XYPosition } from 'reactflow';

import { Commands } from '@/hooks/Mapper/types/mapHandlers.ts';
import { emitMapEvent, useMapEventListener } from '@/hooks/Mapper/events';

import { STORED_INTERFACE_DEFAULT_VALUES } from '@/hooks/Mapper/mapRootProvider/MapRootProvider';
import { useDeleteSystems } from '@/hooks/Mapper/components/contexts/hooks';
import { useCommonMapEventProcessor } from '@/hooks/Mapper/components/mapWrapper/hooks/useCommonMapEventProcessor.ts';
import {
  AddSystemDialog,
  SearchOnSubmitCallback,
} from '@/hooks/Mapper/components/mapInterface/components/AddSystemDialog';

// TODO: INFO - this component needs for abstract work with Map instance
export const MapWrapper = () => {
  const {
    update,
    outCommand,
    data: { selectedConnections, selectedSystems, hubs, systems },
    interfaceSettings: {
      isShowMenu,
      isShowMinimap = STORED_INTERFACE_DEFAULT_VALUES.isShowMinimap,
      isShowKSpace,
      isThickConnections,
      isShowBackgroundPattern,
      isSoftBackground,
    },
  } = useMapRootState();
  const { deleteSystems } = useDeleteSystems();
  const { mapRef, runCommand } = useCommonMapEventProcessor();

  const { open, ...systemContextProps } = useContextMenuSystemHandlers({ systems, hubs, outCommand });
  const { handleSystemMultipleContext, ...systemMultipleCtxProps } = useContextMenuSystemMultipleHandlers();

  const [openSettings, setOpenSettings] = useState<string | null>(null);
  const [openLinkSignatures, setOpenLinkSignatures] = useState<any | null>(null);
  const [openCustomLabel, setOpenCustomLabel] = useState<string | null>(null);
  const [openAddSystem, setOpenAddSystem] = useState<XYPosition | null>(null);
  const [selectedConnection, setSelectedConnection] = useState<SolarSystemConnection | null>(null);

  const ref = useRef({ selectedConnections, selectedSystems, systemContextProps, systems, deleteSystems });
  ref.current = { selectedConnections, selectedSystems, systemContextProps, systems, deleteSystems };

  useMapEventListener(event => {
    switch (event.name) {
      case Commands.linkSignatureToSystem:
        setOpenLinkSignatures(event.data);
        return true;
    }

    runCommand(event);
  });


  const onSelectionChange: OnMapSelectionChange = useCallback(
    ({ systems, connections }) => {
      console.log("=== onSelectionChange triggered ===");
      console.log("New incoming:", { systems, connections });

      const { selectedSystems, selectedConnections } = ref.current;
      console.log("Old existing (ref):", {
        selectedSystems,
        selectedConnections,
      });

      //
      // 1) Figure out the *new* systems array we intend to store
      //
      let newSystems = selectedSystems;

      if (!isEqual(systems, selectedSystems)) {
        // If 'systems' is non-empty, we adopt it directly
        if (systems && systems.length > 0) {
          console.log("Systems are non-empty and changed -> adopting them.");
          newSystems = systems;
        } else {
          // If new systems is empty:
          //  - If the old array had multiple items, force clear to empty
          //  - Otherwise, keep old array (or you can decide to forcibly empty it)
          if (selectedSystems.length > 1) {
            console.log(
              "New systems is empty but old had multiple -> forcibly clearing to []."
            );
            newSystems = [];
          } else {
            console.log(
              "New systems is empty; old had <= 1 item -> not changing it."
            );
          }
        }
      }

      //
      // 2) Figure out the *new* connections array we intend to store
      //
      let newConnections = selectedConnections;

      if (!isEqual(connections, selectedConnections)) {
        // If 'connections' is non-empty, adopt it
        if (connections && connections.length > 0) {
          console.log("Connections are non-empty and changed -> adopting them.");
          newConnections = connections;
        } else {
          // If new connections is empty:
          if (selectedConnections.length > 0) {
            console.log(
              "New connections empty but old had items -> clearing to []."
            );
            newConnections = [];
          } else {
            console.log(
              "New connections empty; old was also empty -> not changing it."
            );
          }
        }
      }


      const systemsDidChange = !isEqual(newSystems, selectedSystems);
      const connectionsDidChange = !isEqual(newConnections, selectedConnections);

      if (systemsDidChange || connectionsDidChange) {
        console.log("Changes detected -> calling update().");
        update({
          selectedSystems: newSystems,
          selectedConnections: newConnections,
        });
      } else {
        console.log(
          "No final changes in systems or connections -> skipping update()."
        );
      }
    },
    [update],
  );

  const handleCommand: OutCommandHandler = useCallback(
    event => {
      switch (event.type) {
        case OutCommand.openSettings:
          setOpenSettings(event.data.system_id);
          break;
        case OutCommand.linkSignatureToSystem:
          setOpenLinkSignatures(event.data);
          break;
        default:
          return outCommand(event);
      }
      // @ts-ignore
      return new Promise(resolve => resolve(null));
    },
    [outCommand],
  );

  const handleSystemContextMenu = useCallback(
    (ev: any, systemId: string) => {
      const { selectedSystems, systems } = ref.current;
      if (selectedSystems.length > 1) {
        const systemsInfo: Node[] = selectedSystems.map(x => ({ data: getSystemById(systems, x), id: x }) as Node);

        handleSystemMultipleContext(ev, systemsInfo);
        return;
      }

      open(ev, systemId);
    },
    [open],
  );

  const handleConnectionDbClick = useCallback((e: SolarSystemConnection) => setSelectedConnection(e), []);

  const handleManualDelete = useCallback((toDelete: string[]) => {
    const restDel = toDelete.filter(x => ref.current.systems.some(y => y.id === x));
    if (restDel.length > 0) {
      ref.current.deleteSystems(restDel);
    }
  }, []);

  const onAddSystem: OnMapAddSystemCallback = useCallback(({ coordinates }) => {
    setOpenAddSystem(coordinates);
  }, []);

  const handleSubmitAddSystem: SearchOnSubmitCallback = useCallback(
    async item => {
      if (ref.current.systems.some(x => x.system_static_info.solar_system_id === item.value)) {
        emitMapEvent({
          name: Commands.centerSystem,
          data: item.value.toString(),
        });
        return;
      }

      await outCommand({
        type: OutCommand.manualAddSystem,
        data: { coordinates: openAddSystem, solar_system_id: item.value },
      });
    },
    [openAddSystem, outCommand],
  );

  return (
    <>
      <Map
        ref={mapRef}
        onCommand={handleCommand}
        onSelectionChange={onSelectionChange}
        onConnectionInfoClick={handleConnectionDbClick}
        onSystemContextMenu={handleSystemContextMenu}
        onSelectionContextMenu={handleSystemMultipleContext}
        minimapClasses={!isShowMenu ? classes.MiniMap : undefined}
        isShowMinimap={isShowMinimap}
        showKSpaceBG={isShowKSpace}
        onManualDelete={handleManualDelete}
        isThickConnections={isThickConnections}
        isShowBackgroundPattern={isShowBackgroundPattern}
        isSoftBackground={isSoftBackground}
        onAddSystem={onAddSystem}
      />

      {openSettings != null && (
        <SystemSettingsDialog systemId={openSettings} visible setVisible={() => setOpenSettings(null)} />
      )}

      {openCustomLabel != null && (
        <SystemCustomLabelDialog systemId={openCustomLabel} visible setVisible={() => setOpenCustomLabel(null)} />
      )}

      {openLinkSignatures != null && (
        <SystemLinkSignatureDialog data={openLinkSignatures} setVisible={() => setOpenLinkSignatures(null)} />
      )}

      <AddSystemDialog
        visible={!!openAddSystem}
        setVisible={() => setOpenAddSystem(null)}
        onSubmit={handleSubmitAddSystem}
      />

      <Connections selectedConnection={selectedConnection} onHide={() => setSelectedConnection(null)} />

      <ContextMenuSystem
        systems={systems}
        hubs={hubs}
        {...systemContextProps}
        onOpenSettings={() => {
          systemContextProps.systemId && setOpenSettings(systemContextProps.systemId);
        }}
        onCustomLabelDialog={() => {
          const { systemContextProps } = ref.current;
          systemContextProps.systemId && setOpenCustomLabel(systemContextProps.systemId);
        }}
      />

      <ContextMenuSystemMultiple {...systemMultipleCtxProps} />
    </>
  );
};
