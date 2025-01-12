import React, { useEffect, useState, useCallback } from 'react';
import { Dialog } from 'primereact/dialog';
import { Button } from 'primereact/button';
import { AutoComplete } from 'primereact/autocomplete';
import clsx from 'clsx';
import { StructureItem, StructureStatus } from '../helpers/types';
import { statusesRequiringTimer } from '../helpers/parseHelpers';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand } from '@/hooks/Mapper/types';

interface StructuresEditDialogProps {
  visible: boolean;
  structure?: StructureItem;
  onClose: () => void;
  onSave: (updatedItem: StructureItem) => void;
  onDelete: (id: string) => void;
}

export const StructuresEditDialog: React.FC<StructuresEditDialogProps> = ({
  visible,
  structure,
  onClose,
  onSave,
  onDelete,
}) => {
  const [editData, setEditData] = useState<StructureItem | null>(null);
  const [owner, setOwner] = useState('');
  const [ownerSuggestions, setOwnerSuggestions] = useState([]);
  const { outCommand } = useMapRootState();
  const [prevQuery, setPrevQuery] = useState('');
  const [prevResults, setPrevResults] = useState([]);

  const searchOwners = useCallback(
    async e => {
      const newQuery = e.query;

      if (newQuery.startsWith(prevQuery) && prevResults.length > 0) {
        const filtered = prevResults.filter(item => item.label.toLowerCase().includes(newQuery.toLowerCase()));
        setOwnerSuggestions(filtered);
        return;
      }

      try {
        const { results = [] } = await outCommand({
          type: OutCommand.getCorporationNames,
          data: { search: newQuery },
        });
        setOwnerSuggestions(results);
        setPrevQuery(newQuery);
        setPrevResults(results);
      } catch (err) {
        console.error('Failed to fetch owners:', err);
        setOwnerSuggestions([]);
      }
    },
    [prevQuery, prevResults, outCommand],
  );

  useEffect(() => {
    setEditData(structure ?? null);
    if (structure) {
      setOwner(structure.owner ?? '');
    } else {
      setOwner('');
    }
  }, [structure]);

  if (!editData) return null;

  const handleChange = (field: keyof StructureItem, val: string) => {
    if (field === 'typeId' || field === 'type') return;
    setEditData(prev => (prev ? { ...prev, [field]: val } : null));
  };

  const handleStatusChange = (val: string) => {
    setEditData(prev => (prev ? { ...prev, status: val as StructureStatus } : null));
  };

  const handleSaveClick = async () => {
    if (!editData) return;
    if (editData.ownerId) {
      try {
        const { ticker } = await outCommand({
          type: OutCommand.getCorporationTicker,
          data: { corp_id: editData.ownerId },
        });
        editData.ownerTicker = ticker ?? '';
      } catch (err) {
        console.error('Failed to fetch ticker:', err);
        editData.ownerTicker = '';
      }
    }
    console.log(editData);
    onSave(editData);
  };

  const handleDeleteClick = () => {
    if (editData) {
      onDelete(editData.id);
      onClose();
    }
  };

  return (
    <Dialog
      visible={visible}
      onHide={onClose}
      header="Edit Structure"
      className={clsx('myStructuresDialog', 'text-stone-200 w-full max-w-md')}
    >
      <div className="flex flex-col gap-2 text-[14px]">
        <label className="grid grid-cols-[100px_250px_1fr] gap-2 items-center">
          <span>Type:</span>
          <input readOnly className="p-inputtext p-component cursor-not-allowed" value={editData.type ?? ''} />
        </label>

        <label className="grid grid-cols-[100px_250px_1fr] gap-2 items-center">
          <span>Name:</span>
          <input
            className="p-inputtext p-component"
            value={editData.name ?? ''}
            onChange={e => handleChange('name', e.target.value)}
          />
        </label>

        <label className="grid grid-cols-[100px_250px_1fr] gap-2 items-center">
          <span>Owner:</span>
          <AutoComplete
            id="owner"
            value={owner}
            suggestions={ownerSuggestions}
            completeMethod={searchOwners}
            minLength={3}
            delay={400}
            field="label"
            placeholder="Corporation name..."
            onChange={e => setOwner(e.value)}
            onSelect={e => {
              console.log('Selected owner:', e.value);
              setOwner(e.value.label);
              setEditData(prev =>
                prev
                  ? {
                      ...prev,
                      owner: e.value.label,
                      ownerId: e.value.value,
                    }
                  : null,
              );
            }}
          />
        </label>

        <label className="grid grid-cols-[100px_250px_1fr] gap-2 items-center">
          <span>Status:</span>
          <select
            className="p-inputtext p-component"
            value={editData.status}
            onChange={e => handleStatusChange(e.target.value)}
          >
            <option value="Powered">Powered</option>
            <option value="Anchoring">Anchoring</option>
            <option value="Unanchoring">Unanchoring</option>
            <option value="Low Power">Low Power</option>
            <option value="Abandoned">Abandoned</option>
            <option value="Reinforced">Reinforced</option>
          </select>
        </label>

        {statusesRequiringTimer.includes(editData.status) && (
          <label className="grid grid-cols-[100px_250px_1fr] gap-2 items-center">
            <span>End Time:</span>
            <input
              type="datetime-local"
              className="p-inputtext p-component"
              value={editData.endTime?.substring(0, 16) || ''}
              onChange={e => handleChange('endTime', e.target.value)}
            />
          </label>
        )}

        <label className="grid grid-cols-[100px_1fr] gap-2 items-start mt-2">
          <span className="mt-1">Notes:</span>
          <textarea
            className="p-inputtext p-component resize-none h-24"
            value={editData.notes ?? ''}
            onChange={e => handleChange('notes', e.target.value)}
          />
        </label>
      </div>

      <div className="flex justify-end items-center gap-2 mt-4">
        <Button label="Delete" severity="danger" className="p-button-sm" onClick={handleDeleteClick} />
        <Button label="Save" className="p-button-sm" onClick={handleSaveClick} />
      </div>
    </Dialog>
  );
};
