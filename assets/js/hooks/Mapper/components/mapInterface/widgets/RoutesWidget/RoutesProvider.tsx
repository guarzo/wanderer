import React, { createContext, useContext, useEffect, useState } from 'react';
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
  avoid: string[];
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
  loading: boolean;
}

const RoutesContext = createContext<MapContextProps>({
  update: () => {},
  data: { ...DEFAULT_SETTINGS },
  loading: false,
});

interface UserSettingsEventDetail {
  key: string;
  settings: Record<string, unknown>;
}

interface UserSettingsEvent extends CustomEvent {
  detail: UserSettingsEventDetail;
}

export const RoutesProvider: React.FC<MapProviderProps> = ({ children }) => {
  const { update, ref } = useContextStore<RoutesType>(
    { ...DEFAULT_SETTINGS },
    {
      onAfterAUpdate: values => {
        // Keep localStorage for backward compatibility
        localStorage.setItem(SESSION_KEY.routes, JSON.stringify(values));

        // Save to server
        saveSettingsToServer(values);
      },
    },
  );

  const [loading, setLoading] = useState(false);
  const [serverSettingsLoaded, setServerSettingsLoaded] = useState(false);
  const { outCommand } = useMapRootState();

  // Function to save settings to the server
  const saveSettingsToServer = (settings: RoutesType) => {
    outCommand({
      type: OutCommand.getRoutes,
      data: {
        type: 'save_user_settings',
        data: {
          key: 'routes',
          settings,
        },
      },
    }).catch(error => {
      console.error('Failed to save settings to server:', error);
    });
  };

  // Function to load settings from the server
  const loadSettingsFromServer = () => {
    setLoading(true);
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
      setLoading(false);
    });
  };

  // Helper function to safely merge settings with defaults
  const mergeWithDefaults = (partialSettings: Partial<RoutesType>): RoutesType => {
    return {
      ...DEFAULT_SETTINGS,
      ...partialSettings,
      // Ensure path_type is valid
      path_type: (partialSettings.path_type as 'shortest' | 'secure' | 'insecure') || DEFAULT_SETTINGS.path_type,
      // Explicitly ensure avoid_wormholes is correctly set
      avoid_wormholes:
        partialSettings.avoid_wormholes !== undefined
          ? Boolean(partialSettings.avoid_wormholes)
          : DEFAULT_SETTINGS.avoid_wormholes,
    };
  };

  // Listen for settings from the server
  useEffect(() => {
    const handleUserSettings = (e: UserSettingsEvent) => {
      if (e.detail.key === 'routes') {
        setLoading(false);
        setServerSettingsLoaded(true);

        if (Object.keys(e.detail.settings).length > 0) {
          try {
            // Ensure we have all required fields with defaults
            const serverSettings = e.detail.settings as Partial<RoutesType>;
            const mergedSettings = mergeWithDefaults(serverSettings);
            update(mergedSettings);
          } catch (error) {
            console.error('Failed to process server settings', error);
          }
        }
      }
    };

    window.addEventListener('user_settings', handleUserSettings as EventListener);

    return () => {
      window.removeEventListener('user_settings', handleUserSettings as EventListener);
    };
  }, [update]);

  // Load settings from server first, then fallback to localStorage if needed
  useEffect(() => {
    // First try to load from server
    loadSettingsFromServer();

    // Set a timeout to check localStorage if server doesn't respond quickly
    const timeoutId = setTimeout(() => {
      if (!serverSettingsLoaded) {
        loadFromLocalStorage();
      }
    }, 1000); // Wait 1 second for server response before trying localStorage

    return () => clearTimeout(timeoutId);
  }, []);

  // Function to load settings from localStorage
  const loadFromLocalStorage = () => {
    const items = localStorage.getItem(SESSION_KEY.routes);
    if (items) {
      try {
        const localSettings = JSON.parse(items) as Partial<RoutesType>;
        const mergedSettings = mergeWithDefaults(localSettings);
        update(mergedSettings);

        // If we loaded from localStorage and server settings haven't loaded yet,
        // save these settings to the server for future use
        if (!serverSettingsLoaded) {
          saveSettingsToServer(mergedSettings);
        }
      } catch (error) {
        console.error('Failed to parse routes settings from localStorage', error);
      }
    }
  };

  return (
    <RoutesContext.Provider
      value={{
        update,
        data: ref,
        loading,
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
