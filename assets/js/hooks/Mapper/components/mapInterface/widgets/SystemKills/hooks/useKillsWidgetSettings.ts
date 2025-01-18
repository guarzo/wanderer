// useKillsWidgetSettings.ts
import useLocalStorageState from 'use-local-storage-state';

export interface KillsWidgetSettings {
  compact: boolean;
  showAll: boolean;
}

export const KILL_WIDGET_DEFAULT: KillsWidgetSettings = {
  compact: false,
  showAll: false,
};

export function useKillsWidgetSettings() {
  return useLocalStorageState<KillsWidgetSettings>('kills:widget:settings', {
    defaultValue: KILL_WIDGET_DEFAULT,
  });
}
