/* eslint-disable react/prop-types */
import React, { useRef, useCallback, useMemo, useEffect } from 'react';
import debounce from 'lodash.debounce';
import { Dialog } from 'primereact/dialog';
import { Button } from 'primereact/button';
import { IconField } from 'primereact/iconfield';
import { InputText } from 'primereact/inputtext';
import { InputTextarea } from 'primereact/inputtextarea';
import { AutoComplete } from 'primereact/autocomplete';
import { Checkbox } from 'primereact/checkbox';

import { TooltipPosition, WdImageSize, WdImgButton } from '@/hooks/Mapper/components/ui-kit';
import { CustomSystemSettingsDialogProps } from './helpers';
import { useCustomSystemSettings } from './hooks/useCustomSystemSettings';
import { isWormholeSpace } from '../../../map/helpers/isWormholeSpace';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';

const CHECKBOX_ITEMS = [
  { code: 'B', label: 'Blobber' },
  { code: 'MB', label: 'Marauder Blobber' },
  { code: 'C', label: 'Check Notes' },
  { code: 'F', label: 'Farm' },
  { code: 'PW', label: 'Prewarp Sites' },
  { code: 'PT', label: 'POS Trash' },
  { code: 'DNP', label: 'Do Not Pod' },
  { code: 'CF', label: 'Coward Finder' },
];

export const CustomSystemSettingsDialog: React.FC<CustomSystemSettingsDialogProps> = ({
  systemId,
  visible,
  setVisible,
}) => {
  const inputRef = useRef<HTMLInputElement>(null);

  const {
    data: { options: mapOptions },
  } = useMapRootState();
  const hasIntelSource = !!mapOptions?.intel_source_map_id;

  const {
    system,
    label,
    setLabel,
    temporaryName,
    setTemporaryName,
    description,
    setDescription,
    ownerName,
    setOwnerName,
    setOwnerId,
    setOwnerType,
    selectedFlags,
    setSelectedFlags,
    ownerSuggestions,
    setOwnerSuggestions,
    searchOwners,
    handleOwnerSelect,
    handleOwnerChange,
    handleSave,
  } = useCustomSystemSettings(systemId, visible);

  const isWormhole = system ? isWormholeSpace(system.system_static_info.system_class) : false;

  const onShow = useCallback(() => {
    inputRef.current?.focus();
  }, []);

  // Wrap the searchOwners function with a debounce of 300ms.
  const debouncedSearch = useMemo(
    () =>
      debounce(async (query: string) => {
        const results = await searchOwners(query);
        setOwnerSuggestions(results);
      }, 300),
    [searchOwners, setOwnerSuggestions],
  );

  // Clean up the debounce on unmount.
  useEffect(() => {
    return () => {
      debouncedSearch.cancel();
    };
  }, [debouncedSearch]);

  const completeMethod = useCallback(
    (e: { originalEvent: React.SyntheticEvent; query: string }) => {
      if (e.query && e.query.length >= 3) {
        debouncedSearch(e.query);
      } else {
        setOwnerSuggestions([]);
      }
    },
    [debouncedSearch, setOwnerSuggestions],
  );

  // This handler enforces uppercase letters and numbers only for the bookmark name.
  const handleTemporaryNameChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      let value = e.target.value.toUpperCase();
      // Allow letters, numbers, spaces and forward slashes
      value = value.replace(/[^A-Z0-9 /]/g, '');
      setTemporaryName(value);
    },
    [setTemporaryName],
  );

  const onSubmit = useCallback(
    async (e: React.FormEvent<HTMLFormElement>) => {
      e.preventDefault();
      if (hasIntelSource) return;
      console.log('[CustomSystemSettingsDialog] Form submitted with owner values:', {
        ownerName,
        ownerId: system?.owner_id,
        ownerType: system?.owner_type,
      });
      await handleSave();
      setVisible(false);
    },
    [handleSave, ownerName, system, setVisible, hasIntelSource],
  );

  return (
    <Dialog
      header="System settings"
      visible={visible}
      draggable={false}
      style={{ width: '450px' }}
      onShow={onShow}
      onHide={() => setVisible(false)}
    >
      <form onSubmit={onSubmit}>
        <div className="flex flex-col gap-3">
          {hasIntelSource && (
            <div className="text-stone-400 text-[11px] bg-blue-900/20 border border-blue-500/30 rounded px-2 py-1">
              <i className="pi pi-info-circle mr-1" />
              These fields are managed by the intel source map and cannot be edited here.
            </div>
          )}
          <div className="flex flex-col gap-2">
            {/* Bookmark Name Field */}
            <div className="flex flex-col gap-1">
              <label htmlFor="temporaryName">Bookmark Name</label>
              <IconField>
                {!hasIntelSource && temporaryName && (
                  <WdImgButton
                    className="pi pi-trash text-red-400"
                    textSize={WdImageSize.large}
                    tooltip={{
                      content: 'Remove temporary name',
                      className: 'pi p-input-icon',
                      position: TooltipPosition.top,
                    }}
                    onClick={() => setTemporaryName('')}
                  />
                )}
                <InputText
                  id="temporaryName"
                  autoComplete="off"
                  ref={inputRef}
                  maxLength={10}
                  value={temporaryName}
                  disabled={hasIntelSource}
                  onChange={handleTemporaryNameChange}
                />
              </IconField>
            </div>
            {/* Conditional rendering for Tag vs. Ticker/Flags */}
            {!isWormhole ? (
              <div className="flex flex-col gap-1">
                <label htmlFor="label">Tag (4-j, 7-A, etc)</label>
                <IconField>
                  {!hasIntelSource && label && (
                    <WdImgButton
                      className="pi pi-trash text-red-400"
                      textSize={WdImageSize.large}
                      tooltip={{
                        content: 'Remove custom tag',
                        className: 'pi p-input-icon',
                        position: TooltipPosition.top,
                      }}
                      onClick={() => setLabel('')}
                    />
                  )}
                  <InputText
                    id="label"
                    autoComplete="off"
                    value={label}
                    maxLength={5}
                    disabled={hasIntelSource}
                    onChange={e => setLabel(e.target.value.toUpperCase())}
                  />
                </IconField>
              </div>
            ) : (
              <>
                {/* Ticker Field */}
                <div className="flex flex-col gap-1">
                  <label htmlFor="owner">Ticker</label>
                  <IconField>
                    {!hasIntelSource && ownerName && (
                      <WdImgButton
                        className="pi pi-trash text-red-400"
                        textSize={WdImageSize.large}
                        tooltip={{
                          content: 'Clear Owner',
                          className: 'pi p-input-icon',
                          position: TooltipPosition.top,
                        }}
                        onClick={() => {
                          setOwnerName('');
                          setOwnerId('');
                          setOwnerType('');
                        }}
                      />
                    )}
                    <AutoComplete
                      id="owner"
                      className="w-full"
                      placeholder="Type to search (corp/alliance)"
                      value={ownerName}
                      suggestions={ownerSuggestions}
                      completeMethod={completeMethod}
                      onChange={e => handleOwnerChange(e.value)}
                      onSelect={e => handleOwnerSelect(e.value)}
                      field="formatted"
                      forceSelection={false}
                      disabled={hasIntelSource}
                    />
                  </IconField>
                </div>
                {/* Custom Flags Field */}
                <div className="flex flex-col gap-1">
                  <label>Custom Flags</label>
                  <div className="grid grid-cols-2 gap-2 pl-2">
                    {CHECKBOX_ITEMS.map(item => {
                      const checked = selectedFlags.includes(item.code);
                      return (
                        <div key={item.code} className="flex items-center gap-2">
                          <Checkbox
                            inputId={item.code}
                            checked={checked}
                            disabled={hasIntelSource}
                            onChange={e => {
                              const isChecked = e.checked ?? false;
                              if (isChecked) {
                                setSelectedFlags(prev => [...prev, item.code]);
                              } else {
                                setSelectedFlags(prev => prev.filter(flag => flag !== item.code));
                              }
                            }}
                          />
                          <label htmlFor={item.code}>{item.label}</label>
                        </div>
                      );
                    })}
                  </div>
                </div>
              </>
            )}
            {/* Notes Field */}
            <div className="flex flex-col gap-1">
              <label htmlFor="description">Notes</label>
              <InputTextarea
                id="description"
                rows={5}
                autoResize
                value={description}
                disabled={hasIntelSource}
                onChange={e => setDescription(e.target.value)}
              />
            </div>
          </div>
          <div className="flex justify-end gap-2">
            <Button type="submit" outlined size="small" label="Save" disabled={hasIntelSource} />
          </div>
        </div>
      </form>
    </Dialog>
  );
};
