import { WindowStoreInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useStoreWidgets.ts';
import { SignatureSettingsType } from '@/hooks/Mapper/constants/signatures.ts';

export enum AvailableThemes {
  default = 'default',
  pathfinder = 'pathfinder',
}

export enum MiniMapPlacement {
  rightTop = 'rightTop',
  rightBottom = 'rightBottom',
  leftTop = 'leftTop',
  leftBottom = 'leftBottom',
  hide = 'hide',
}

export enum PingsPlacement {
  rightTop = 'rightTop',
  rightBottom = 'rightBottom',
  leftTop = 'leftTop',
  leftBottom = 'leftBottom',
}

export type InterfaceStoredSettings = {
  isShowMenu: boolean;
  isShowKSpace: boolean;
  isThickConnections: boolean;
  isShowUnsplashedSignatures: boolean;
  isShowBackgroundPattern: boolean;
  isSoftBackground: boolean;
  theme: AvailableThemes;
  minimapPlacement: MiniMapPlacement;
  pingsPlacement: PingsPlacement;
};

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

export type LocalWidgetSettings = {
  compact: boolean;
  showOffline: boolean;
  version: number;
  showShipName: boolean;
};

export type OnTheMapSettingsType = {
  hideOffline: boolean;
  version: number;
};

export type KillsWidgetSettings = {
  showAll: boolean;
  whOnly: boolean;
  excludedSystems: number[];
  version: number;
  timeRange: number;
};

export type SettingsWithVersion<T> = {
  version: number;
  settings: T;
};

export type MapUserSettings = {
  widgets: SettingsWithVersion<WindowStoreInfo>;
  interface: SettingsWithVersion<InterfaceStoredSettings>;
  onTheMap: SettingsWithVersion<OnTheMapSettingsType>;
  routes: SettingsWithVersion<RoutesType>;
  localWidget: SettingsWithVersion<LocalWidgetSettings>;
  signaturesWidget: SettingsWithVersion<SignatureSettingsType>;
  killsWidget: SettingsWithVersion<KillsWidgetSettings>;
};

export type MapUserSettingsStructure = {
  [mapId: string]: MapUserSettings;
};
