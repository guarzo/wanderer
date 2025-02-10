import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { WdTooltip, WdTooltipHandlers } from '@/hooks/Mapper/components/ui-kit';
import {
  getGroupIdByRawGroup,
  GROUPS_LIST,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { DataTable, DataTableRowClickEvent, DataTableRowMouseEvent, SortOrder } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { getActualSigs, getRowColorByTimeLeft } from '../helpers';
import useRefState from 'react-usestateref';
import { Setting } from '../SystemSignatureSettingsDialog';
import { useHotkey } from '@/hooks/Mapper/hooks';
import useMaxWidth from '@/hooks/Mapper/hooks/useMaxWidth';
import { useClipboard } from '@/hooks/Mapper/hooks/useClipboard';
import clsx from 'clsx';
import classes from './SystemSignaturesContent.module.scss';
import { SystemSignature } from '@/hooks/Mapper/types';
import { SignatureView } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/SignatureView';
import {
  renderAddedTimeLeft,
  renderDescription,
  renderIcon,
  renderInfoColumn,
  renderUpdatedTimeLeft,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/renders';
import useLocalStorageState from 'use-local-storage-state';
import { PrimeIcons } from 'primereact/api';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { WdTooltipWrapper } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper';
import { COSMIC_SIGNATURE } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/SystemSignatureSettingsDialog';
import {
  SHOW_DESCRIPTION_COLUMN_SETTING,
  SHOW_UPDATED_COLUMN_SETTING,
  LAZY_DELETE_SIGNATURES_SETTING,
  KEEP_LAZY_DELETE_SETTING,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures';
import { parseSignatures } from '@/hooks/Mapper/helpers';
import { SignatureSettings } from '@/hooks/Mapper/components/mapRootContent/components/SignatureSettings';

import {
  ExtendedSystemSignature,
  PendingChange,
  FLASH_DURATION_MS,
  FINAL_DURATION_MS,
  prepareUpdatePayload,
  scheduleLazyDeletionTimers,
  mergeWithPendingFlags,
  getRowClassName,
} from '../helpers/contentHelpers';

type SystemSignaturesSortSettings = {
  sortField: string;
  sortOrder: SortOrder;
};

const SORT_DEFAULT_VALUES: SystemSignaturesSortSettings = {
  sortField: 'inserted_at',
  sortOrder: -1,
};

interface SystemSignaturesContentProps {
  systemId: string;
  settings: Setting[];
  hideLinkedSignatures?: boolean;
  selectable?: boolean;
  onSelect?: (signature: SystemSignature) => void;
  onLazyDeleteChange?: (value: boolean) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
  onCountChange: (count: number) => void;
}

export const SystemSignaturesContent = ({
  systemId,
  settings,
  hideLinkedSignatures,
  selectable,
  onSelect,
  onLazyDeleteChange,
  onPendingChange,
  onCountChange,
}: SystemSignaturesContentProps) => {
  const { outCommand } = useMapRootState();

  const [signatures, setSignatures, signaturesRef] = useRefState<ExtendedSystemSignature[]>([]);
  const [selectedSignatures, setSelectedSignatures] = useState<ExtendedSystemSignature[]>([]);
  const [nameColumnWidth, setNameColumnWidth] = useState('auto');
  const [selectedSignature, setSelectedSignature] = useState<SystemSignature | null>(null);
  const [hoveredSig, setHoveredSig] = useState<SystemSignature | null>(null);

  const [sortSettings, setSortSettings] = useLocalStorageState<SystemSignaturesSortSettings>('window:signatures:sort', {
    defaultValue: SORT_DEFAULT_VALUES,
  });

  const tableRef = useRef<HTMLDivElement>(null);
  const tooltipRef = useRef<WdTooltipHandlers>(null);

  const compact = useMaxWidth(tableRef, 260);
  const medium = useMaxWidth(tableRef, 380);

  const { clipboardContent, setClipboardContent } = useClipboard();

  const lazyDeleteValue = useMemo(
    () => settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false,
    [settings],
  );
  const keepLazyDeleteValue = useMemo(
    () => settings.find(s => s.key === KEEP_LAZY_DELETE_SETTING)?.value ?? false,
    [settings],
  );

  const [pendingDeletionMap, setPendingDeletionMap] = useState<
    Record<
      string,
      {
        flashUntil: number;
        finalUntil: number;
        flashTimeoutId: number;
        finalTimeoutId: number;
      }
    >
  >({});

  const [pendingChanges, setPendingChanges] = useState<PendingChange[]>([]);

  const removeSignaturePermanently = useCallback(
    async (sig: ExtendedSystemSignature) => {
      await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, [], [], [sig]),
      });
      setPendingChanges(prev => prev.filter(p => p.eve_id !== sig.eve_id));
    },
    [outCommand, systemId, setPendingChanges],
  );

  const handleLazyDelete = useCallback(
    async (removed: ExtendedSystemSignature[], newServerSigs: ExtendedSystemSignature[]) => {
      const removedPending = removed.map(r => ({ ...r, action: 'delete' }) as PendingChange);
      setPendingChanges(prev => [...prev, ...removedPending]);

      scheduleLazyDeletionTimers(
        removed,
        setPendingDeletionMap,
        removeSignaturePermanently,
        setSignatures,
        FLASH_DURATION_MS,
        FINAL_DURATION_MS,
      );

      const now = Date.now();
      const merged = newServerSigs.map(sig =>
        removed.some(r => r.eve_id === sig.eve_id)
          ? { ...sig, pendingDeletion: true, pendingUntil: now + FLASH_DURATION_MS }
          : sig,
      );

      const onlyRemovedPending = removed
        .map(r => ({ ...r, pendingDeletion: true, pendingUntil: now + FLASH_DURATION_MS }))
        .filter(r => !merged.some(m => m.eve_id === r.eve_id));

      setSignatures([...merged, ...onlyRemovedPending]);
    },
    [removeSignaturePermanently, setSignatures, setPendingDeletionMap, setPendingChanges],
  );

  const undoAllPending = useCallback(async () => {
    Object.values(pendingDeletionMap).forEach(({ flashTimeoutId, finalTimeoutId }) => {
      clearTimeout(flashTimeoutId);
      clearTimeout(finalTimeoutId);
    });

    setSignatures(prev => {
      const map = new Map<string, ExtendedSystemSignature>();
      prev.forEach(sig => {
        if (pendingDeletionMap[sig.eve_id]) {
          map.set(sig.eve_id, {
            ...sig,
            pendingDeletion: false,
            pendingUntil: undefined,
          });
        } else {
          map.set(sig.eve_id, sig);
        }
      });
      return Array.from(map.values());
    });

    const additionsToRemove = pendingChanges.filter(pc => pc.action === 'add');
    if (additionsToRemove.length > 0) {
      await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, [], [], additionsToRemove),
      });
      setSignatures(prev => prev.filter(sig => !additionsToRemove.some(a => a.eve_id === sig.eve_id)));
    }

    setPendingDeletionMap({});
    setPendingChanges([]);
  }, [outCommand, systemId, pendingDeletionMap, pendingChanges, setSignatures]);

  useEffect(() => {
    onPendingChange?.(pendingChanges, undoAllPending);
  }, [pendingChanges, onPendingChange, undoAllPending]);

  useEffect(() => {
    onCountChange(signatures.length);
  }, [signatures, onCountChange]);

  const handleResize = useCallback(() => {
    if (tableRef.current) {
      const tableWidth = tableRef.current.offsetWidth;
      const otherColumnsWidth = 276;
      setNameColumnWidth(`${tableWidth - otherColumnsWidth}px`);
    }
  }, []);

  const groupSettings = useMemo(() => settings.filter(s => (GROUPS_LIST as string[]).includes(s.key)), [settings]);
  const showDescriptionColumn = useMemo(
    () => settings.find(s => s.key === SHOW_DESCRIPTION_COLUMN_SETTING)?.value,
    [settings],
  );
  const showUpdatedColumn = useMemo(() => settings.find(s => s.key === SHOW_UPDATED_COLUMN_SETTING)?.value, [settings]);

  const handleGetSignatures = useCallback(async () => {
    if (!systemId) {
      setSignatures([]);
      return;
    }
    const { signatures: serverSignatures } = await outCommand({
      type: OutCommand.getSignatures,
      data: { system_id: systemId },
    });

    let extendedServer = (serverSignatures as SystemSignature[]).map(sig => ({
      ...sig,
      pendingDeletion: false,
    })) as ExtendedSystemSignature[];

    if (lazyDeleteValue) {
      extendedServer = mergeWithPendingFlags(extendedServer, signaturesRef.current);
    }
    setSignatures(extendedServer);
  }, [systemId, outCommand, lazyDeleteValue, signaturesRef, setSignatures]);

  const handleUpdateSignatures = useCallback(
    async (newSignatures: ExtendedSystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );

      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, removed),
      });

      const merged = (resp.signatures as SystemSignature[]).map(sig => ({
        ...sig,
        pendingDeletion: false,
      })) as ExtendedSystemSignature[];

      setSignatures(merged);
      setSelectedSignatures([]);
    },
    [outCommand, systemId, signaturesRef, setSignatures],
  );

  const handleDeleteSelected = useCallback(
    async (e: KeyboardEvent) => {
      if (selectable || selectedSignatures.length === 0) return;
      e.preventDefault();
      e.stopPropagation();

      const selectedIds = selectedSignatures.map(x => x.eve_id);
      await handleUpdateSignatures(
        signatures.filter(x => !selectedIds.includes(x.eve_id)),
        false,
        true,
      );
    },
    [handleUpdateSignatures, selectable, signatures, selectedSignatures],
  );

  const handleSelectAll = useCallback(() => {
    setSelectedSignatures(signatures);
  }, [signatures]);

  const handleSelectSignatures = useCallback(
    (e: { value: ExtendedSystemSignature[] }) => {
      if (selectable) {
        onSelect?.(e.value[0]);
      } else {
        setSelectedSignatures(e.value);
      }
    },
    [onSelect, selectable],
  );

  const handlePaste = useCallback(
    async (clipboardText: string) => {
      const parsed = parseSignatures(
        clipboardText,
        settings.map(x => x.key),
      ).map(sig => ({ ...sig, pendingDeletion: false })) as ExtendedSystemSignature[];

      if (parsed.length === 0) {
        return;
      }

      if (lazyDeleteValue) {
        const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion);
        const { added, updated, removed } = getActualSigs(currentNonPending, parsed, false, true);

        const resp = await outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, added, updated, []),
        });
        const updatedFromServer = (resp.signatures as SystemSignature[]).map(srv => ({
          ...srv,
          pendingDeletion: false,
        })) as ExtendedSystemSignature[];

        if (added.length > 0) {
          const additions = added.map(a => ({ ...a, action: 'add' }) as PendingChange);
          setPendingChanges(prev => [...prev, ...additions]);
        }

        if (removed.length > 0) {
          await handleLazyDelete(removed, updatedFromServer);
        } else {
          setSignatures(updatedFromServer);
        }

        if (!keepLazyDeleteValue) {
          onLazyDeleteChange?.(false);
        }
      } else {
        const { added, updated, removed } = getActualSigs(signaturesRef.current, parsed, true);
        const resp = await outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, added, updated, removed),
        });
        const updatedFromServer = (resp.signatures as SystemSignature[]).map(srv => ({
          ...srv,
          pendingDeletion: false,
        })) as ExtendedSystemSignature[];

        if (added.length > 0) {
          const additions = added.map(a => ({ ...a, action: 'add' }) as PendingChange);
          setPendingChanges(prev => [...prev, ...additions]);
        }
        setSignatures(updatedFromServer);
      }
    },
    [
      settings,
      lazyDeleteValue,
      signaturesRef,
      outCommand,
      systemId,
      keepLazyDeleteValue,
      handleLazyDelete,
      setSignatures,
      onLazyDeleteChange,
      setPendingChanges,
    ],
  );

  useEffect(() => {
    if (selectable) return;
    if (!clipboardContent?.text) return;
    handlePaste(clipboardContent.text);
    setClipboardContent(null);
  }, [clipboardContent, selectable, handlePaste, setClipboardContent]);

  useHotkey(true, ['a'], handleSelectAll);
  useHotkey(false, ['Backspace', 'Delete'], handleDeleteSelected);

  useEffect(() => {
    handleGetSignatures();
  }, [systemId, handleGetSignatures]);

  useMapEventListener(event => {
    if (event.name === Commands.signaturesUpdated && event.data?.toString() === systemId.toString()) {
      handleGetSignatures();
      return true;
    }
  });

  useEffect(() => {
    const observer = new ResizeObserver(handleResize);
    if (tableRef.current) observer.observe(tableRef.current);
    handleResize();
    return () => {
      if (tableRef.current) observer.unobserve(tableRef.current);
    };
  }, [handleResize]);

  const renderToolbar = () => (
    <div className="flex justify-end items-center gap-2 mr-[4px]">
      <WdTooltipWrapper content="To Edit Signature do double click">
        <span className={clsx(PrimeIcons.PENCIL, 'text-[10px]')}></span>
      </WdTooltipWrapper>
    </div>
  );

  const filteredSignatures = useMemo(() => {
    return signatures
      .filter(x => {
        if (hideLinkedSignatures && !!x.linked_system) return false;
        const isCosmicSignature = x.kind === COSMIC_SIGNATURE;
        const preparedGroup = getGroupIdByRawGroup(x.group);
        if (isCosmicSignature) {
          const showCosmicSignatures = settings.find(y => y.key === COSMIC_SIGNATURE)?.value;
          return showCosmicSignatures
            ? !x.group || groupSettings.find(y => y.key === preparedGroup)?.value
            : !!x.group && groupSettings.find(y => y.key === preparedGroup)?.value;
        }
        return settings.find(y => y.key === x.kind)?.value;
      })
      .sort((a, b) => new Date(b.updated_at || 0).getTime() - new Date(a.updated_at || 0).getTime());
  }, [signatures, settings, groupSettings, hideLinkedSignatures]);

  const [showSignatureSettings, setShowSignatureSettings] = useState(false);
  const handleRowClick = (e: DataTableRowClickEvent) => {
    setSelectedSignature(e.data as SystemSignature);
    setShowSignatureSettings(true);
  };

  return (
    <div ref={tableRef} className="h-full">
      {filteredSignatures.length === 0 ? (
        <div className="w-full h-full flex justify-center items-center select-none text-stone-400/80 text-sm">
          No signatures
        </div>
      ) : (
        <DataTable
          className={classes.Table}
          value={filteredSignatures}
          size="small"
          selectionMode="multiple"
          selection={selectedSignatures}
          metaKeySelection
          onSelectionChange={handleSelectSignatures}
          dataKey="eve_id"
          tableClassName="w-full select-none"
          resizableColumns={false}
          onRowDoubleClick={handleRowClick}
          rowHover
          selectAll
          sortField={sortSettings.sortField}
          sortOrder={sortSettings.sortOrder}
          onSort={event => setSortSettings({ sortField: event.sortField, sortOrder: event.sortOrder })}
          onRowMouseEnter={
            compact || medium
              ? (e: DataTableRowMouseEvent) => {
                  setHoveredSig(filteredSignatures[e.index]);
                  tooltipRef.current?.show(e.originalEvent);
                }
              : undefined
          }
          onRowMouseLeave={
            compact || medium
              ? () => {
                  tooltipRef.current?.hide();
                  setHoveredSig(null);
                }
              : undefined
          }
          rowClassName={row =>
            getRowClassName(
              row,
              pendingDeletionMap,
              selectedSignatures.map(s => s.eve_id),
              getRowColorByTimeLeft,
            )
          }
        >
          <Column
            bodyClassName="p-0 px-1"
            field="group"
            body={x => renderIcon(x)}
            style={{ maxWidth: 26, minWidth: 26, width: 26, height: 25 }}
          />
          <Column
            field="eve_id"
            header="Id"
            bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
            style={{ maxWidth: 72, minWidth: 72, width: 72 }}
            sortable
          />
          <Column
            field="group"
            header="Group"
            bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
            hidden={compact}
            style={{ maxWidth: 110, minWidth: 110, width: 110 }}
            sortable
          />
          <Column
            field="info"
            bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
            body={renderInfoColumn}
            style={{ maxWidth: nameColumnWidth }}
            hidden={compact || medium}
          />
          {showDescriptionColumn && (
            <Column
              field="description"
              header="Description"
              bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
              body={renderDescription}
              hidden={compact}
              sortable
            />
          )}
          <Column
            field="inserted_at"
            header="Added"
            dataType="date"
            bodyClassName="w-[70px] text-ellipsis overflow-hidden whitespace-nowrap"
            body={renderAddedTimeLeft}
            sortable
          />
          {showUpdatedColumn && (
            <Column
              field="updated_at"
              header="Updated"
              dataType="date"
              bodyClassName="w-[70px] text-ellipsis overflow-hidden whitespace-nowrap"
              body={renderUpdatedTimeLeft}
              sortable
            />
          )}
          {!selectable && (
            <Column
              bodyClassName="p-0 pl-1 pr-2"
              field="group"
              body={renderToolbar}
              style={{ maxWidth: 26, minWidth: 26, width: 26 }}
            />
          )}
        </DataTable>
      )}

      <WdTooltip
        className="bg-stone-900/95 text-slate-50"
        ref={tooltipRef}
        content={hoveredSig ? <SignatureView {...hoveredSig} /> : null}
      />

      {showSignatureSettings && (
        <SignatureSettings
          systemId={systemId}
          show
          onHide={() => setShowSignatureSettings(false)}
          signatureData={selectedSignature}
        />
      )}
    </div>
  );
};
