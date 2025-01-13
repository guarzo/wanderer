import { ContextStoreDataUpdate, useContextStore } from '@/hooks/Mapper/utils';
import { createContext, Dispatch, ForwardedRef, forwardRef, SetStateAction, useContext, useEffect } from 'react';
import { MapUnionTypes, OutCommandHandler, SolarSystemConnection } from '@/hooks/Mapper/types';
import { useMapRootHandlers } from '@/hooks/Mapper/mapRootProvider/hooks';
import { WithChildren } from '@/hooks/Mapper/types/common.ts';
import useLocalStorageState from 'use-local-storage-state';
import { WidgetsIds } from '@/hooks/Mapper/components/mapInterface/constants.tsx';

export type MapRootData = MapUnionTypes & {
  selectedSystems: string[];
  selectedConnections: Pick<SolarSystemConnection, 'source' | 'target'>[];
};

const INITIAL_DATA: MapRootData = {
  wormholesData: {},
  wormholes: [],
  effects: {},
  characters: [],
  userCharacters: [],
  presentCharacters: [],
  systems: [],
  systemSignatures: {},
  hubs: [],
  routes: undefined,
  kills: [],
  connections: [],

  selectedSystems: [],
  selectedConnections: [],
  userPermissions: {},
  options: {},
};

// eslint-disable-next-line react-refresh/only-export-components
export enum InterfaceStoredSettingsProps {
  isShowMenu = 'isShowMenu',
  isShowMinimap = 'isShowMinimap',
  isShowKSpace = 'isShowKSpace',
  isThickConnections = 'isThickConnections',
  isShowUnsplashedSignatures = 'isShowUnsplashedSignatures',
  isShowBackgroundPattern = 'isShowBackgroundPattern',
  isSoftBackground = 'isSoftBackground',
  theme = 'theme',
}

export type InterfaceStoredSettings = {
  isShowMenu: boolean;
  isShowMinimap: boolean;
  isShowKSpace: boolean;
  isThickConnections: boolean;
  isShowUnsplashedSignatures: boolean;
  isShowBackgroundPattern: boolean;
  isSoftBackground: boolean;
  theme: string;
};

// eslint-disable-next-line react-refresh/only-export-components
export const STORED_INTERFACE_DEFAULT_VALUES: InterfaceStoredSettings = {
  isShowMenu: false,
  isShowMinimap: true,
  isShowKSpace: false,
  isThickConnections: false,
  isShowUnsplashedSignatures: false,
  isShowBackgroundPattern: true,
  isSoftBackground: false,
  theme: 'default',
};

// eslint-disable-next-line react-refresh/only-export-components
export const STORED_VISIBLE_WIDGETS_DEFAULT = [
  WidgetsIds.info,
  WidgetsIds.local,
  WidgetsIds.routes,
  WidgetsIds.signatures,
];

export interface MapRootContextProps {
  update: ContextStoreDataUpdate<MapRootData>;
  data: MapRootData;
  outCommand: OutCommandHandler;
  interfaceSettings: InterfaceStoredSettings;
  setInterfaceSettings: Dispatch<SetStateAction<InterfaceStoredSettings>>;
  windowsVisible: WidgetsIds[];
  setWindowsVisible: Dispatch<SetStateAction<WidgetsIds[]>>;
}

const MapRootContext = createContext<MapRootContextProps>({
  update: () => {},
  data: { ...INITIAL_DATA },
  // @ts-ignore
  outCommand: async () => void 0,
  interfaceSettings: STORED_INTERFACE_DEFAULT_VALUES,
  setInterfaceSettings: () => null,
});

type MapRootProviderProps = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  fwdRef: ForwardedRef<any>;
  outCommand: OutCommandHandler;
} & WithChildren;

// eslint-disable-next-line react/display-name
const MapRootHandlers = forwardRef(({ children }: WithChildren, fwdRef: ForwardedRef<any>) => {
  useMapRootHandlers(fwdRef);
  return <>{children}</>;
});

// eslint-disable-next-line react/display-name
export const MapRootProvider = ({ children, fwdRef, outCommand }: MapRootProviderProps) => {
  const { update, ref } = useContextStore<MapRootData>({ ...INITIAL_DATA });

  const [interfaceSettings, setInterfaceSettings] = useLocalStorageState<InterfaceStoredSettings>(
    'window:interface:settings',
    {
      defaultValue: STORED_INTERFACE_DEFAULT_VALUES,
    },
  );

  const [windowsVisible, setWindowsVisible] = useLocalStorageState<WidgetsIds[]>('windows:visible', {
    defaultValue: STORED_VISIBLE_WIDGETS_DEFAULT,
  });

  useEffect(() => {
    let foundNew = false;
    const newVals = Object.keys(STORED_INTERFACE_DEFAULT_VALUES).reduce((acc, x) => {
      if (Object.keys(acc).includes(x)) {
        return acc;
      }

      foundNew = true;

      // @ts-ignore
      return { ...acc, [x]: STORED_INTERFACE_DEFAULT_VALUES[x] };
    }, interfaceSettings);

    if (foundNew) {
      setInterfaceSettings(newVals);
    }
  }, []);

  return (
    <MapRootContext.Provider
      value={{
        update,
        data: ref,
        outCommand: outCommand,
        setInterfaceSettings,
        interfaceSettings,
        windowsVisible,
        setWindowsVisible,
      }}
    >
      <MapRootHandlers ref={fwdRef}>{children}</MapRootHandlers>
    </MapRootContext.Provider>
  );
};

// eslint-disable-next-line react-refresh/only-export-components
export const useMapRootState = () => {
  const context = useContext<MapRootContextProps>(MapRootContext);
  return context;
};
