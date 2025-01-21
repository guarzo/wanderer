import useLocalStorageState from 'use-local-storage-state';

export interface KillsWidgetSettings {
  compact: boolean;
  showAll: boolean;
  version: number;
}

export const KILL_WIDGET_DEFAULT: KillsWidgetSettings = {
  compact: false,
  showAll: false,
  version: 0,
};

export function useKillsWidgetSettings() {
  return useLocalStorageState<KillsWidgetSettings>('kills:widget:settings', {
    defaultValue: KILL_WIDGET_DEFAULT,
  });
}
