import React, { createContext, useContext, useEffect, useCallback } from 'react';
import { ContextStoreDataUpdate, useContextStore } from '@/hooks/Mapper/utils';
import { SESSION_KEY } from '@/hooks/Mapper/constants.ts';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand } from '@/hooks/Mapper/types';

export type RoutesType = {
  path_type: 'shortest' | 'secure' | 'insecure';
  include_mass_crit: boolean;
  include_eol: boolean;
  include_frig: boolean;
  include_cruise: boolean;
  include_thera: boolean;
  avoid_wormholes: boolean;
  avoid_pochven: boolean;
  avoid_edencom: boolean;
  avoid_triglavian: boolean;
  avoid: number[];
  hubs?: string[];
};

interface MapProviderProps {
  children: React.ReactNode;
}

export const DEFAULT_SETTINGS: RoutesType = {
  path_type: 'shortest',
  include_mass_crit: true,
  include_eol: true,
  include_frig: true,
  include_cruise: true,
  include_thera: true,
  avoid_wormholes: false,
  avoid_pochven: false,
  avoid_edencom: false,
  avoid_triglavian: false,
  avoid: [],
  hubs: [],
};

export interface MapContextProps {
  update: ContextStoreDataUpdate<RoutesType>;
  data: RoutesType;
}

const RoutesContext = createContext<MapContextProps>({
  update: () => {},
  data: { ...DEFAULT_SETTINGS },
});

export const RoutesProvider: React.FC<MapProviderProps> = ({ children }) => {
  const {
    outCommand,
    data: { hubs: mapHubs },
  } = useMapRootState();

  const saveSettingsToServer = useCallback(
    (settings: RoutesType) => {
      const settingsWithTimestamp = {
        ...settings,
        _timestamp: Date.now(),
      };

      outCommand({
        type: OutCommand.getRoutes,
        data: {
          type: 'save_user_settings',
          data: {
            key: 'routes',
            settings: settingsWithTimestamp,
          },
        },
      }).catch(error => {
        console.error('Failed to save settings to server:', error);
      });
    },
    [outCommand],
  );

  const { update, ref } = useContextStore<RoutesType>(
    { ...DEFAULT_SETTINGS },
    {
      onAfterAUpdate: values => {
        // Save to localStorage
        localStorage.setItem(SESSION_KEY.routes, JSON.stringify(values));

        // Save to server
        saveSettingsToServer({
          path_type: values.path_type || DEFAULT_SETTINGS.path_type,
          include_mass_crit: values.include_mass_crit ?? DEFAULT_SETTINGS.include_mass_crit,
          include_eol: values.include_eol ?? DEFAULT_SETTINGS.include_eol,
          include_frig: values.include_frig ?? DEFAULT_SETTINGS.include_frig,
          include_cruise: values.include_cruise ?? DEFAULT_SETTINGS.include_cruise,
          include_thera: values.include_thera ?? DEFAULT_SETTINGS.include_thera,
          avoid_wormholes: values.avoid_wormholes ?? DEFAULT_SETTINGS.avoid_wormholes,
          avoid_pochven: values.avoid_pochven ?? DEFAULT_SETTINGS.avoid_pochven,
          avoid_edencom: values.avoid_edencom ?? DEFAULT_SETTINGS.avoid_edencom,
          avoid_triglavian: values.avoid_triglavian ?? DEFAULT_SETTINGS.avoid_triglavian,
          avoid: values.avoid ?? DEFAULT_SETTINGS.avoid,
          hubs: values.hubs ?? DEFAULT_SETTINGS.hubs,
        });
      },
    },
  );

  const loadSettingsFromServer = useCallback(() => {
    outCommand({
      type: OutCommand.getRoutes,
      data: {
        type: 'get_user_settings',
        data: {
          key: 'routes',
        },
      },
    }).catch(error => {
      console.error('Failed to load settings from server:', error);
    });
  }, [outCommand]);

  useEffect(() => {
    // First try to load from localStorage
    const items = localStorage.getItem(SESSION_KEY.routes);
    if (items) {
      try {
        const parsedSettings = JSON.parse(items);
        // Don't merge with default settings - use localStorage settings as is
        // Just ensure path_type is valid
        const validPathType = ['shortest', 'secure', 'insecure'].includes(parsedSettings.path_type)
          ? (parsedSettings.path_type as RoutesType['path_type'])
          : 'shortest';

        const cleanSettings: RoutesType = {
          path_type: validPathType,
          include_mass_crit: Boolean(parsedSettings.include_mass_crit),
          include_eol: Boolean(parsedSettings.include_eol),
          include_frig: Boolean(parsedSettings.include_frig),
          include_cruise: Boolean(parsedSettings.include_cruise),
          include_thera: Boolean(parsedSettings.include_thera),
          avoid_wormholes: Boolean(parsedSettings.avoid_wormholes),
          avoid_pochven: Boolean(parsedSettings.avoid_pochven),
          avoid_edencom: Boolean(parsedSettings.avoid_edencom),
          avoid_triglavian: Boolean(parsedSettings.avoid_triglavian),
          avoid: Array.isArray(parsedSettings.avoid) ? (parsedSettings.avoid as number[]) : [],
          hubs: Array.isArray(parsedSettings.hubs) ? (parsedSettings.hubs as string[]) : [],
        };

        console.log('Updating settings from localStorage:', cleanSettings);
        update(cleanSettings);
      } catch (error) {
        console.error('Failed to parse settings from localStorage:', error);
      }
    }

    // Then try to load from server
    loadSettingsFromServer();
  }, [update, loadSettingsFromServer]);

  // Sync with MapRootState hubs
  useEffect(() => {
    if (mapHubs && mapHubs.length > 0) {
      console.log('RoutesProvider - Syncing with MapRootState hubs:', mapHubs);
      update(currentSettings => ({
        ...currentSettings,
        hubs: mapHubs,
      }));
    }
  }, [mapHubs, update]);

  // Listen for settings from the server
  useEffect(() => {
    const handleUserSettings = (e: CustomEvent) => {
      if (e.detail?.key === 'routes' && e.detail?.settings) {
        try {
          const serverSettings = e.detail.settings as Record<string, unknown>;
          const serverTimestamp = (serverSettings._timestamp as number) || 0;

          const localItem = localStorage.getItem(SESSION_KEY.routes);
          let localTimestamp = 0;

          if (localItem) {
            try {
              const localSettings = JSON.parse(localItem);
              localTimestamp = localSettings._timestamp || 0;
            } catch (error) {
              console.error('Failed to parse local settings for timestamp comparison', error);
            }
          }

          // Only update if server settings are newer
          if (serverTimestamp >= localTimestamp) {
            // Don't merge with default settings - use server settings as is
            // Just ensure path_type is valid
            const validPathType = ['shortest', 'secure', 'insecure'].includes(serverSettings.path_type as string)
              ? (serverSettings.path_type as RoutesType['path_type'])
              : 'shortest';

            const cleanSettings: RoutesType = {
              path_type: validPathType,
              include_mass_crit: Boolean(serverSettings.include_mass_crit),
              include_eol: Boolean(serverSettings.include_eol),
              include_frig: Boolean(serverSettings.include_frig),
              include_cruise: Boolean(serverSettings.include_cruise),
              include_thera: Boolean(serverSettings.include_thera),
              avoid_wormholes: Boolean(serverSettings.avoid_wormholes),
              avoid_pochven: Boolean(serverSettings.avoid_pochven),
              avoid_edencom: Boolean(serverSettings.avoid_edencom),
              avoid_triglavian: Boolean(serverSettings.avoid_triglavian),
              avoid: Array.isArray(serverSettings.avoid) ? (serverSettings.avoid as number[]) : [],
              hubs: Array.isArray(serverSettings.hubs) ? (serverSettings.hubs as string[]) : [],
            };

            console.log('Updating settings from server:', cleanSettings);
            update(cleanSettings);
            localStorage.setItem(SESSION_KEY.routes, JSON.stringify(serverSettings));
          }
        } catch (error) {
          console.error('Failed to process server settings', error);
        }
      }
    };

    window.addEventListener('user_settings', handleUserSettings as EventListener);

    return () => {
      window.removeEventListener('user_settings', handleUserSettings as EventListener);
    };
  }, [update]);

  // Listen for map_updated events directly
  useEffect(() => {
    const handleMapEvent = (e: CustomEvent) => {
      if (e.detail?.type === 'map_updated' && e.detail?.body?.hubs) {
        const updatedHubs = e.detail.body.hubs as string[];
        console.log('RoutesProvider - Received map_updated event with hubs:', updatedHubs);
        
        // Update the current settings with the new hubs
        update(currentSettings => ({
          ...currentSettings,
          hubs: updatedHubs,
        }));
        
        // Also update localStorage
        const localItem = localStorage.getItem(SESSION_KEY.routes);
        if (localItem) {
          try {
            const localSettings = JSON.parse(localItem);
            localSettings.hubs = updatedHubs;
            localStorage.setItem(SESSION_KEY.routes, JSON.stringify(localSettings));
          } catch (error) {
            console.error('Failed to update hubs in localStorage', error);
          }
        }
      }
    };

    window.addEventListener('map_event', handleMapEvent as EventListener);

    return () => {
      window.removeEventListener('map_event', handleMapEvent as EventListener);
    };
  }, [update]);

  // We don't need a custom event listener for user_hubs_updated anymore
  // The map_updated event will be handled by the MapRootProvider and will update the hubs

  return (
    <RoutesContext.Provider
      value={{
        update,
        data: ref,
      }}
    >
      {children}
    </RoutesContext.Provider>
  );
};

export const useRouteProvider = () => {
  const context = useContext<MapContextProps>(RoutesContext);
  return context;
};
