import { Edge, EdgeMouseHandler } from 'reactflow';
import { useCallback, useRef, useState } from 'react';
import { ContextMenu } from 'primereact/contextmenu';
import { useMapState } from '../../MapProvider.tsx';
import { OutCommand } from '@/hooks/Mapper/types/mapHandlers.ts';
import { ConnectionType, MassState, ShipSizeStatus, SolarSystemConnection, TimeStatus } from '@/hooks/Mapper/types';
import { ctxManager } from '@/hooks/Mapper/utils/contextManager.ts';

export const useContextMenuConnectionHandlers = () => {
  const contextMenuRef = useRef<ContextMenu | null>(null);
  const { outCommand } = useMapState();
  const [edge, setEdge] = useState<Edge<SolarSystemConnection>>();

  const ref = useRef({ edge, outCommand });
  ref.current = { edge, outCommand };

  const handleConnectionContext: EdgeMouseHandler = (ev, edge_) => {
    setEdge(edge_);
    ev.preventDefault();
    ctxManager.next('ctxConn', contextMenuRef.current);
    contextMenuRef.current?.show(ev);
  };

  const onDeleteConnection = () => {
    if (!edge) {
      return;
    }

    outCommand({ type: OutCommand.manualDeleteConnection, data: { source: edge.source, target: edge.target } });
    setEdge(undefined);
  };

  const onChangeTimeState = (status?: TimeStatus) => {
    if (!edge || !edge.data) {
      return;
    }

    // Use provided status, or toggle between default and eol_4hr for backwards compatibility
    let newStatus = status;
    if (newStatus === undefined) {
      newStatus = edge.data.time_status === TimeStatus.default ? TimeStatus.eol_4hr : TimeStatus.default;
    }

    outCommand({
      type: OutCommand.updateConnectionTimeStatus,
      data: {
        source: edge.source,
        target: edge.target,
        value: newStatus,
      },
    });
    setEdge(undefined);
  };

  const onChangeType = useCallback((type: ConnectionType) => {
    const { edge, outCommand } = ref.current;

    if (!edge) {
      return;
    }

    outCommand({
      type: OutCommand.updateConnectionType,
      data: {
        source: edge.source,
        target: edge.target,
        value: type,
      },
    });
  }, []);

  const onChangeMassState = useCallback((status: MassState) => {
    const { edge, outCommand } = ref.current;

    if (!edge) {
      return;
    }

    outCommand({
      type: OutCommand.updateConnectionMassStatus,
      data: {
        source: edge.source,
        target: edge.target,
        value: status,
      },
    });
  }, []);

  const onChangeShipSizeStatus = useCallback((status: ShipSizeStatus) => {
    const { edge, outCommand } = ref.current;

    if (!edge) {
      return;
    }

    outCommand({
      type: OutCommand.updateConnectionShipSizeType,
      data: {
        source: edge.source,
        target: edge.target,
        value: status,
      },
    });

    if (status === ShipSizeStatus.small) {
      outCommand({
        type: OutCommand.updateConnectionMassStatus,
        data: {
          source: edge.source,
          target: edge.target,
          value: MassState.normal,
        },
      });
    }
  }, []);

  const onToggleMassSave = useCallback((locked: boolean) => {
    const { edge, outCommand } = ref.current;

    if (!edge) {
      return;
    }

    outCommand({
      type: OutCommand.updateConnectionLocked,
      data: {
        source: edge.source,
        target: edge.target,
        value: locked,
      },
    });
  }, []);

  const onToggleLoop = useCallback(() => {
    const { edge, outCommand } = ref.current;

    if (!edge || !edge.data) {
      return;
    }

    const newType = edge.data.type === ConnectionType.loop ? ConnectionType.wormhole : ConnectionType.loop;

    outCommand({
      type: OutCommand.updateConnectionType,
      data: {
        source: edge.source,
        target: edge.target,
        value: newType,
      },
    });
  }, []);

  const onHide = useCallback(() => {
    setEdge(undefined);
  }, []);

  return {
    handleConnectionContext,
    edge,

    contextMenuRef,
    onDeleteConnection,
    onChangeTimeState,
    onChangeType,
    onChangeMassState,
    onChangeShipSizeStatus,
    onToggleMassSave,
    onToggleLoop,
    onHide,
  };
};
