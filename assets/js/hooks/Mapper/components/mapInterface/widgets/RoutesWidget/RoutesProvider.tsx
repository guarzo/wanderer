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
  const { outCommand } = useMapRootState();

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
        saveSettingsToServer(values);
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
        // Ensure all required fields are present
        const mergedSettings: RoutesType = {
          ...DEFAULT_SETTINGS,
          ...parsedSettings,
          // Ensure path_type is valid
          path_type: (parsedSettings.path_type as RoutesType['path_type']) || DEFAULT_SETTINGS.path_type,
        };
        update(mergedSettings);
      } catch (error) {
        console.error('Failed to parse settings from localStorage:', error);
      }
    }

    // Then try to load from server
    loadSettingsFromServer();
  }, [update, loadSettingsFromServer]);

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
            // Ensure all required fields are present
            const mergedSettings: RoutesType = {
              ...DEFAULT_SETTINGS,
              ...serverSettings,
              // Ensure path_type is valid
              path_type: (serverSettings.path_type as RoutesType['path_type']) || DEFAULT_SETTINGS.path_type,
            };

            update(mergedSettings);
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
