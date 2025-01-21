// useKillsWidgetSettings.ts

import { useMemo, useCallback } from 'react';
import useLocalStorageState from 'use-local-storage-state';

export interface KillsWidgetSettings {
  compact: boolean;
  showAll: boolean;
  excludedSystems: number[];
}

export const KILL_WIDGET_DEFAULT: KillsWidgetSettings = {
  compact: false,
  showAll: false,
  excludedSystems: [],
};

export function useKillsWidgetSettings() {
  const [rawValue, setRawValue] = useLocalStorageState<KillsWidgetSettings | undefined>('kills:widget:settings');

  const value = useMemo<KillsWidgetSettings>(() => {
    if (!rawValue) {
      return KILL_WIDGET_DEFAULT;
    }
    return {
      ...KILL_WIDGET_DEFAULT,
      ...rawValue,
      excludedSystems: Array.isArray(rawValue.excludedSystems) ? rawValue.excludedSystems : [],
    };
  }, [rawValue]);

  const setValue = useCallback(
    (newVal: KillsWidgetSettings | ((prev: KillsWidgetSettings) => KillsWidgetSettings)) => {
      setRawValue(prev => {
        const prevMerged = prev
          ? {
              ...KILL_WIDGET_DEFAULT,
              ...prev,
              excludedSystems: Array.isArray(prev.excludedSystems) ? prev.excludedSystems : [],
            }
          : KILL_WIDGET_DEFAULT;

        const nextValue = typeof newVal === 'function' ? newVal(prevMerged) : newVal;
        return nextValue;
      });
    },
    [setRawValue],
  );

  return [value, setValue] as const;
}
