import { useCallback, useRef, useState } from 'react';
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
import { useMapGetOption } from '@/hooks/Mapper/mapRootProvider/hooks/api';
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

function extractKnownFlagsFromLabel(label: string): {
  leftover: string;
  flags: string[];
} {
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

  return {
    leftover: leftoverParts.join(' '),
    flags: recognizedFlags,
  };
}

interface SystemSettingsDialogProps {
  systemId: string;
  visible: boolean;
  setVisible: (visible: boolean) => void;
}

export const SystemSettingsDialog = ({ systemId, visible, setVisible }: SystemSettingsDialogProps) => {
  const {
    data: { systems },
    outCommand,
  } = useMapRootState();

  const isTempSystemNameEnabled = useMapGetOption('show_temp_system_name') === 'true';

  const system = getSystemById(systems, systemId);
  const isWormhole = system ? isWormholeSpace(system.system_static_info.system_class) : false;

  const [name, setName] = useState('');
  const [label, setLabel] = useState('');
  const [temporaryName, setTemporaryName] = useState('');
  const [description, setDescription] = useState('');

  const [ownerName, setOwnerName] = useState('');
  const [ownerId, setOwnerId] = useState('');
  const [ownerType, setOwnerType] = useState<'corp' | 'alliance' | ''>('');

  const [ownerSuggestions, setOwnerSuggestions] = useState<string[]>([]);
  const [ownerMap, setOwnerMap] = useState<Record<string, { id: string; type: 'corp' | 'alliance' }>>({});

  const [prevOwnerQuery, setPrevOwnerQuery] = useState('');
  const [prevOwnerResults, setPrevOwnerResults] = useState<string[]>([]);

  const [selectedFlags, setSelectedFlags] = useState<string[]>([]);

  // ref for autofocus on "bookmark name"
  const bookmarkNameRef = useRef<HTMLInputElement>(null);

  // We'll reset the dialog’s state each time it opens
  const onShow = useCallback(() => {
    if (!system) return;

    const labelsManager = new LabelsManager(system.labels || '');
    setName(system.name || '');
    setLabel(labelsManager.customLabel || '');
    setTemporaryName(system.temporary_name || '');
    setDescription(system.description || '');

    if (system.owner_id && system.owner_type) {
      if (system.owner_type === 'corp') {
        outCommand({
          type: OutCommand.getCorporationTicker,
          data: { corp_id: system.owner_id },
        }).then(({ ticker }) => {
          setOwnerName(ticker || '');
        });
      } else {
        outCommand({
          type: OutCommand.getAllianceTicker,
          data: { alliance_id: system.owner_id },
        }).then(({ ticker }) => {
          setOwnerName(ticker || '');
        });
      }
      setOwnerId(system.owner_id);
      setOwnerType(system.owner_type as 'corp' | 'alliance');
    } else {
      setOwnerName('');
      setOwnerId('');
      setOwnerType('');
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

    // Delay focus so the dialog finishes rendering first
    setTimeout(() => {
      bookmarkNameRef.current?.focus();
    }, 0);
  }, [system, outCommand]);

  const dataRef = useRef({
    name,
    label,
    temporaryName,
    description,
    ownerName,
    ownerId,
    ownerType,
    selectedFlags,
    system,
  });

  dataRef.current = {
    name,
    label,
    temporaryName,
    description,
    ownerName,
    ownerId,
    ownerType,
    selectedFlags,
    system,
  };

  const handleSave = useCallback(() => {
    const { name, label, temporaryName, description, ownerId, ownerType, selectedFlags, system } = dataRef.current;
    if (!system) return;

    const lm = new LabelsManager(system.labels ?? '');
    lm.updateCustomLabel(label);

    outCommand({
      type: OutCommand.updateSystemLabels,
      data: {
        system_id: systemId,
        value: lm.toString(),
      },
    });

    outCommand({
      type: OutCommand.updateSystemName,
      data: {
        system_id: systemId,
        value: name.trim() || system.system_static_info.solar_system_name,
      },
    });

    outCommand({
      type: OutCommand.updateSystemTemporaryName,
      data: {
        system_id: systemId,
        value: temporaryName,
      },
    });

    outCommand({
      type: OutCommand.updateSystemDescription,
      data: {
        system_id: systemId,
        value: description,
      },
    });

    outCommand({
      type: OutCommand.updateSystemOwner,
      data: {
        system_id: systemId,
        owner_id: ownerId,
        owner_type: ownerType,
      },
    });

    const flagsStr = toTagString(selectedFlags);
    outCommand({
      type: OutCommand.updateSystemCustomFlags,
      data: {
        system_id: systemId,
        value: flagsStr,
      },
    });

    setVisible(false);
  }, [outCommand, setVisible, systemId]);

  // handle searching owners
  const searchOwners = useCallback(
    async (e: { query: string }) => {
      const newQuery = e.query.trim();
      if (!newQuery) {
        setOwnerSuggestions([]);
        setOwnerMap({});
        return;
      }

      if (newQuery.length < 3) {
        setOwnerSuggestions([]);
        setOwnerMap({});
        return;
      }

      // If continuing from a previous query, just filter old results
      if (newQuery.startsWith(prevOwnerQuery) && prevOwnerResults.length > 0) {
        const filtered = prevOwnerResults.filter(item => item.toLowerCase().includes(newQuery.toLowerCase()));
        setOwnerSuggestions(filtered);
        return;
      }

      try {
        const [corpRes, allianceRes] = await Promise.all([
          outCommand({ type: OutCommand.getCorporationNames, data: { search: newQuery } }),
          outCommand({ type: OutCommand.getAllianceNames, data: { search: newQuery } }),
        ]);

        const corpItems = (corpRes?.results || []).map((r: any) => ({
          name: r.label,
          id: r.value,
          type: 'corp' as const,
        }));
        const allianceItems = (allianceRes?.results || []).map((r: any) => ({
          name: r.label,
          id: r.value,
          type: 'alliance' as const,
        }));

        const merged = [...corpItems, ...allianceItems];
        const nameList = merged.map(m => m.name);
        const mapObj: Record<string, { id: string; type: 'corp' | 'alliance' }> = {};
        for (const item of merged) {
          mapObj[item.name] = { id: item.id, type: item.type };
        }

        setOwnerSuggestions(nameList);
        setOwnerMap(mapObj);
        setPrevOwnerQuery(newQuery);
        setPrevOwnerResults(nameList);
      } catch (err) {
        console.error('Failed to fetch owners:', err);
        setOwnerSuggestions([]);
        setOwnerMap({});
      }
    },
    [outCommand, prevOwnerQuery, prevOwnerResults],
  );

  const handleCustomLabelInput = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const raw = e.target.value.toUpperCase();
    const cleaned = raw.replace(/[^A-Z0-9\-[\](){}]/g, '');
    setLabel(cleaned);
  }, []);

  const handleCheckboxChange = useCallback((code: string, checked: boolean) => {
    setSelectedFlags(prev => (checked ? [...prev, code] : prev.filter(item => item !== code)));
  }, []);

  return (
    <Dialog
      header="System settings"
      visible={visible}
      draggable={false}
      style={{ width: '450px' }}
      onShow={onShow}
      onHide={() => {
        if (!visible) return;
        setVisible(false);
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
            {isTempSystemNameEnabled && (
              <div className="flex flex-col gap-1">
                <label htmlFor="temporaryName">Bookmark Name</label>
                <IconField>
                  {temporaryName && (
                    <WdImgButton
                      className="pi pi-trash text-red-400"
                      textSize={WdImageSize.large}
                      tooltip={{
                        className: 'pi p-input-icon',
                        content: 'Remove temporary name',
                        position: TooltipPosition.top,
                      }}
                      onClick={() => setTemporaryName('')}
                    />
                  )}
                  <InputText
                    id="temporaryName"
                    ref={bookmarkNameRef} // <-- Use this ref for autofocus
                    autoComplete="off"
                    maxLength={10}
                    value={temporaryName}
                    onChange={e => setTemporaryName(e.target.value)}
                  />
                </IconField>
              </div>
            )}
            {!isWormhole && (
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
            )}
            {isWormhole && (
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
                    onSelect={e => {
                      const chosenName = e.value;
                      setOwnerName(chosenName);
                      const found = ownerMap[chosenName];
                      if (found) {
                        setOwnerId(found.id);
                        setOwnerType(found.type);
                      } else {
                        setOwnerId('');
                        setOwnerType('');
                      }
                    }}
                    onChange={e => {
                      setOwnerName(e.value);
                      setOwnerId('');
                      setOwnerType('');
                    }}
                  />
                </IconField>
              </div>
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
                        onChange={e => handleCheckboxChange(item.code, e.checked)}
                      />
                      <label htmlFor={item.code}>{item.label}</label>
                    </div>
                  );
                })}
              </div>
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
