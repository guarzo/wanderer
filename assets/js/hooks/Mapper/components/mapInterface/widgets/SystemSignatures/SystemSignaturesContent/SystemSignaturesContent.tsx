import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { DataTable, DataTableRowClickEvent, DataTableRowMouseEvent, SortOrder } from 'primereact/datatable';
import { Column } from 'primereact/column';
import clsx from 'clsx';
import classes from './SystemSignaturesContent.module.scss';
import useMaxWidth from '@/hooks/Mapper/hooks/useMaxWidth';
import useLocalStorageState from 'use-local-storage-state';
import { PrimeIcons } from 'primereact/api';
import { WdTooltip, WdTooltipHandlers } from '@/hooks/Mapper/components/ui-kit';
import { SignatureView } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/SignatureView';
import {
  renderAddedTimeLeft,
  renderDescription,
  renderIcon,
  renderInfoColumn,
  renderUpdatedTimeLeft,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/renders';
import { SignatureSettings } from '@/hooks/Mapper/components/mapRootContent/components/SignatureSettings';
import { useClipboard } from '@/hooks/Mapper/hooks/useClipboard';
import { COSMIC_SIGNATURE } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/SystemSignatureSettingsDialog';
import {
  SHOW_DESCRIPTION_COLUMN_SETTING,
  SHOW_UPDATED_COLUMN_SETTING,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures';
import { GROUPS_LIST } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { ExtendedSystemSignature, getRowClassName } from '../helpers/contentHelpers';
import { useSystemSignaturesData } from '../hooks/useSystemSignaturesData';
import { useHotkey } from '@/hooks/Mapper/hooks';
import { SystemSignature } from '@/hooks/Mapper/types';

interface SystemSignaturesContentProps {
  systemId: string;
  settings: { key: string; value: boolean }[];
  hideLinkedSignatures?: boolean;
  selectable?: boolean;
  onSelect?: (signature: SystemSignature) => void;
  onLazyDeleteChange?: (value: boolean) => void;
  onCountChange: (count: number) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
  onBookmarkPasteComplete?: () => void;
}

export const SystemSignaturesContent = ({
  systemId,
  settings,
  hideLinkedSignatures,
  selectable,
  onSelect,
  onCountChange,
  onPendingChange,
  onBookmarkPasteComplete,
}: SystemSignaturesContentProps) => {
  const { signatures, selectedSignatures, setSelectedSignatures, handleDeleteSelected, handleSelectAll, handlePaste } =
    useSystemSignaturesData({
      systemId,
      settings,
      hideLinkedSignatures,
      onCountChange,
      onPendingChange,
      onBookmarkPasteComplete,
    });

  const [sortSettings, setSortSettings] = useLocalStorageState<{ sortField: string; sortOrder: SortOrder }>(
    'window:signatures:sort',
    { defaultValue: { sortField: 'inserted_at', sortOrder: -1 } },
  );

  // Refs for layout and tooltips.
  const tableRef = useRef<HTMLDivElement>(null);
  const tooltipRef = useRef<WdTooltipHandlers>(null);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [hoveredSig, setHoveredSig] = useState<any>(null);

  const compact = useMaxWidth(tableRef, 260);
  const medium = useMaxWidth(tableRef, 380);

  const { clipboardContent, setClipboardContent } = useClipboard();
  useEffect(() => {
    if (selectable) return;
    if (!clipboardContent?.text) return;
    handlePaste(clipboardContent.text);
    setClipboardContent(null);
  }, [clipboardContent, selectable, handlePaste, setClipboardContent]);

  useHotkey(true, ['a'], handleSelectAll);
  useHotkey(false, ['Backspace', 'Delete'], handleDeleteSelected);

  const [nameColumnWidth, setNameColumnWidth] = useState('auto');
  const handleResize = useCallback(() => {
    if (tableRef.current) {
      const tableWidth = tableRef.current.offsetWidth;
      const otherColumnsWidth = 276;
      setNameColumnWidth(`${tableWidth - otherColumnsWidth}px`);
    }
  }, []);
  useEffect(() => {
    const observer = new ResizeObserver(handleResize);
    if (tableRef.current) observer.observe(tableRef.current);
    handleResize();
    return () => {
      if (tableRef.current) observer.unobserve(tableRef.current);
    };
  }, [handleResize]);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [selectedSignature, setSelectedSignature] = useState<any>(null);
  const [showSignatureSettings, setShowSignatureSettings] = useState(false);
  const handleRowClick = (e: DataTableRowClickEvent) => {
    setSelectedSignature(e.data);
    setShowSignatureSettings(true);
  };

  const handleSelectSignatures = useCallback(
    (e: { value: SystemSignature[] }) => {
      if (selectable) {
        onSelect?.(e.value[0]);
      } else {
        setSelectedSignatures(e.value);
      }
    },
    [selectable, onSelect, setSelectedSignatures],
  );

  // Filtering and sorting signatures.
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
        const preparedGroup = x.group;
        if (isCosmicSignature) {
          const showCosmicSignatures = settings.find(y => y.key === COSMIC_SIGNATURE)?.value;
          return showCosmicSignatures
            ? !x.group || groupSettings.find(y => y.key === preparedGroup)?.value
            : !!x.group && groupSettings.find(y => y.key === preparedGroup)?.value;
        }
        return settings.find(y => y.key === x.kind)?.value;
      })
      .sort((a, b) => {
        if (a.pendingDeletion && !b.pendingDeletion) return 1;
        if (!a.pendingDeletion && b.pendingDeletion) return -1;
        return new Date(b.updated_at || 0).getTime() - new Date(a.updated_at || 0).getTime();
      });
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
          rowClassName={row => getRowClassName(row, selectedSignatures)}
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
              body={() => (
                <div className="flex justify-end items-center gap-2 mr-[4px]">
                  <span className={clsx(PrimeIcons.PENCIL, 'text-[10px]')}></span>
                </div>
              )}
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
