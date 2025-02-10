import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { parseSignatures, getActualSigs } from '../helpers/zooSignatures';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { WdTooltip, WdTooltipHandlers } from '@/hooks/Mapper/components/ui-kit';
import {
  getGroupIdByRawGroup,
  GROUPS_LIST,
  TIME_ONE_DAY,
  TIME_ONE_WEEK,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { DataTable, DataTableRowClickEvent, DataTableRowMouseEvent, SortOrder } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import useRefState from 'react-usestateref';
import { Setting } from '../SystemSignatureSettingsDialog';
import { useHotkey } from '@/hooks/Mapper/hooks';
import useMaxWidth from '@/hooks/Mapper/hooks/useMaxWidth';
import { useClipboard } from '@/hooks/Mapper/hooks/useClipboard';
import clsx from 'clsx';
import classes from './SystemSignaturesContent.module.scss';
import { SystemSignature, SignatureGroup } from '@/hooks/Mapper/types';
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
import { SignatureSettings } from '@/hooks/Mapper/components/mapRootContent/components/SignatureSettings';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { WdTooltipWrapper } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper';
import { COSMIC_SIGNATURE } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/SystemSignatureSettingsDialog';
import {
  SHOW_DESCRIPTION_COLUMN_SETTING,
  SHOW_UPDATED_COLUMN_SETTING,
  LAZY_DELETE_SIGNATURES_SETTING,
  KEEP_LAZY_DELETE_SETTING,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures';

import {
  ExtendedSystemSignature,
  FLASH_DURATION_MS,
  FINAL_DURATION_MS,
  scheduleLazyDeletionTimers,
  prepareUpdatePayload,
  mergeWithPendingFlags,
  getRowClassName,
} from '../helpers/contentHelpers';
import { getRowColorByTimeLeft } from '../helpers';

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
  onCountChange: (count: number) => void;
  /**
   * If parent wants to show an "undo" button for lazy deletions, we call
   *   onPendingChange(pendingUndoSignatures, undoPendingDeletions)
   */
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
}

export const SystemSignaturesContent = ({
  systemId,
  settings,
  hideLinkedSignatures,
  selectable,
  onSelect,
  onLazyDeleteChange,
  onCountChange,
  onPendingChange,
}: SystemSignaturesContentProps) => {
  const { outCommand } = useMapRootState();

  // Our list of extended signatures in the UI
  const [signatures, setSignatures, signaturesRef] = useRefState<ExtendedSystemSignature[]>([]);
  // DataTable selection
  const [selectedSignatures, setSelectedSignatures] = useState<ExtendedSystemSignature[]>([]);
  // For dynamic name column sizing
  const [nameColumnWidth, setNameColumnWidth] = useState('auto');

  // For editing a signature in the "SignatureSettings" dialog
  const [selectedSignature, setSelectedSignature] = useState<SystemSignature | null>(null);
  // For the hovered row tooltip
  const [hoveredSig, setHoveredSig] = useState<SystemSignature | null>(null);

  // Sorting info from local storage
  const [sortSettings, setSortSettings] = useLocalStorageState<SystemSignaturesSortSettings>('window:signatures:sort', {
    defaultValue: SORT_DEFAULT_VALUES,
  });

  // Refs for layout & tooltips
  const tableRef = useRef<HTMLDivElement>(null);
  const tooltipRef = useRef<WdTooltipHandlers>(null);

  // For column hiding in small screens
  const compact = useMaxWidth(tableRef, 260);
  const medium = useMaxWidth(tableRef, 380);

  // Because user can toggle "selectable" at runtime
  const refData = useRef({ selectable });
  refData.current = { selectable };

  // Clipboard
  const { clipboardContent, setClipboardContent } = useClipboard();

  // Lazy delete settings
  const lazyDeleteValue = useMemo(
    () => settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false,
    [settings],
  );
  const keepLazyDeleteValue = useMemo(
    () => settings.find(s => s.key === KEEP_LAZY_DELETE_SETTING)?.value ?? false,
    [settings],
  );

  // track how many total signatures we have
  useEffect(() => {
    onCountChange(signatures.length);
  }, [signatures, onCountChange]);

  /**
   * This map tracks each signature that is in "pending deletion," along with
   * its flashUntil/finalUntil times.
   */
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

  /**
   * All signatures that have recently been removed but can still be undone
   */
  const [pendingUndoSignatures, setPendingUndoSignatures] = useState<ExtendedSystemSignature[]>([]);

  /**
   * Called to fetch from the server. If lazy delete is on, we "mergeWithPendingFlags"
   * so that things still pending remain highlighted for possible undo.
   */
  const handleGetSignatures = useCallback(async () => {
    if (!systemId) {
      setSignatures([]);
      return;
    }
    const { signatures: serverSignatures } = await outCommand({
      type: OutCommand.getSignatures,
      data: { system_id: systemId },
    });

    let extendedServer = (serverSignatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];

    if (lazyDeleteValue) {
      extendedServer = mergeWithPendingFlags(extendedServer, signaturesRef.current);
    }
    setSignatures(extendedServer);
  }, [systemId, outCommand, lazyDeleteValue, signaturesRef, setSignatures]);

  /**
   * Called whenever we do a normal "update" (non-lazy).
   */
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

      const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      setSignatures(castedUpdated);
      setSelectedSignatures([]);
    },
    [systemId, outCommand, signaturesRef, setSignatures],
  );

  /**
   * If user hits "delete" hotkey while some rows are selected, do a normal remove
   */
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
    [handleUpdateSignatures, selectable, selectedSignatures, signatures],
  );

  // "select all" key
  const handleSelectAll = useCallback(() => {
    setSelectedSignatures(signatures);
  }, [signatures]);

  // table selection
  const handleSelectSignatures = useCallback(
    (e: { value: ExtendedSystemSignature[] }) => {
      if (selectable) {
        onSelect?.(e.value[0]);
      } else {
        setSelectedSignatures(e.value);
      }
    },
    [selectable, onSelect],
  );

  /**
   * “Undo” everything in `pendingDeletionMap` or `pendingUndoSignatures`.
   */
  const undoPendingDeletions = useCallback(() => {
    // stop the scheduled timeouts
    Object.values(pendingDeletionMap).forEach(({ flashTimeoutId, finalTimeoutId }) => {
      clearTimeout(flashTimeoutId);
      clearTimeout(finalTimeoutId);
    });

    // revert all
    setSignatures(prev => {
      const existingIds = new Set(prev.map(sig => sig.eve_id));
      // if any were fully removed from the table, re-add them
      const toReAdd = pendingUndoSignatures.filter(sig => !existingIds.has(sig.eve_id));

      // revert the "pendingDeletion" on the ones that remain
      const updated = prev.map(sig =>
        pendingDeletionMap[sig.eve_id] ? { ...sig, pendingDeletion: false, pendingUntil: undefined } : sig,
      );

      return [...updated, ...toReAdd];
    });

    // clear out
    setPendingDeletionMap({});
    setPendingUndoSignatures([]);
  }, [pendingDeletionMap, pendingUndoSignatures, setSignatures]);

  /**
   * Whenever the list of "pendingUndoSignatures" changes, we inform the parent we can undo
   */
  useEffect(() => {
    onPendingChange?.(pendingUndoSignatures, undoPendingDeletions);
  }, [pendingUndoSignatures, onPendingChange, undoPendingDeletions]);

  /**
   * Called upon paste: parse any new signatures. If lazy delete is on, do partial updates for
   * "added"/"updated" and schedule lazy deletion for "removed."
   */
  const handlePaste = useCallback(
    async (clipboardString: string) => {
      const parsed = parseSignatures(
        clipboardString,
        settings.map(x => x.key),
      ).map(s => ({ ...s })) as ExtendedSystemSignature[];

      // if no valid signatures found, do nothing
      if (parsed.length === 0) {
        return;
      }

      if (lazyDeleteValue) {
        // handle partial cosmic duplicates (like you do)
        const filteredNew = parsed.filter(sig => {
          if (sig.kind === COSMIC_SIGNATURE && sig.eve_id.length === 3) {
            const prefix = sig.eve_id.substring(0, 3).toUpperCase();
            return !signaturesRef.current.some(
              existingSig =>
                existingSig.kind === COSMIC_SIGNATURE &&
                existingSig.eve_id.substring(0, 3).toUpperCase() === prefix &&
                existingSig.eve_id.length === 7,
            );
          }
          return true;
        });

        // compare with current "non-pending"
        const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion);
        const { added, updated, removed } = getActualSigs(currentNonPending, filteredNew, false, true);

        // Mark these removed items in our "undo" list so we can re-add them
        setPendingUndoSignatures(prev => [...prev, ...removed]);

        // Send partial update for "added"/"updated"
        const resp = await outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, added, updated, []),
        });
        const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];

        if (removed.length > 0) {
          // schedule lazy removal from UI + server
          scheduleLazyDeletionTimers(
            removed,
            setPendingDeletionMap,
            async sig => {
              // final removal from the server
              await outCommand({
                type: OutCommand.updateSignatures,
                data: prepareUpdatePayload(systemId, [], [], [sig]),
              });
              // remove from the "undo" array so it's no longer restorable
              setPendingUndoSignatures(pu => pu.filter(x => x.eve_id !== sig.eve_id));
            },
            setSignatures,
            FLASH_DURATION_MS,
            FINAL_DURATION_MS,
          );

          // Mark them as “pendingDeletion: true” so row is highlighted
          const now = Date.now();
          const updatedWithRemoval = castedUpdated.map(sig =>
            removed.some(r => r.eve_id === sig.eve_id)
              ? { ...sig, pendingDeletion: true, pendingUntil: now + FLASH_DURATION_MS }
              : sig,
          );
          // If the server doesn't return them at all, add them manually
          const onlyRemoved = removed
            .map(r => ({ ...r, pendingDeletion: true, pendingUntil: now + FLASH_DURATION_MS }))
            .filter(r => !updatedWithRemoval.some(m => m.eve_id === r.eve_id));

          setSignatures([...updatedWithRemoval, ...onlyRemoved]);
        } else {
          // no items were removed, just set the updated array
          setSignatures(castedUpdated);
        }

        // optionally disable lazy
        if (!keepLazyDeleteValue) {
          onLazyDeleteChange?.(false);
        }
      } else {
        // no lazy logic
        const filteredNew = parsed.filter(sig => {
          if (sig.kind === COSMIC_SIGNATURE && sig.eve_id.length === 3) {
            const prefix = sig.eve_id.substring(0, 3).toUpperCase();
            return !signaturesRef.current.some(
              existingSig =>
                existingSig.kind === COSMIC_SIGNATURE &&
                existingSig.eve_id.substring(0, 3).toUpperCase() === prefix &&
                existingSig.eve_id.length === 7,
            );
          }
          return true;
        });
        await handleUpdateSignatures(filteredNew, true);
      }
    },
    [
      lazyDeleteValue,
      keepLazyDeleteValue,
      onLazyDeleteChange,
      outCommand,
      systemId,
      signaturesRef,
      handleUpdateSignatures,
      settings,
      setSignatures,
    ],
  );

  // If user physically pastes and we have text
  useEffect(() => {
    if (refData.current.selectable) return;
    if (!clipboardContent?.text) return;
    handlePaste(clipboardContent.text);
    setClipboardContent(null);
  }, [clipboardContent, selectable, handlePaste, setClipboardContent]);

  // "A" => select all, "Delete"/"Backspace" => delete selected
  useHotkey(true, ['a'], handleSelectAll);
  useHotkey(false, ['Backspace', 'Delete'], handleDeleteSelected);

  // On mount or system change
  useEffect(() => {
    if (!systemId) {
      setSignatures([]);
      return;
    }
    handleGetSignatures();
  }, [systemId, handleGetSignatures, setSignatures]);

  // Listen for "signaturesUpdated" events
  useMapEventListener(event => {
    if (event.name === Commands.signaturesUpdated && event.data?.toString() === systemId.toString()) {
      handleGetSignatures();
      return true;
    }
  });

  /**
   * We define the handleResize function to fix the "Cannot find name 'handleResize'" error.
   * Called by the ResizeObserver below.
   */
  const handleResize = useCallback(() => {
    if (tableRef.current) {
      const tableWidth = tableRef.current.offsetWidth;
      const otherColumnsWidth = 276;
      setNameColumnWidth(`${tableWidth - otherColumnsWidth}px`);
    }
  }, []);

  // Observe table resize for dynamic columns
  useEffect(() => {
    const observer = new ResizeObserver(handleResize);
    if (tableRef.current) observer.observe(tableRef.current);
    handleResize();
    return () => {
      if (tableRef.current) observer.unobserve(tableRef.current);
    };
  }, [handleResize]);

  /**
   * Periodically remove old signatures:
   *  - wormholes older than 1 day
   *  - everything else older than 1 week
   */
  useEffect(() => {
    const currentTime = Date.now();
    const signaturesToDelete = signaturesRef.current.filter(sig => {
      if (!sig.inserted_at) return false;
      const insertedTime = new Date(sig.inserted_at).getTime();
      const threshold = sig.group === SignatureGroup.Wormhole ? TIME_ONE_DAY : TIME_ONE_WEEK;
      return currentTime - insertedTime > threshold;
    });
    if (signaturesToDelete.length > 0) {
      const remainingSignatures = signaturesRef.current.filter(sig => !signaturesToDelete.includes(sig));
      handleUpdateSignatures(remainingSignatures, false, true);
    }
  }, [handleUpdateSignatures, signatures, signaturesRef]);

  const renderToolbar = () => (
    <div className="flex justify-end items-center gap-2 mr-[4px]">
      <WdTooltipWrapper content="To Edit Signature do double click">
        <span className={clsx(PrimeIcons.PENCIL, 'text-[10px]')}></span>
      </WdTooltipWrapper>
    </div>
  );

  const [showSignatureSettings, setShowSignatureSettings] = useState(false);
  const handleRowClick = (e: DataTableRowClickEvent) => {
    setSelectedSignature(e.data as SystemSignature);
    setShowSignatureSettings(true);
  };

  // Filter hidden or cosmic signatures, then sort
  const groupSettings = useMemo(() => settings.filter(s => (GROUPS_LIST as string[]).includes(s.key)), [settings]);
  const showDescriptionColumn = useMemo(
    () => settings.find(s => s.key === SHOW_DESCRIPTION_COLUMN_SETTING)?.value,
    [settings],
  );
  const showUpdatedColumn = useMemo(() => settings.find(s => s.key === SHOW_UPDATED_COLUMN_SETTING)?.value, [settings]);

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
              ? (e: DataTableRowMouseEvent) => {
                  // @ts-ignore
                  tooltipRef.current?.hide(e.originalEvent);
                  setHoveredSig(null);
                }
              : undefined
          }
          rowClassName={row => getRowClassName(row, pendingDeletionMap, selectedSignatures, getRowColorByTimeLeft)}
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
