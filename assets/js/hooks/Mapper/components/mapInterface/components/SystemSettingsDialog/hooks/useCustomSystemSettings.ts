import { useCallback, useEffect, useRef, useState } from 'react';
import { OutCommand } from '@/hooks/Mapper/types';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { getSystemById } from '@/hooks/Mapper/helpers';
import { LabelsManager } from '@/hooks/Mapper/utils/labelsManager';
import { parseTagString, toTagString } from '../helpers';
import { SolarSystemRawType } from '@/hooks/Mapper/types';

export interface OwnerSuggestion {
  label: string;
  value: string;
  corporation?: boolean;
  alliance?: boolean;
  formatted: string;
  name: string;
  ticker: string;
  id: string;
  type: 'corp' | 'alliance';
}

/**
 * Custom hook to manage the state and logic for the CustomSystemSettingsDialog.
 *
 * @param systemId - The ID of the system to edit.
 * @param visible - Whether the dialog is visible.
 */
export function useCustomSystemSettings(systemId: string, visible: boolean) {
  const {
    data: { systems },
    outCommand,
  } = useMapRootState();
  const system = getSystemById(systems, systemId);

  // Local state declarations.
  const [name, setName] = useState('');
  const [label, setLabel] = useState('');
  const [temporaryName, setTemporaryName] = useState('');
  const [description, setDescription] = useState('');
  const [ownerName, setOwnerName] = useState('');
  const [ownerId, setOwnerId] = useState('');
  const [ownerType, setOwnerType] = useState<'corp' | 'alliance' | ''>('');
  const [selectedFlags, setSelectedFlags] = useState<string[]>([]);
  const [prevOwnerQuery, setPrevOwnerQuery] = useState('');
  const [prevOwnerResults, setPrevOwnerResults] = useState<OwnerSuggestion[]>([]);
  const [ownerSuggestions, setOwnerSuggestions] = useState<OwnerSuggestion[]>([]);

  // Cache for ticker lookups.
  const tickerCacheRef = useRef<Record<string, string>>({});

  // Use a ref to ensure initialization only happens once per dialog open.
  const initializedRef = useRef(false);

  // Use refs to store owner info so we don't lose it when state updates.
  const ownerInfoRef = useRef<{
    ownerId: string;
    ownerType: 'corp' | 'alliance' | '';
    ownerName: string;
  }>({ ownerId: '', ownerType: '', ownerName: '' });

  // Initialization: only run when dialog is visible and not yet initialized.
  useEffect(() => {
    if (!visible) {
      // When the dialog is closed, reset the initialization flag.
      initializedRef.current = false;
      return;
    }
    if (visible && system && !initializedRef.current) {
      // Initialize text fields.
      setName(system.name || '');
      setDescription(system.description || '');
      setTemporaryName(system.temporary_name || '');

      // Handle owner ticker logic.
      if (system.owner_id && system.owner_type) {
        setOwnerId(system.owner_id || '');
        setOwnerType((system.owner_type as '' | 'corp' | 'alliance') || '');
        ownerInfoRef.current.ownerId = system.owner_id || '';
        ownerInfoRef.current.ownerType = (system.owner_type as '' | 'corp' | 'alliance') || '';

        const cacheKey = `${system.owner_type}_${system.owner_id}`;
        if (tickerCacheRef.current[cacheKey]) {
          setOwnerName(tickerCacheRef.current[cacheKey]);
          ownerInfoRef.current.ownerName = tickerCacheRef.current[cacheKey];
        } else {
          const systemWithTicker = system as SolarSystemRawType & { owner_ticker?: string | null };
          if (systemWithTicker.owner_ticker) {
            setOwnerName(systemWithTicker.owner_ticker);
            ownerInfoRef.current.ownerName = systemWithTicker.owner_ticker;
            tickerCacheRef.current[cacheKey] = systemWithTicker.owner_ticker;
          } else {
            if (system.owner_type === 'corp') {
              outCommand({
                type: OutCommand.getCorporationTicker,
                data: { corp_id: system.owner_id },
              }).then(({ ticker }) => {
                if (ticker) {
                  setOwnerName(ticker);
                  ownerInfoRef.current.ownerName = ticker;
                  tickerCacheRef.current[`corp_${system.owner_id}`] = ticker;
                }
              });
            } else if (system.owner_type === 'alliance') {
              outCommand({
                type: OutCommand.getAllianceTicker,
                data: { alliance_id: system.owner_id },
              }).then(({ ticker }) => {
                if (ticker) {
                  setOwnerName(ticker);
                  ownerInfoRef.current.ownerName = ticker;
                  tickerCacheRef.current[`alliance_${system.owner_id}`] = ticker;
                }
              });
            }
          }
        }
      } else if (system.owner_ticker) {
        // If we have just a ticker without ID/type, still display it
        setOwnerName(system.owner_ticker);
        ownerInfoRef.current.ownerName = system.owner_ticker;
        setOwnerId('');
        setOwnerType('');
        ownerInfoRef.current.ownerId = '';
        ownerInfoRef.current.ownerType = '';
      } else {
        setOwnerId('');
        setOwnerType('');
        setOwnerName('');
        ownerInfoRef.current.ownerId = '';
        ownerInfoRef.current.ownerType = '';
        ownerInfoRef.current.ownerName = '';
      }

      // Parse and set custom flags.
      if (system.custom_flags) {
        setSelectedFlags(parseTagString(system.custom_flags));
      } else {
        setSelectedFlags([]);
      }

      // Parse and set the custom label.
      try {
        const labelsObj = JSON.parse(system.labels || '{}');
        setLabel(labelsObj.customLabel || '');
      } catch (e) {
        setLabel('');
      }

      initializedRef.current = true;
    }
  }, [visible, system, outCommand]);

  // Searches for owner suggestions based on a query string.
  const searchOwners = useCallback(
    async (newQuery: string): Promise<OwnerSuggestion[]> => {
      if (newQuery.length < 3) return [];
      if (prevOwnerQuery && newQuery.startsWith(prevOwnerQuery) && prevOwnerResults.length > 0) {
        const filtered = prevOwnerResults.filter(item => item.formatted.toLowerCase().includes(newQuery.toLowerCase()));

        // Find exact ticker matches
        const exactMatches = filtered.filter(item => item.ticker.toLowerCase() === newQuery.toLowerCase());

        // Return exact matches first, then other filtered results
        if (exactMatches.length > 0) {
          const otherResults = filtered.filter(item => item.ticker.toLowerCase() !== newQuery.toLowerCase());
          return [...exactMatches, ...otherResults];
        }

        return filtered;
      }
      // Fetch suggestions for both corporations and alliances.
      const corpPromise = outCommand({
        type: OutCommand.getCorporationNames,
        data: { search: newQuery },
      }).catch(error => {
        console.error('[searchOwners] Corporation search error:', error);
        return null;
      });
      const alliancePromise = outCommand({
        type: OutCommand.getAllianceNames,
        data: { search: newQuery },
      }).catch(error => {
        console.error('[searchOwners] Alliance search error:', error);
        return null;
      });
      const [corpResponse, allianceResponse] = await Promise.all([corpPromise, alliancePromise]);

      const corpResults = corpResponse?.results || [];
      const allianceResults = allianceResponse?.results || [];

      const combinedResults: OwnerSuggestion[] = [
        ...corpResults.map((r: Omit<OwnerSuggestion, 'corporation' | 'alliance'>) => {
          if (r.ticker) {
            tickerCacheRef.current[`corp_${r.value}`] = r.ticker;
          }
          return { ...r, corporation: true, alliance: false } as OwnerSuggestion;
        }),
        ...allianceResults.map((r: Omit<OwnerSuggestion, 'corporation' | 'alliance'>) => {
          if (r.ticker) {
            tickerCacheRef.current[`alliance_${r.value}`] = r.ticker;
          }
          return { ...r, corporation: false, alliance: true } as OwnerSuggestion;
        }),
      ];

      // Find exact ticker matches
      const exactTickerMatches = combinedResults.filter(item => item.ticker.toLowerCase() === newQuery.toLowerCase());

      // If we have exact ticker matches, prioritize them
      if (exactTickerMatches.length > 0) {
        // Get other results that aren't exact ticker matches
        const otherResults = combinedResults.filter(item => item.ticker.toLowerCase() !== newQuery.toLowerCase());

        // Store all results for future filtering
        setPrevOwnerQuery(newQuery);
        setPrevOwnerResults([...exactTickerMatches, ...otherResults]);

        // Return exact matches first, then other results
        return [...exactTickerMatches, ...otherResults];
      }

      setPrevOwnerQuery(newQuery);
      setPrevOwnerResults(combinedResults);
      return combinedResults;
    },
    [prevOwnerQuery, prevOwnerResults, outCommand],
  );

  // Handler when an owner suggestion is selected.
  const handleOwnerSelect = useCallback(
    (selected: OwnerSuggestion) => {
      if (selected) {
        if (selected.ticker) {
          setOwnerName(selected.ticker);
          ownerInfoRef.current.ownerName = selected.ticker;

          // Cache the ticker
          const cacheKey = `${selected.type}_${selected.id}`;
          tickerCacheRef.current[cacheKey] = selected.ticker;
        } else {
          setOwnerName(selected.name);
          ownerInfoRef.current.ownerName = selected.name;
          if (selected.type === 'corp') {
            outCommand({
              type: OutCommand.getCorporationTicker,
              data: { corp_id: selected.id },
            }).then(({ ticker }) => {
              if (ticker) {
                tickerCacheRef.current[`corp_${selected.id}`] = ticker;
                setOwnerName(ticker);
                ownerInfoRef.current.ownerName = ticker;
              }
            });
          } else if (selected.type === 'alliance') {
            outCommand({
              type: OutCommand.getAllianceTicker,
              data: { alliance_id: selected.id },
            }).then(({ ticker }) => {
              if (ticker) {
                tickerCacheRef.current[`alliance_${selected.id}`] = ticker;
                setOwnerName(ticker);
                ownerInfoRef.current.ownerName = ticker;
              }
            });
          }
        }
        setOwnerId(selected.id);
        setOwnerType(selected.type);
        ownerInfoRef.current.ownerId = selected.id;
        ownerInfoRef.current.ownerType = selected.type;
      }
    },
    [outCommand],
  );

  // Handler for changes in the owner field.
  const handleOwnerChange = useCallback((value: string | OwnerSuggestion) => {
    if (value) {
      if (typeof value === 'string') {
        setOwnerName(value);
        ownerInfoRef.current.ownerName = value;
      } else {
        setOwnerName(value.name);
        setOwnerId(value.id);
        setOwnerType(value.type);
        ownerInfoRef.current.ownerName = value.name;
        ownerInfoRef.current.ownerId = value.id;
        ownerInfoRef.current.ownerType = value.type;
      }
    } else {
      setOwnerName('');
      setOwnerId('');
      setOwnerType('');
      ownerInfoRef.current.ownerName = '';
      ownerInfoRef.current.ownerId = '';
      ownerInfoRef.current.ownerType = '';
    }
  }, []);

  // Save handler that calls the update commands and returns a promise.
  const handleSave = useCallback(async () => {
    if (!system) return;

    // Use ownerInfoRef values instead of state values to ensure we have the most up-to-date info
    const currentOwnerId = ownerInfoRef.current.ownerId;
    const currentOwnerType = ownerInfoRef.current.ownerType;
    const currentOwnerName = ownerInfoRef.current.ownerName;
    const currentSystemId = system.id;

    // Update the ticker cache if we have valid owner info
    if (currentOwnerId && currentOwnerType && currentOwnerName) {
      const cacheKey = `${currentOwnerType}_${currentOwnerId}`;
      tickerCacheRef.current[cacheKey] = currentOwnerName;
    }

    const lm = new LabelsManager(system.labels ?? '');
    lm.updateCustomLabel(label);

    const updatePromises = [
      outCommand({
        type: OutCommand.updateSystemLabels,
        data: { system_id: currentSystemId, value: lm.toString() },
      }),
      outCommand({
        type: OutCommand.updateSystemName,
        data: {
          system_id: currentSystemId,
          value: name.trim() || system.system_static_info.solar_system_name,
        },
      }),
      outCommand({
        type: OutCommand.updateSystemTemporaryName,
        data: { system_id: currentSystemId, value: temporaryName },
      }),
      outCommand({
        type: OutCommand.updateSystemDescription,
        data: { system_id: currentSystemId, value: description },
      }),
    ];

    // Always send owner update with complete information
    const ownerData = {
      system_id: currentSystemId,
      owner_id: currentOwnerId === '' ? null : currentOwnerId,
      owner_type: currentOwnerType === '' ? null : currentOwnerType,
      owner_ticker: currentOwnerName === '' ? null : currentOwnerName,
    };

    updatePromises.push(
      outCommand({
        type: OutCommand.updateSystemOwner,
        data: ownerData,
      }),
    );

    const flagsStr = toTagString(selectedFlags);
    updatePromises.push(
      outCommand({
        type: OutCommand.updateSystemCustomFlags,
        data: { system_id: currentSystemId, value: flagsStr === '' ? null : flagsStr },
      }),
    );

    await Promise.all(updatePromises);
  }, [system, name, label, temporaryName, description, selectedFlags, outCommand]);

  return {
    system,
    name,
    setName,
    label,
    setLabel,
    temporaryName,
    setTemporaryName,
    description,
    setDescription,
    ownerName,
    setOwnerName,
    ownerId,
    setOwnerId,
    ownerType,
    setOwnerType,
    selectedFlags,
    setSelectedFlags,
    ownerSuggestions,
    setOwnerSuggestions,
    searchOwners,
    handleOwnerSelect,
    handleOwnerChange,
    handleSave,
  };
}
