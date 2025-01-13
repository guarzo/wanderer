import React, { useState, useCallback } from 'react';
import { DataTable, DataTableRowClickEvent } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { PrimeIcons } from 'primereact/api';
import clsx from 'clsx';

import { StructuresEditDialog } from '../SystemStructuresDialog/SystemStructuresDialog';
import { StructureItem, StructureStatus } from '../helpers/types';
import { useHotkey } from '@/hooks/Mapper/hooks';

import classes from './SystemStructuresContent.module.scss';

const statusesRequiringTimer: StructureStatus[] = ['Anchoring', 'Reinforced'];

interface SystemStructuresContentProps {
  structures: StructureItem[];
  onUpdateStructures: (newList: StructureItem[]) => void;
}

export const SystemStructuresContent: React.FC<SystemStructuresContentProps> = ({ structures, onUpdateStructures }) => {
  const [selectedRow, setSelectedRow] = useState<StructureItem | null>(null);
  const [editingItem, setEditingItem] = useState<StructureItem | null>(null);
  const [showEditDialog, setShowEditDialog] = useState(false);

  const handleRowClick = (e: DataTableRowClickEvent) => {
    const row = e.data as StructureItem;
    setSelectedRow(prev => (prev?.id === row.id ? null : row));
  };

  const handleRowDoubleClick = (e: DataTableRowClickEvent) => {
    setEditingItem(e.data as StructureItem);
    setShowEditDialog(true);
  };

  // Press Delete => remove selected row from local array
  const handleDeleteSelected = useCallback(
    (e: KeyboardEvent) => {
      if (!selectedRow) {
        return;
      }
      e.preventDefault();
      e.stopPropagation();

      const newList = structures.filter(s => s.id !== selectedRow.id);
      onUpdateStructures(newList);

      setSelectedRow(null);
    },
    [selectedRow, structures, onUpdateStructures],
  );

  useHotkey(false, ['Delete', 'Backspace'], handleDeleteSelected);

  function renderOwner(row: StructureItem) {
    return (
      <div className="flex items-center gap-2">
        {row.ownerId && (
          <img
            src={`https://images.evetech.net/corporations/${row.ownerId}/logo?size=32`}
            alt="corp icon"
            className="w-5 h-5 object-contain"
          />
        )}
        <span>{row.ownerTicker || row.owner}</span>
      </div>
    );
  }

  function renderTimer(row: StructureItem) {
    if (!statusesRequiringTimer.includes(row.status)) {
      return <span className="text-stone-400"></span>;
    }
    if (!row.endTime) {
      return <span className="text-sky-400">Set Timer</span>;
    }

    const msLeft = new Date(row.endTime).getTime() - Date.now();
    if (msLeft <= 0) {
      return <span className="text-red-500">00:00:00</span>;
    }

    const sec = Math.floor(msLeft / 1000) % 60;
    const min = Math.floor(msLeft / (1000 * 60)) % 60;
    const hr = Math.floor(msLeft / (1000 * 3600));

    const pad = (n: number) => n.toString().padStart(2, '0');
    return (
      <span className="text-sky-400">
        {pad(hr)}:{pad(min)}:{pad(sec)}
      </span>
    );
  }

  function renderType(row: StructureItem) {
    return (
      <div className="flex items-center gap-1">
        <img
          src={`https://images.evetech.net/types/${row.typeId}/icon`}
          alt="icon"
          className="w-5 h-5 object-contain"
        />
        <span>{row.type ?? ''}</span>
      </div>
    );
  }

  // We'll let "visibleStructures" = structures, or do filtering if needed
  const visibleStructures = structures;

  return (
    // Fill the available space => "flex flex-col h-full"
    <div className="flex flex-col gap-2 p-2 text-xs text-stone-200 h-full">
      {visibleStructures.length === 0 ? (
        // Fill vertical space so the background is consistent
        <div className="flex-1 flex justify-center items-center text-stone-400/80 text-sm">No structures</div>
      ) : (
        // Occupy the rest of the vertical space
        <div className="flex-1">
          <DataTable
            value={visibleStructures}
            dataKey="id"
            className={clsx(classes.Table, 'w-full select-none h-full')}
            size="small"
            sortMode="single"
            rowHover
            onRowClick={handleRowClick}
            onRowDoubleClick={handleRowDoubleClick}
            rowClassName={rowData => {
              const isSelected = selectedRow?.id === rowData.id;
              return clsx(
                classes.TableRowCompact,
                'transition-colors duration-200 cursor-pointer',
                isSelected ? 'bg-amber-500/50 hover:bg-amber-500/70' : 'hover:bg-purple-400/20',
              );
            }}
          >
            <Column header="Type" body={renderType} style={{ width: '160px' }} />
            <Column field="name" header="Name" style={{ width: '120px' }} />
            <Column header="Owner" body={renderOwner} style={{ width: '120px' }} />
            <Column field="status" header="Status" style={{ width: '100px' }} />
            <Column header="Timer" body={renderTimer} style={{ width: '110px' }} />
            <Column
              body={(rowData: StructureItem) => (
                <i
                  className={clsx(PrimeIcons.PENCIL, 'text-[14px] cursor-pointer')}
                  title="Edit"
                  onClick={() => {
                    setEditingItem(rowData);
                    setShowEditDialog(true);
                  }}
                />
              )}
              style={{ width: '40px', textAlign: 'center' }}
            />
          </DataTable>
        </div>
      )}

      {showEditDialog && editingItem && (
        <StructuresEditDialog
          visible={showEditDialog}
          structure={editingItem}
          onClose={() => setShowEditDialog(false)}
          onSave={async (updatedItem: StructureItem) => {
            const newList = structures.map(s => (s.id === updatedItem.id ? updatedItem : s));
            onUpdateStructures(newList);
            setShowEditDialog(false);
          }}
          onDelete={async (deleteId: string) => {
            const newList = structures.filter(s => s.id !== deleteId);
            onUpdateStructures(newList);
            setShowEditDialog(false);
          }}
        />
      )}
    </div>
  );
};
