import { useCallback, useEffect, useRef, useState, useMemo } from 'react';
import { Dialog } from 'primereact/dialog';
import { Button } from 'primereact/button';
import { IconField } from 'primereact/iconfield';
import { InputText } from 'primereact/inputtext';
import { InputTextarea } from 'primereact/inputtextarea';
import { AutoComplete } from 'primereact/autocomplete';
import { Checkbox } from 'primereact/checkbox';

import { TooltipPosition, WdImageSize, WdImgButton } from '@/hooks/Mapper/components/ui-kit';
import { getSystemById } from '@/hooks/Mapper/helpers';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand } from '@/hooks/Mapper/types';
import { LabelsManager } from '@/hooks/Mapper/utils/labelsManager.ts';
import { isWormholeSpace } from '../../../map/helpers/isWormholeSpace';

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

function parseTagString(str: string): string[] {
  if (!str) return [];
  return str
    .trim()
    .split(/\s+/)
    .map(item => item.replace(/^\*/, ''))
    .filter(Boolean);
}

function toTagString(arr: string[]): string {
  return arr.map(code => `*${code}`).join(' ');
}

function extractKnownFlagsFromLabel(label: string): { leftover: string; flags: string[] } {
  const parts = label.trim().split(/\s+/);
  const validCodes = new Set(CHECKBOX_ITEMS.map(item => item.code));
  const recognizedFlags: string[] = [];
  const leftoverParts: string[] = [];
  for (const part of parts) {
    const candidate = part.replace(/^\*/, '');
    if (validCodes.has(candidate)) {
      recognizedFlags.push(candidate);
    } else {
      leftoverParts.push(part);
    }
  }
  return { leftover: leftoverParts.join(' '), flags: recognizedFlags };
}

interface OwnerSuggestion {
  name: string;
  ticker: string;
  id: string;
  type: 'corp' | 'alliance';
  formatted: string;
}

interface CustomSystemSettingsDialogProps {
  systemId: string;
  visible: boolean;
  setVisible: (visible: boolean) => void;
}

export const CustomSystemSettingsDialog = ({ systemId, visible, setVisible }: CustomSystemSettingsDialogProps) => {
  const {
    data: { systems },
    outCommand,
  } = useMapRootState();
  const system = getSystemById(systems, systemId);
  const isWormhole = system ? isWormholeSpace(system.system_static_info.system_class) : false;

  const [name, setName] = useState('');
  const [label, setLabel] = useState('');
  const [temporaryName, setTemporaryName] = useState('');
  const [description, setDescription] = useState('');

  const [ownerName, setOwnerName] = useState('');
  const [ownerId, setOwnerId] = useState('');
  const [ownerType, setOwnerType] = useState<'corp' | 'alliance' | ''>('');

  const [ownerSuggestions, setOwnerSuggestions] = useState<OwnerSuggestion[]>([]);
  const [prevOwnerQuery, setPrevOwnerQuery] = useState('');
  const [prevOwnerResults, setPrevOwnerResults] = useState<OwnerSuggestion[]>([]);

  const [selectedFlags, setSelectedFlags] = useState<string[]>([]);

  const tickerSearchRegex = /^[A-Za-z0-9 .]{1,5}$/;

  const tickerCacheRef = useRef<Record<string, string>>({});

  const inputRef = useRef<HTMLInputElement>(null);

  const dataRef = useRef({
    name,
    label,
    temporaryName,
    description,
    ownerName,
    ownerId,
    ownerType,
    system,
    selectedFlags,
  });
  dataRef.current = { name, label, temporaryName, description, ownerName, ownerId, ownerType, system, selectedFlags };

  useEffect(() => {
    if (!system) return;

    const labelsManager = new LabelsManager(system.labels || '');
    setName(system.name || '');
    setLabel(labelsManager.customLabel);
    setTemporaryName(system.temporary_name || '');
    setDescription(system.description || '');

    setOwnerId(system.owner_id || '');
    setOwnerType((system.owner_type as 'corp' | 'alliance') || '');

    if (system.owner_id && system.owner_type) {
      if (system.owner_type === 'corp') {
        outCommand({
          type: OutCommand.getCorporationTicker,
          data: { corp_id: system.owner_id },
        }).then(({ ticker }) => setOwnerName(ticker || ''));
      } else {
        outCommand({
          type: OutCommand.getAllianceTicker,
          data: { alliance_id: system.owner_id },
        }).then(({ ticker }) => setOwnerName(ticker || ''));
      }
    } else {
      setOwnerName('');
    }

    if (system.custom_flags) {
      setSelectedFlags(parseTagString(system.custom_flags));
    } else {
      const extracted = extractKnownFlagsFromLabel(labelsManager.customLabel || '');
      if (extracted.flags.length > 0) {
        setSelectedFlags(extracted.flags);
        setLabel(extracted.leftover);
      } else {
        setSelectedFlags([]);
      }
    }
  }, [outCommand, system]);

  const searchOwners = useCallback(
    async (e: { query: string }) => {
      const newQuery = e.query.trim();
      if (!newQuery) {
        setOwnerSuggestions([]);
        setPrevOwnerQuery('');
        setPrevOwnerResults([]);
        return;
      }

      if (prevOwnerQuery && newQuery.startsWith(prevOwnerQuery)) {
        const filtered = prevOwnerResults.filter(
          s =>
            s.formatted.toLowerCase().includes(newQuery.toLowerCase()) ||
            s.name.toLowerCase().includes(newQuery.toLowerCase()) ||
            s.ticker.toLowerCase().includes(newQuery.toLowerCase()),
        );
        if (
          filtered.length > 0 ||
          !(newQuery.length >= 4 && newQuery.length <= 5 && tickerSearchRegex.test(newQuery))
        ) {
          setOwnerSuggestions(filtered);
          return;
        }
      }

      try {
        const [corpRes, allianceRes] = await Promise.all([
          outCommand({ type: OutCommand.getCorporationNames, data: { search: newQuery } }),
          outCommand({ type: OutCommand.getAllianceNames, data: { search: newQuery } }),
        ]);
        const corpItems: OwnerSuggestion[] = (corpRes?.results || []).map((r: { label: string; value: string }) => {
          return {
            name: r.label,
            ticker: '',
            id: r.value,
            type: 'corp' as const,
            formatted: r.label,
          };
        });
        const allianceItems: OwnerSuggestion[] = (allianceRes?.results || []).map(
          (r: { label: string; value: string }) => {
            return {
              name: r.label,
              ticker: '',
              id: r.value,
              type: 'alliance' as const,
              formatted: r.label,
            };
          },
        );
        let merged: OwnerSuggestion[] = [...corpItems, ...allianceItems];
        merged = await Promise.all(
          merged.map(async suggestion => {
            if (!suggestion.ticker) {
              const cached = tickerCacheRef.current[suggestion.id];
              if (cached) {
                suggestion.ticker = cached;
              } else {
                try {
                  let result;
                  if (suggestion.type === 'corp') {
                    result = await outCommand({
                      type: OutCommand.getCorporationTicker,
                      data: { corp_id: suggestion.id },
                    });
                  } else {
                    result = await outCommand({
                      type: OutCommand.getAllianceTicker,
                      data: { alliance_id: suggestion.id },
                    });
                  }
                  const ticker = result?.ticker || '';
                  tickerCacheRef.current[suggestion.id] = ticker;
                  suggestion.ticker = ticker;
                } catch (error) {
                  console.error('Failed to fetch ticker for suggestion', suggestion, error);
                }
              }
            }
            suggestion.formatted = suggestion.ticker ? `(${suggestion.ticker}) ${suggestion.name}` : suggestion.name;
            return suggestion;
          }),
        );
        console.log('Updated suggestions with ticker:', merged);
        setOwnerSuggestions(merged);
        setPrevOwnerQuery(newQuery);
        setPrevOwnerResults(merged);
      } catch (err) {
        console.error('Failed to fetch owners:', err);
        setOwnerSuggestions([]);
      }
    },
    [outCommand, prevOwnerQuery, prevOwnerResults, tickerSearchRegex],
  );

  const handleCustomLabelInput = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const raw = e.target.value.toUpperCase();
    const cleaned = raw.replace(/[^A-Z0-9\-[\](){} \s.]/g, '');
    setLabel(cleaned);
  }, []);

  const handleInput = useCallback((e: React.FormEvent<HTMLInputElement>) => {
    e.currentTarget.value = e.currentTarget.value.replace(/[^A-Z0-9a-z\-[\](){} \s.]/g, '');
  }, []);

  const handleCheckboxChange = useCallback((code: string, checked: boolean) => {
    setSelectedFlags(prev => (checked ? [...prev, code] : prev.filter(item => item !== code)));
  }, []);

  const validTickerRegex = useMemo(() => /^[A-Z0-9a-z\-[\](){} .]+$/, []);

  const handleOwnerBlur = useCallback(() => {
    if (ownerName) {
      const foundSuggestion = prevOwnerResults.find(s => {
        const formatted = s.formatted.toLowerCase();
        return (
          ownerName.trim().toLowerCase() === formatted ||
          ownerName.trim().toLowerCase() === s.name.toLowerCase() ||
          ownerName.trim().toLowerCase() === s.ticker.toLowerCase()
        );
      });
      console.log('handleOwnerBlur found suggestion:', foundSuggestion);
      if (foundSuggestion) {
        setOwnerName(foundSuggestion.formatted);
        setOwnerId(foundSuggestion.id);
        setOwnerType(foundSuggestion.type);
      } else if (validTickerRegex.test(ownerName)) {
        setOwnerName(ownerName);
        setOwnerId('');
        setOwnerType('');
      } else {
        setOwnerName('');
        setOwnerId('');
        setOwnerType('');
      }
    }
  }, [ownerName, prevOwnerResults, validTickerRegex]);

  const handleSave = useCallback(() => {
    const { name, label, temporaryName, description, ownerId, ownerType, system, selectedFlags } = dataRef.current;
    if (!system) return;

    const lm = new LabelsManager(system.labels ?? '');
    lm.updateCustomLabel(label);
    outCommand({
      type: OutCommand.updateSystemLabels,
      data: { system_id: systemId, value: lm.toString() },
    });
    outCommand({
      type: OutCommand.updateSystemName,
      data: { system_id: systemId, value: name.trim() || system.system_static_info.solar_system_name },
    });
    outCommand({
      type: OutCommand.updateSystemTemporaryName,
      data: { system_id: systemId, value: temporaryName },
    });
    outCommand({
      type: OutCommand.updateSystemDescription,
      data: { system_id: systemId, value: description },
    });
    outCommand({
      type: OutCommand.updateSystemOwner,
      data: { system_id: systemId, owner_id: ownerId, owner_type: ownerType },
    });
    const flagsStr = toTagString(selectedFlags);
    outCommand({
      type: OutCommand.updateSystemCustomFlags,
      data: { system_id: systemId, value: flagsStr === '' ? null : flagsStr },
    });
    setVisible(false);
  }, [outCommand, setVisible, systemId]);

  const onShow = useCallback(() => {
    inputRef.current?.focus();
  }, []);

  return (
    <Dialog
      header="System settings"
      visible={visible}
      draggable={false}
      style={{ width: '450px' }}
      onShow={onShow}
      onHide={() => {
        if (visible) setVisible(false);
      }}
    >
      <form
        onSubmit={e => {
          e.preventDefault();
          handleSave();
        }}
      >
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-2">
            <div className="flex flex-col gap-1">
              <label htmlFor="temporaryName">Bookmark Name</label>
              <IconField>
                {temporaryName && (
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
                  onChange={e => setTemporaryName(e.target.value)}
                />
              </IconField>
            </div>
            {!isWormhole ? (
              <div className="flex flex-col gap-1">
                <label htmlFor="label">Tag (4-j, 7-A, etc)</label>
                <IconField>
                  {label !== '' && (
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
                    aria-describedby="label"
                    autoComplete="off"
                    value={label}
                    maxLength={5}
                    onChange={handleCustomLabelInput}
                  />
                </IconField>
              </div>
            ) : (
              <>
                <div className="flex flex-col gap-1">
                  <label htmlFor="owner">Ticker</label>
                  <IconField>
                    {ownerName && (
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
                      suggestions={ownerSuggestions}
                      completeMethod={searchOwners}
                      value={ownerName}
                      forceSelection={true}
                      onInput={handleInput}
                      itemTemplate={(item: OwnerSuggestion) => <div>{item.formatted}</div>}
                      onSelect={e => {
                        const selected = e.value as OwnerSuggestion;
                        setOwnerName(selected.formatted);
                        setOwnerId(selected.id);
                        setOwnerType(selected.type);
                      }}
                      onChange={e => {
                        if (!e.value) {
                          setOwnerName('');
                          setOwnerId('');
                          setOwnerType('');
                        } else if (typeof e.value === 'string') {
                          setOwnerName(e.value);
                          setOwnerId('');
                          setOwnerType('');
                        } else {
                          const selected = e.value as OwnerSuggestion;
                          setOwnerName(selected.formatted);
                          setOwnerId(selected.id);
                          setOwnerType(selected.type);
                        }
                      }}
                      onBlur={handleOwnerBlur}
                    />
                  </IconField>
                </div>
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
                            onChange={e => handleCheckboxChange(item.code, e.checked as boolean)}
                          />
                          <label htmlFor={item.code}>{item.label}</label>
                        </div>
                      );
                    })}
                  </div>
                </div>
              </>
            )}
            <div className="flex flex-col gap-1">
              <label htmlFor="description">Notes</label>
              <InputTextarea
                id="description"
                rows={5}
                autoResize
                value={description}
                onChange={e => setDescription(e.target.value)}
              />
            </div>
          </div>
          <div className="flex justify-end gap-2">
            <Button onClick={handleSave} outlined size="small" label="Save" />
          </div>
        </div>
      </form>
    </Dialog>
  );
};
