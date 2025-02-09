import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { parseSignatures, getActualSigs } from '../helpers/zooSignatures';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers.ts';
import { WdTooltip, WdTooltipHandlers } from '@/hooks/Mapper/components/ui-kit';
import {
  getGroupIdByRawGroup,
  GROUPS_LIST,
  TIME_ONE_DAY,
  TIME_ONE_WEEK,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants.ts';

import { DataTable, DataTableRowClickEvent, DataTableRowMouseEvent, SortOrder } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import useRefState from 'react-usestateref';
import { Setting } from '../SystemSignatureSettingsDialog';
import { useHotkey } from '@/hooks/Mapper/hooks';
import useMaxWidth from '@/hooks/Mapper/hooks/useMaxWidth.ts';
import { useClipboard } from '@/hooks/Mapper/hooks/useClipboard';

import classes from './SystemSignaturesContent.module.scss';
import clsx from 'clsx';
import { SystemSignature, SignatureGroup } from '@/hooks/Mapper/types';
import { SignatureView } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/SignatureView';
import { getRowColorByTimeLeft } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/helpers';
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
}

export const SystemSignaturesContent = ({
  systemId,
  settings,
  hideLinkedSignatures,
  selectable,
  onSelect,
  onLazyDeleteChange,
  onCountChange,
}: SystemSignaturesContentProps) => {
  const { outCommand } = useMapRootState();

  // Local state holds all signatures.
  // When lazy deletion is active, items marked with a pendingDeletion flag (and a pendingUntil timestamp)
  // will be rendered with a flashing red-to-black effect.
  const [signatures, setSignatures, signaturesRef] = useRefState<SystemSignature[]>([]);
  const [selectedSignatures, setSelectedSignatures] = useState<SystemSignature[]>([]);
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

  const lazyDeleteValue = useMemo(() => {
    return settings.find(setting => setting.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false;
  }, [settings]);

  const keepLazyDeleteValue = useMemo(() => {
    return settings.find(setting => setting.key === KEEP_LAZY_DELETE_SETTING)?.value ?? false;
  }, [settings]);

  const handleResize = useCallback(() => {
    if (tableRef.current) {
      const tableWidth = tableRef.current.offsetWidth;
      const otherColumnsWidth = 276;
      const availableWidth = tableWidth - otherColumnsWidth;
      setNameColumnWidth(`${availableWidth}px`);
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

  // ── Modified handleGetSignatures: preserve pending items that haven't expired ─────────────
  const handleGetSignatures = useCallback(async () => {
    const { signatures: serverSignatures } = await outCommand({
      type: OutCommand.getSignatures,
      data: { system_id: systemId },
    });
    if (lazyDeleteValue) {
      const now = Date.now();
      // Build a map of locally pending signatures that haven't yet expired.
      const pendingMap = new Map<string, SystemSignature>();
      signaturesRef.current
        .filter(sig => (sig as any).pendingDeletion && (sig as any).pendingUntil > now)
        .forEach(sig => pendingMap.set(sig.eve_id, sig));
      // For each server signature, if it's locally pending, reapply the pendingDeletion flag.
      const merged = serverSignatures.map(sig => {
        if (pendingMap.has(sig.eve_id)) {
          return { ...sig, pendingDeletion: true, pendingUntil: (pendingMap.get(sig.eve_id) as any).pendingUntil };
        }
        return sig;
      });
      // Also add any pending deletion items that are not returned by the server.
      const extra = Array.from(pendingMap.values()).filter(sig => !serverSignatures.some(s => s.eve_id === sig.eve_id));
      setSignatures([...merged, ...extra]);
    } else {
      setSignatures(serverSignatures);
    }
  }, [outCommand, systemId, lazyDeleteValue, signaturesRef, setSignatures]);

  const handleUpdateSignatures = useCallback(
    async (newSignatures: SystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );

      const { signatures: updatedSignatures } = await outCommand({
        type: OutCommand.updateSignatures,
        data: {
          system_id: systemId,
          added,
          updated,
          removed,
        },
      });

      setSignatures(() => updatedSignatures);
      setSelectedSignatures([]);
    },
    [outCommand, setSignatures, signaturesRef, systemId],
  );

  const handleDeleteSelected = useCallback(
    async (e: KeyboardEvent) => {
      if (selectable) {
        return;
      }
      if (selectedSignatures.length === 0) {
        return;
      }

      e.preventDefault();
      e.stopPropagation();

      const selectedSignaturesEveIds = selectedSignatures.map(x => x.eve_id);
      await handleUpdateSignatures(
        signatures.filter(x => !selectedSignaturesEveIds.includes(x.eve_id)),
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
    // @ts-ignore
    e => {
      if (selectable) {
        onSelect?.(e.value);
      } else {
        setSelectedSignatures(e.value);
      }
    },
    [onSelect, selectable],
  );

  // ── Revised handlePaste for lazy deletion ──────────────────────────────
  const handlePaste = async (clipboardContent: string) => {
    if (lazyDeleteValue) {
      const newSignatures = parseSignatures(
        clipboardContent,
        settings.map(x => x.key),
        undefined,
      );
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

      // Compute diff based only on signatures not already pending deletion.
      const currentNonPending = signaturesRef.current.filter(sig => !(sig as any).pendingDeletion);
      const { added, updated, removed } = getActualSigs(currentNonPending, filteredNew, false, true);

      // Update added/updated items in the backend but send an empty removal array.
      const { signatures: updatedSignatures } = await outCommand({
        type: OutCommand.updateSignatures,
        data: {
          system_id: systemId,
          added,
          updated,
          removed: [],
        },
      });

      // Mark any signature that should be removed as pending deletion,
      // and attach a pendingUntil timestamp for 7 seconds from now.
      const now = Date.now();
      const merged = updatedSignatures.map(sig => {
        if (removed.some(r => r.eve_id === sig.eve_id)) {
          return { ...sig, pendingDeletion: true, pendingUntil: now + 7000 };
        }
        return sig;
      });
      const pendingRemoved = removed
        .map(sig => ({ ...sig, pendingDeletion: true, pendingUntil: now + 7000 }))
        .filter(p => !merged.some(s => s.eve_id === p.eve_id));
      setSignatures([...merged, ...pendingRemoved]);

      // Schedule removal after 7 seconds.
      setTimeout(async () => {
        setSignatures(prev => prev.filter(sig => removed.every(r => r.eve_id !== sig.eve_id)));
        await outCommand({
          type: OutCommand.updateSignatures,
          data: {
            system_id: systemId,
            added: [],
            updated: [],
            removed,
          },
        });
      }, 7000);

      if (!keepLazyDeleteValue) {
        onLazyDeleteChange?.(false);
      }
    } else {
      const existing = signaturesRef.current;
      const newSignatures = parseSignatures(
        clipboardContent,
        settings.map(x => x.key),
        existing,
      );
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
  };
  // ─────────────────────────────────────────────────────────────────────────

  const handleEnterRow = useCallback((e: DataTableRowMouseEvent) => {
    setHoveredSig(filteredSignatures[e.index]);
    tooltipRef.current?.show(e.originalEvent);
  }, []);

  const handleLeaveRow = useCallback((e: DataTableRowMouseEvent) => {
    tooltipRef.current?.hide(e.originalEvent);
    setHoveredSig(null);
  }, []);

  useEffect(() => {
    if (refData.current.selectable) {
      return;
    }
    if (!clipboardContent?.text) {
      return;
    }
    handlePaste(clipboardContent.text);
    setClipboardContent(null);
  }, [clipboardContent, selectable, lazyDeleteValue, keepLazyDeleteValue, handlePaste, setClipboardContent]);

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
    switch (event.name) {
      case Commands.signaturesUpdated:
        if (event.data?.toString() !== systemId.toString()) {
          return;
        }
        handleGetSignatures();
        return true;
    }
  });

  useEffect(() => {
    const observer = new ResizeObserver(handleResize);
    if (tableRef.current) {
      observer.observe(tableRef.current);
    }
    handleResize();
    return () => {
      if (tableRef.current) {
        observer.unobserve(tableRef.current);
      }
    };
  }, []);

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

  const renderToolbar = () => {
    return (
      <div className="flex justify-end items-center gap-2 mr-[4px]">
        <WdTooltipWrapper content="To Edit Signature do double click">
          <span className={clsx(PrimeIcons.PENCIL, 'text-[10px]')}></span>
        </WdTooltipWrapper>
      </div>
    );
  };

  const [showSignatureSettings, setShowSignatureSettings] = useState(false);
  const handleRowClick = (e: DataTableRowClickEvent) => {
    setSelectedSignature(e.data as SystemSignature);
    setShowSignatureSettings(true);
  };

  const filteredSignatures = useMemo(() => {
    return signatures
      .filter(x => {
        if (hideLinkedSignatures && !!x.linked_system) {
          return false;
        }
        const isCosmicSignature = x.kind === COSMIC_SIGNATURE;
        const preparedGroup = getGroupIdByRawGroup(x.group);
        if (isCosmicSignature) {
          const showCosmicSignatures = settings.find(y => y.key === COSMIC_SIGNATURE)?.value;
          if (showCosmicSignatures) {
            return !x.group || groupSettings.find(y => y.key === preparedGroup)?.value;
          } else {
            return !!x.group && groupSettings.find(y => y.key === preparedGroup)?.value;
          }
        }
        return settings.find(y => y.key === x.kind)?.value;
      })
      .sort((a, b) => new Date(b.updated_at || 0).getTime() - new Date(a.updated_at || 0).getTime());
  }, [signatures, settings, groupSettings, hideLinkedSignatures]);

  return (
    <>
      <div ref={tableRef} className="h-full">
        {filteredSignatures.length === 0 ? (
          <div className="w-full h-full flex justify-center items-center select-none text-stone-400/80 text-sm">
            No signatures
          </div>
        ) : (
          <>
            {/* @ts-ignore */}
            <DataTable
              className={classes.Table}
              value={filteredSignatures}
              size="small"
              selectionMode={selectable ? 'single' : 'multiple'}
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
              onSort={event => setSortSettings(() => ({ sortField: event.sortField, sortOrder: event.sortOrder }))}
              onRowMouseEnter={compact || medium ? handleEnterRow : undefined}
              onRowMouseLeave={compact || medium ? handleLeaveRow : undefined}
              rowClassName={row => {
                // If pendingDeletion is set, apply the flashing animation class.
                if ((row as any).pendingDeletion) {
                  return clsx(classes.TableRowCompact, classes.flashPending);
                }
                if (selectedSignatures.some(x => x.eve_id === row.eve_id)) {
                  return clsx(classes.TableRowCompact, 'bg-amber-500/50 hover:bg-amber-500/70 transition duration-200');
                }
                const dateClass = getRowColorByTimeLeft(row.inserted_at ? new Date(row.inserted_at) : undefined);
                if (!dateClass) {
                  return clsx(classes.TableRowCompact, 'hover:bg-purple-400/20 transition duration-200');
                }
                return clsx(classes.TableRowCompact, dateClass);
              }}
            >
              <Column
                bodyClassName="p-0 px-1"
                field="group"
                body={x => renderIcon(x)}
                style={{ maxWidth: 26, minWidth: 26, width: 26, height: 25 }}
              ></Column>
              <Column
                field="eve_id"
                header="Id"
                bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
                style={{ maxWidth: 72, minWidth: 72, width: 72 }}
                sortable
              ></Column>
              <Column
                field="group"
                header="Group"
                bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
                hidden={compact}
                style={{ maxWidth: 110, minWidth: 110, width: 110 }}
                sortable
              ></Column>
              <Column
                field="info"
                bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
                body={renderInfoColumn}
                style={{ maxWidth: nameColumnWidth }}
                hidden={compact || medium}
              ></Column>
              {showDescriptionColumn && (
                <Column
                  field="description"
                  header="Description"
                  bodyClassName="text-ellipsis overflow-hidden whitespace-nowrap"
                  body={renderDescription}
                  hidden={compact}
                  sortable
                ></Column>
              )}
              <Column
                field="inserted_at"
                header="Added"
                dataType="date"
                bodyClassName="w-[70px] text-ellipsis overflow-hidden whitespace-nowrap"
                body={renderAddedTimeLeft}
                sortable
              ></Column>
              {showUpdatedColumn && (
                <Column
                  field="updated_at"
                  header="Updated"
                  dataType="date"
                  bodyClassName="w-[70px] text-ellipsis overflow-hidden whitespace-nowrap"
                  body={renderUpdatedTimeLeft}
                  sortable
                ></Column>
              )}
              {!selectable && (
                <Column
                  bodyClassName="p-0 pl-1 pr-2"
                  field="group"
                  body={renderToolbar}
                  style={{ maxWidth: 26, minWidth: 26, width: 26 }}
                ></Column>
              )}
            </DataTable>
          </>
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
    </>
  );
};
