// SystemSignaturesContent.tsx

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
import classes from './SystemSignaturesContent.module.scss';
import clsx from 'clsx';
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

export interface ExtendedSystemSignature extends SystemSignature {
  pendingDeletion?: boolean;
  pendingUntil?: number;
}

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
  onPendingDeletionChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
}

export const SystemSignaturesContent = ({
  systemId,
  settings,
  hideLinkedSignatures,
  selectable,
  onSelect,
  onLazyDeleteChange,
  onCountChange,
  onPendingDeletionChange,
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
  const compact = useMaxWidth(tableRef, 260);
  const medium = useMaxWidth(tableRef, 380);

  const refData = useRef({ selectable });
  refData.current = { selectable };

  const tooltipRef = useRef<WdTooltipHandlers>(null);
  const { clipboardContent, setClipboardContent } = useClipboard();

  // Whether lazy-delete is currently active:
  const lazyDeleteValue = useMemo(
    () => settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false,
    [settings],
  );
  // Whether to remain in lazy-delete mode after a parse
  const keepLazyDeleteValue = useMemo(
    () => settings.find(s => s.key === KEEP_LAZY_DELETE_SETTING)?.value ?? false,
    [settings],
  );

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

  useEffect(() => {
    onCountChange(signatures.length);
  }, [onCountChange, signatures]);

  const [pendingDeletions, setPendingDeletions] = useState<
    Record<string, { flashUntil: number; finalUntil: number; flashTimeoutId: number; finalTimeoutId: number }>
  >({});
  const [pendingUndoSignatures, setPendingUndoSignatures] = useState<ExtendedSystemSignature[]>([]);

  const handleGetSignatures = useCallback(async () => {
    if (!systemId) {
      setSignatures([]);
      return;
    }
    const { signatures: serverSignatures } = await outCommand({
      type: OutCommand.getSignatures,
      data: { system_id: systemId },
    });
    const extendedServer = serverSignatures.map((s: SystemSignature) => ({ ...s })) as ExtendedSystemSignature[];

    if (lazyDeleteValue) {
      const now = Date.now();
      const pendingMap = new Map<string, ExtendedSystemSignature>();
      signaturesRef.current
        .filter(sig => sig.pendingDeletion && sig.pendingUntil && sig.pendingUntil > now)
        .forEach(sig => pendingMap.set(sig.eve_id, sig));

      const merged = extendedServer.map(sig =>
        pendingMap.has(sig.eve_id)
          ? { ...sig, pendingDeletion: true, pendingUntil: pendingMap.get(sig.eve_id)!.pendingUntil }
          : sig,
      );
      const extra = Array.from(pendingMap.values()).filter(sig => !merged.some(s => s.eve_id === sig.eve_id));
      setSignatures([...merged, ...extra]);
    } else {
      setSignatures(extendedServer);
    }
  }, [outCommand, systemId, lazyDeleteValue, signaturesRef, setSignatures]);

  const handleUpdateSignatures = useCallback(
    async (newSignatures: ExtendedSystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );
      const { signatures: updatedSigsFromServer } = await outCommand({
        type: OutCommand.updateSignatures,
        data: { system_id: systemId, added, updated, removed },
      });
      const castedUpdated = updatedSigsFromServer.map((s: SystemSignature) => ({ ...s })) as ExtendedSystemSignature[];
      setSignatures(() => castedUpdated);
      setSelectedSignatures([]);
    },
    [outCommand, setSignatures, signaturesRef, systemId],
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

  const undoPendingDeletions = useCallback(() => {
    Object.entries(pendingDeletions).forEach(([, timers]) => {
      clearTimeout(timers.flashTimeoutId);
      clearTimeout(timers.finalTimeoutId);
    });
    setSignatures(prev => {
      const existingIds = new Set(prev.map(sig => sig.eve_id));
      const toReAdd = pendingUndoSignatures.filter(sig => !existingIds.has(sig.eve_id));
      const updated = prev.map(sig =>
        pendingDeletions[sig.eve_id] ? { ...sig, pendingDeletion: false, pendingUntil: undefined } : sig,
      );
      return [...updated, ...toReAdd];
    });
    setPendingDeletions({});
    setPendingUndoSignatures([]);
  }, [pendingDeletions, pendingUndoSignatures, setSignatures]);

  useEffect(() => {
    if (onPendingDeletionChange) {
      onPendingDeletionChange(pendingUndoSignatures, undoPendingDeletions);
    }
  }, [pendingUndoSignatures, onPendingDeletionChange, undoPendingDeletions]);

  const handlePaste = useCallback(
    async (clipboardString: string) => {
      if (lazyDeleteValue) {
        const newSignatures = parseSignatures(
          clipboardString,
          settings.map(x => x.key),
          undefined,
        ).map(s => ({ ...s })) as ExtendedSystemSignature[];

        const filteredNew = newSignatures.filter(sig => {
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

        const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion);
        const { added, updated, removed } = getActualSigs(currentNonPending, filteredNew, false, true);

        setPendingUndoSignatures(prev => [...prev, ...removed]);

        const { signatures: updatedSignatures } = await outCommand({
          type: OutCommand.updateSignatures,
          data: { system_id: systemId, added, updated, removed: [] },
        });
        const castedUpdated = updatedSignatures.map((s: SystemSignature) => ({ ...s })) as ExtendedSystemSignature[];

        const now = Date.now();
        removed.forEach(sig => {
          const flashTimeoutId = window.setTimeout(() => {
            setSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
          }, 7000);

          const finalTimeoutId = window.setTimeout(async () => {
            const baseSig: SystemSignature = {
              ...sig,
            };
            await outCommand({
              type: OutCommand.updateSignatures,
              data: { system_id: systemId, added: [], updated: [], removed: [baseSig] },
            });

            setPendingDeletions(prev => {
              const newPending = { ...prev };
              delete newPending[sig.eve_id];
              return newPending;
            });
            setPendingUndoSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
          }, 60000);

          setPendingDeletions(prev => ({
            ...prev,
            [sig.eve_id]: { flashUntil: now + 7000, finalUntil: now + 60000, flashTimeoutId, finalTimeoutId },
          }));
        });

        const merged = castedUpdated.map(sig =>
          removed.some(r => r.eve_id === sig.eve_id)
            ? { ...sig, pendingDeletion: true, pendingUntil: now + 7000 }
            : sig,
        );
        const pendingRemoved = removed
          .map(sig => ({ ...sig, pendingDeletion: true, pendingUntil: now + 7000 }))
          .filter(p => !merged.some(s => s.eve_id === p.eve_id));
        const finalArr = [...merged, ...pendingRemoved];
        setSignatures(finalArr);

        if (!keepLazyDeleteValue) {
          onLazyDeleteChange?.(false);
        }
      } else {
        const existing = signaturesRef.current;
        const newSignatures = parseSignatures(
          clipboardString,
          settings.map(x => x.key),
          existing,
        ).map(s => ({ ...s })) as ExtendedSystemSignature[];

        const filteredNew = newSignatures.filter(sig => {
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

        handleUpdateSignatures(filteredNew, true);
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

  useEffect(() => {
    if (refData.current.selectable) return;
    if (!clipboardContent?.text) return;
    handlePaste(clipboardContent.text);
    setClipboardContent(null);
  }, [clipboardContent, selectable, handlePaste, setClipboardContent]);

  useHotkey(true, ['a'], handleSelectAll);
  useHotkey(false, ['Backspace', 'Delete'], handleDeleteSelected);

  useEffect(() => {
    if (!systemId) {
      setSignatures([]);
      return;
    }
    handleGetSignatures();
  }, [handleGetSignatures, setSignatures, systemId]);

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
    // @ts-ignore
    setSelectedSignature(e.data);
    setShowSignatureSettings(true);
  };

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
          rowClassName={row => {
            const isPending = pendingDeletions[row.eve_id] && pendingDeletions[row.eve_id].flashUntil > Date.now();
            if (isPending) return clsx(classes.TableRowCompact, classes.flashPending);

            if (selectedSignatures.some(s => s.eve_id === row.eve_id)) {
              return clsx(classes.TableRowCompact, 'bg-amber-500/50 hover:bg-amber-500/70 transition');
            }
            return clsx(classes.TableRowCompact, 'hover:bg-purple-400/20 transition');
          }}
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
