import { SolarSystemRawType, SolarSystemStaticInfoRaw } from '@/hooks/Mapper/types/system.ts';
import { SolarSystemConnection } from '@/hooks/Mapper/types/connection.ts';
import { WormholeDataRaw } from '@/hooks/Mapper/types/wormholes.ts';
import { CharacterTypeRaw } from '@/hooks/Mapper/types/character.ts';
import { RoutesList } from '@/hooks/Mapper/types/routes.ts';
import { DetailedKill, Kill } from '@/hooks/Mapper/types/kills.ts';
import { UserPermissions } from '@/hooks/Mapper/types';
import { ActivitySummary } from '../components/map/components';
import { CharacterTrackingData } from '../components/map/components/TrackAndFollow';
import { EffectRaw } from '@/hooks/Mapper/types/effect.ts';

export enum Commands {
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
  show_activity = 'show_activity',
  update_activity = 'update_activity',
  show_tracking = 'show_tracking',
  update_tracking = 'update_tracking',
  hide_tracking = 'hide_tracking',
  refresh_characters = 'refresh_characters',
}

export type Command =
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
  | Commands.show_activity
  | Commands.update_activity
  | Commands.show_tracking
  | Commands.update_tracking
  | Commands.hide_tracking
  | Commands.refresh_characters;

export type CommandInit = {
  systems: SolarSystemRawType[];
  kills: Kill[];
  system_static_infos: SolarSystemStaticInfoRaw[];
  connections: SolarSystemConnection[];
  wormholes: WormholeDataRaw[];
  effects: EffectRaw[];
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
export type CommandUpdateActivity = { activity: ActivitySummary[] };
export type CommandUpdateTracking = { characters: CharacterTrackingData[] };
export type CommandEmptyData = Record<string, never>;

export interface CommandData {
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
  [Commands.show_activity]: CommandEmptyData;
  [Commands.update_activity]: CommandUpdateActivity;
  [Commands.show_tracking]: CommandEmptyData;
  [Commands.update_tracking]: CommandUpdateTracking;
  [Commands.hide_tracking]: CommandEmptyData;
  [Commands.refresh_characters]: CommandEmptyData;
}

export interface MapHandlers {
  command<T extends Command>(type: T, data: CommandData[T]): void;
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

  getUserSettings = 'get_user_settings',
  updateUserSettings = 'update_user_settings',
  unlinkSignature = 'unlink_signature',
  searchSystems = 'search_systems',

  // Track and follow commands
  toggleTrack = 'toggle_track',
  toggleFollow = 'toggle_follow',
  hideTracking = 'hide_tracking',
  hideActivity = 'hide_activity',
  refreshCharacters = 'refresh_characters',
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type OutCommandHandler = <TResult = any>(event: { type: OutCommand; data: unknown }) => Promise<TResult>;

export interface OutCommandData {
  [OutCommand.addHub]: string;
  [OutCommand.deleteHub]: string;
  [OutCommand.getRoutes]: CommandEmptyData;
  [OutCommand.getCharacterJumps]: { characterId: string };
  [OutCommand.getStructures]: { systemId: string };
  [OutCommand.getSignatures]: { systemId: string };
  [OutCommand.getSystemStaticInfos]: CommandEmptyData;
  [OutCommand.getConnectionInfo]: { source: string; target: string };
  [OutCommand.updateConnectionTimeStatus]: { source: string; target: string; status: string };
  [OutCommand.updateConnectionType]: { source: string; target: string; type: string };
  [OutCommand.updateConnectionMassStatus]: { source: string; target: string; status: string };
  [OutCommand.updateConnectionShipSizeType]: { source: string; target: string; type: string };
  [OutCommand.updateConnectionLocked]: { source: string; target: string; locked: boolean };
  [OutCommand.updateConnectionCustomInfo]: { source: string; target: string; info: string };
  [OutCommand.updateStructures]: { systemId: string; structures: Record<string, unknown>[] }; // TODO: Define proper structure type
  [OutCommand.updateSignatures]: { systemId: string; signatures: Record<string, unknown>[] }; // TODO: Define proper signature type
  [OutCommand.updateSystemName]: { systemId: string; name: string };
  [OutCommand.updateSystemTemporaryName]: { systemId: string; name: string };
  [OutCommand.updateSystemDescription]: { systemId: string; description: string };
  [OutCommand.updateSystemLabels]: { systemId: string; labels: string[] };
  [OutCommand.updateSystemLocked]: { systemId: string; locked: boolean };
  [OutCommand.updateSystemStatus]: { systemId: string; status: string };
  [OutCommand.updateSystemTag]: { systemId: string; tag: string };
  [OutCommand.updateSystemPosition]: { systemId: string; x: number; y: number };
  [OutCommand.updateSystemPositions]: { systems: { id: string; x: number; y: number }[] };
  [OutCommand.deleteSystems]: string[];
  [OutCommand.manualAddSystem]: { name: string; class: string; effect?: string };
  [OutCommand.manualAddConnection]: { source: string; target: string };
  [OutCommand.manualDeleteConnection]: { source: string; target: string };
  [OutCommand.setAutopilotWaypoint]: { systemId: string };
  [OutCommand.addSystem]: { name: string; class: string };
  [OutCommand.addCharacter]: CommandEmptyData;
  [OutCommand.openUserSettings]: CommandEmptyData;
  [OutCommand.getPassages]: { characterId: string };
  [OutCommand.linkSignatureToSystem]: { signatureId: string; systemId: string };
  [OutCommand.getCorporationNames]: string[];
  [OutCommand.getCorporationTicker]: string;
  [OutCommand.getSystemKills]: { systemId: string };
  [OutCommand.getSystemsKills]: string[];
  [OutCommand.openSettings]: CommandEmptyData;
  [OutCommand.getUserSettings]: CommandEmptyData;
  [OutCommand.updateUserSettings]: Record<string, boolean>;
  [OutCommand.unlinkSignature]: { signatureId: string };
  [OutCommand.searchSystems]: { query: string };
  [OutCommand.toggleTrack]: { 'character-id': string };
  [OutCommand.toggleFollow]: { 'character-id': string };
  [OutCommand.hideTracking]: CommandEmptyData;
  [OutCommand.hideActivity]: CommandEmptyData;
  [OutCommand.refreshCharacters]: CommandEmptyData;
}
