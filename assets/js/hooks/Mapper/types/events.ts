import { ActivitySummary } from '../components/map/components/CharacterActivity';
import { CharacterTrackingData } from '../components/map/components/TrackAndFollow';
import { Command } from './mapHandlers';

/**
 * Phoenix event names that can be received from the server
 */
export enum PhoenixEventName {
  // Map events
  MAP_EVENT = 'map_event',
  MAP_EVENTS = 'map_events',

  // Activity events
  SHOW_ACTIVITY = 'show_activity',
  UPDATE_ACTIVITY = 'update_activity',

  // Tracking events
  SHOW_TRACKING = 'show_tracking',
  UPDATE_TRACKING = 'update_tracking',
  HIDE_TRACKING = 'hide_tracking',
  REFRESH_CHARACTERS = 'refresh_characters',

  // System events
  UI_LOADED = 'ui_loaded',
  LOG_MAP_ERROR = 'log_map_error',
}

/**
 * Phoenix event payloads for each event type
 */
export interface PhoenixEventPayload {
  [PhoenixEventName.MAP_EVENT]: { type: Command; data: unknown };
  [PhoenixEventName.MAP_EVENTS]: Array<{ type: Command; data: unknown }>;
  [PhoenixEventName.SHOW_ACTIVITY]: null;
  [PhoenixEventName.UPDATE_ACTIVITY]: { activity: ActivitySummary[] };
  [PhoenixEventName.SHOW_TRACKING]: null;
  [PhoenixEventName.UPDATE_TRACKING]: { characters: CharacterTrackingData[] };
  [PhoenixEventName.HIDE_TRACKING]: null;
  [PhoenixEventName.REFRESH_CHARACTERS]: null;
  [PhoenixEventName.UI_LOADED]: { version: string | null };
  [PhoenixEventName.LOG_MAP_ERROR]: { error: string; componentStack: string };
}

/**
 * Type for Phoenix event handlers
 */
export type PhoenixEventHandler<T extends PhoenixEventName> = (payload: PhoenixEventPayload[T]) => void;

/**
 * Interface for the hooks passed to the Mapper component
 */
export interface MapperHooks {
  onError: (error: Error, componentStack: string) => void;
  handleEvent: <T extends PhoenixEventName>(
    event: T | string,
    handler: PhoenixEventHandler<T> | ((payload: unknown) => void),
  ) => void;
  pushEventAsync: <T = unknown>(event: string, payload: unknown) => Promise<T>;
  pushEvent: (event: string, payload: unknown, callback?: (reply: unknown) => void) => void;
}

/**
 * Interface for the event handlers used in MapRootContent
 */
export interface MapEventHandlers {
  handleShowActivity: () => void;
  handleUpdateActivity: (activityData: PhoenixEventPayload[PhoenixEventName.UPDATE_ACTIVITY]) => void;
  handleShowTracking: () => void;
  handleUpdateTracking: (trackingData: PhoenixEventPayload[PhoenixEventName.UPDATE_TRACKING]) => void;
  handleHideTracking: () => void;
  handleRefreshCharacters: () => void;
}
