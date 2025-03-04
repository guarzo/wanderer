import { SolarSystemRawType, SolarSystemStaticInfoRaw } from '@/hooks/Mapper/types/system.ts';
import { SolarSystemConnection } from '@/hooks/Mapper/types/connection.ts';
import { WormholeDataRaw } from '@/hooks/Mapper/types/wormholes.ts';
import { CharacterTypeRaw } from '@/hooks/Mapper/types/character.ts';
import { RoutesList } from '@/hooks/Mapper/types/routes.ts';
import { DetailedKill, Kill } from '@/hooks/Mapper/types/kills.ts';
import { UserPermissions } from '@/hooks/Mapper/types';
import { ActivitySummary } from '../components/mapRootContent/components/CharacterActivity/CharacterActivity';
import { TrackingCharacter } from '../components/mapRootContent/components/TrackAndFollow/types';

/**
 * Commands that can be sent from the server to the client
 * or used for event handling
 */
export enum Commands {
  // Map data commands
  init = 'init',
  addSystems = 'add_systems',
  updateSystems = 'update_systems',
  removeSystems = 'remove_systems',
  addConnections = 'add_connections',
  removeConnections = 'remove_connections',
  charactersUpdated = 'characters_updated',
  characterAdded = 'character_added',
  characterRemoved = 'character_removed',
  characterUpdated = 'character_updated',
  presentCharacters = 'present_characters',
  updateConnection = 'update_connection',
  mapUpdated = 'map_updated',
  killsUpdated = 'kills_updated',
  detailedKillsUpdated = 'detailed_kills_updated',
  routes = 'routes',
  centerSystem = 'center_system',
  selectSystem = 'select_system',
  linkSignatureToSystem = 'link_signature_to_system',
  signaturesUpdated = 'signatures_updated',

  // Activity and tracking commands
  characterActivityData = 'character_activity_data',
  trackingCharactersData = 'tracking_characters_data',
  userSettingsUpdated = 'user_settings_updated',

  mapEvent = 'map_event',
  mapEvents = 'map_events',
  showActivity = 'show_activity',
  updateActivity = 'update_activity',
  hideActivity = 'hide_activity',
  showTracking = 'show_tracking',
  updateTracking = 'update_tracking',
  hideTracking = 'hide_tracking',
  refreshCharacters = 'refresh_characters',
  uiLoaded = 'ui_loaded',
  logMapError = 'log_map_error',
}

export type Command =
  // Map data commands
  | Commands.init
  | Commands.addSystems
  | Commands.updateSystems
  | Commands.removeSystems
  | Commands.removeConnections
  | Commands.addConnections
  | Commands.charactersUpdated
  | Commands.characterAdded
  | Commands.characterRemoved
  | Commands.characterUpdated
  | Commands.presentCharacters
  | Commands.updateConnection
  | Commands.mapUpdated
  | Commands.killsUpdated
  | Commands.detailedKillsUpdated
  | Commands.routes
  | Commands.selectSystem
  | Commands.centerSystem
  | Commands.linkSignatureToSystem
  | Commands.signaturesUpdated

  // Activity and tracking commands
  | Commands.characterActivityData
  | Commands.trackingCharactersData
  | Commands.userSettingsUpdated

  // Phoenix event names (previously in PhoenixEventName)
  | Commands.mapEvent
  | Commands.mapEvents
  | Commands.showActivity
  | Commands.updateActivity
  | Commands.hideActivity
  | Commands.showTracking
  | Commands.updateTracking
  | Commands.hideTracking
  | Commands.refreshCharacters
  | Commands.uiLoaded
  | Commands.logMapError;

export type CommandInit = {
  systems: SolarSystemRawType[];
  kills: Kill[];
  system_static_infos: SolarSystemStaticInfoRaw[];
  connections: SolarSystemConnection[];
  wormholes: WormholeDataRaw[];
  effects: unknown[];
  characters: CharacterTypeRaw[];
  present_characters: string[];
  user_characters: string[];
  user_permissions: UserPermissions;
  hubs: string[];
  routes: RoutesList;
  options: Record<string, string | boolean>;
  reset?: boolean;
  is_subscription_active?: boolean;
};
export type CommandAddSystems = SolarSystemRawType[];
export type CommandUpdateSystems = SolarSystemRawType[];
export type CommandRemoveSystems = number[];
export type CommandAddConnections = SolarSystemConnection[];
export type CommandRemoveConnections = string[];
export type CommandCharactersUpdated = CharacterTypeRaw[];
export type CommandCharacterAdded = CharacterTypeRaw;
export type CommandCharacterRemoved = CharacterTypeRaw;
export type CommandCharacterUpdated = CharacterTypeRaw;
export type CommandPresentCharacters = string[];
export type CommandUpdateConnection = SolarSystemConnection;
export type CommandSignaturesUpdated = string;
export type CommandMapUpdated = Partial<CommandInit>;
export type CommandRoutes = RoutesList;
export type CommandKillsUpdated = Kill[];
export type CommandDetailedKillsUpdated = Record<string, DetailedKill[]>;
export type CommandSelectSystem = string | undefined;
export type CommandCenterSystem = string | undefined;
export type CommandLinkSignatureToSystem = {
  solar_system_source: number;
  solar_system_target: number;
};
export type CommandLinkSignaturesUpdated = number;
export type CommandCharacterActivityData = { activity: ActivitySummary[] };
export type CommandTrackingCharactersData = { characters: TrackingCharacter[] };
export type CommandUserSettingsUpdated = { settings: Record<string, unknown> };

/**
 * Interface mapping Commands to their data types
 */
export interface CommandData {
  // Map data commands
  [Commands.init]: CommandInit;
  [Commands.addSystems]: CommandAddSystems;
  [Commands.updateSystems]: CommandUpdateSystems;
  [Commands.removeSystems]: CommandRemoveSystems;
  [Commands.addConnections]: CommandAddConnections;
  [Commands.removeConnections]: CommandRemoveConnections;
  [Commands.charactersUpdated]: CommandCharactersUpdated;
  [Commands.characterAdded]: CommandCharacterAdded;
  [Commands.characterRemoved]: CommandCharacterRemoved;
  [Commands.characterUpdated]: CommandCharacterUpdated;
  [Commands.presentCharacters]: CommandPresentCharacters;
  [Commands.updateConnection]: CommandUpdateConnection;
  [Commands.mapUpdated]: CommandMapUpdated;
  [Commands.routes]: CommandRoutes;
  [Commands.killsUpdated]: CommandKillsUpdated;
  [Commands.detailedKillsUpdated]: CommandDetailedKillsUpdated;
  [Commands.selectSystem]: CommandSelectSystem;
  [Commands.centerSystem]: CommandCenterSystem;
  [Commands.linkSignatureToSystem]: CommandLinkSignatureToSystem;
  [Commands.signaturesUpdated]: CommandLinkSignaturesUpdated;

  // Activity and tracking commands
  [Commands.characterActivityData]: CommandCharacterActivityData;
  [Commands.trackingCharactersData]: CommandTrackingCharactersData;
  [Commands.userSettingsUpdated]: CommandUserSettingsUpdated;

  // Event payloads
  [Commands.mapEvent]: { type: Command; data: unknown };
  [Commands.mapEvents]: Array<{ type: Command; data: unknown }>;
  [Commands.showActivity]: null;
  [Commands.updateActivity]: { activity: ActivitySummary[] };
  [Commands.hideActivity]: null;
  [Commands.showTracking]: null;
  [Commands.updateTracking]: { characters: TrackingCharacter[] };
  [Commands.hideTracking]: null;
  [Commands.refreshCharacters]: null;
  [Commands.uiLoaded]: { version: string | null };
  [Commands.logMapError]: { error: string; componentStack: string };
}

/**
 * Type for command event handlers
 */
export type CommandEventHandler<T extends keyof CommandData> = (payload: CommandData[T]) => void;

/**
 * Interface for the hooks passed to the Mapper component
 */
export interface MapperHooks {
  onError: (error: Error, componentStack: string) => void;
  handleEvent: <T extends keyof CommandData>(
    event: T | string,
    handler: CommandEventHandler<T> | ((payload: unknown) => void),
  ) => void;
  pushEventAsync: <T = unknown>(event: string, payload: unknown) => Promise<T>;
  pushEvent: (event: string, payload: unknown, callback?: (reply: unknown) => void) => void;
}

/**
 * Interface for the event handlers used in MapRootContent
 */
export interface MapEventHandlers {
  handleShowActivity: () => void;
  handleUpdateActivity: (activityData: CommandData[Commands.updateActivity]) => void;
  handleHideActivity: () => void;
  handleShowTracking: () => void;
  handleUpdateTracking: (trackingData: CommandData[Commands.updateTracking]) => void;
  handleHideTracking: () => void;
  handleRefreshCharacters: () => void;
  handleUserSettingsUpdated: (settingsData: CommandData[Commands.userSettingsUpdated]) => void;
}

export interface MapHandlers {
  command<T extends keyof CommandData>(type: T, data: CommandData[T]): void;
}

export enum OutCommand {
  addHub = 'add_hub',
  deleteHub = 'delete_hub',
  getRoutes = 'get_routes',
  getCharacterJumps = 'get_character_jumps',
  getStructures = 'get_structures',
  getSignatures = 'get_signatures',
  getSystemStaticInfos = 'get_system_static_infos',
  getConnectionInfo = 'get_connection_info',
  updateConnectionTimeStatus = 'update_connection_time_status',
  updateConnectionType = 'update_connection_type',
  updateConnectionMassStatus = 'update_connection_mass_status',
  updateConnectionShipSizeType = 'update_connection_ship_size_type',
  updateConnectionLocked = 'update_connection_locked',
  updateConnectionCustomInfo = 'update_connection_custom_info',
  updateStructures = 'update_structures',
  updateSignatures = 'update_signatures',
  updateSystemName = 'update_system_name',
  updateSystemTemporaryName = 'update_system_temporary_name',
  updateSystemOwner = 'update_system_owner',
  updateSystemDescription = 'update_system_description',
  updateSystemLabels = 'update_system_labels',
  updateSystemLocked = 'update_system_locked',
  updateSystemStatus = 'update_system_status',
  updateSystemTag = 'update_system_tag',
  updateSystemPosition = 'update_system_position',
  updateSystemPositions = 'update_system_positions',
  deleteSystems = 'delete_systems',
  manualAddSystem = 'manual_add_system',
  manualAddConnection = 'manual_add_connection',
  manualDeleteConnection = 'manual_delete_connection',
  setAutopilotWaypoint = 'set_autopilot_waypoint',
  addSystem = 'add_system',
  addCharacter = 'add_character',
  openUserSettings = 'open_user_settings',
  getPassages = 'get_passages',
  linkSignatureToSystem = 'link_signature_to_system',
  getCorporationNames = 'get_corporation_names',
  getCorporationTicker = 'get_corporation_ticker',
  getSystemKills = 'get_system_kills',
  getSystemsKills = 'get_systems_kills',
  updateSystemCustomFlags = 'update_system_custom_flags',

  getAllianceNames = 'get_alliance_names',
  getAllianceTicker = 'get_alliance_ticker',
  // Only UI commands
  openSettings = 'open_settings',

  // Character activity commands
  hideActivity = 'hide_activity',
  showActivity = 'show_activity',

  // Character tracking commands
  hideTracking = 'hide_tracking',
  showTracking = 'show_tracking',
  toggleTrack = 'toggle_track',
  toggleFollow = 'toggle_follow',
  refreshCharacters = 'refresh_characters',

  getUserSettings = 'get_user_settings',
  updateUserSettings = 'update_user_settings',
  unlinkSignature = 'unlink_signature',
  searchSystems = 'search_systems',
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type OutCommandHandler = <T = unknown>(event: { type: OutCommand; data: Record<string, unknown> }) => Promise<T>;

/**
 * Interface for map events used with the event system
 */
export interface MapEvent<T extends keyof CommandData> {
  name: T;
  data: CommandData[T];
}
