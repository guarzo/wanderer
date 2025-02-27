import { RefObject, useCallback } from 'react';
import { Command, CommandData, MapHandlers } from '@/hooks/Mapper/types/mapHandlers.ts';
import { MapperHooks } from './types/events';

/**
 * Hook to handle communication between Phoenix LiveView and React
 *
 * This hook provides functions to:
 * 1. Send commands to the server (handleCommand)
 * 2. Handle map events from the server (handleMapEvent)
 * 3. Handle multiple map events from the server (handleMapEvents)
 *
 * @param handlerRefs - References to MapHandlers instances
 * @param hooksRef - Reference to the hooks object from Phoenix LiveView
 * @returns Object with handler functions
 */
export const useMapperHandlers = (handlerRefs: RefObject<MapHandlers>[], hooksRef: RefObject<MapperHooks>) => {
  /**
   * Sends a command to the server
   *
   * @param type - The command type
   * @param data - The command data
   * @returns Promise with the server response
   */
  const handleCommand = useCallback(
    async <T = unknown>({ type, data }: { type: string; data: unknown }): Promise<T> => {
      if (!hooksRef.current) {
        throw new Error('Hooks reference is not available');
      }

      return await hooksRef.current.pushEventAsync<T>(type, data);
    },
    [hooksRef],
  );

  /**
   * Handles a single map event from the server
   *
   * @param event - The map event object
   */
  const handleMapEvent = useCallback(
    (event: { type: Command; body: unknown }) => {
      handlerRefs.forEach(ref => {
        if (!ref.current) {
          return;
        }

        ref.current.command(event.type, event.body as CommandData[typeof event.type]);
      });
    },
    [handlerRefs],
  );

  /**
   * Handles multiple map events from the server
   *
   * @param events - Array of map events
   */
  const handleMapEvents = useCallback(
    (events: Array<{ type: Command; body: unknown }>) => {
      events.forEach(event => {
        handleMapEvent(event);
      });
    },
    [handleMapEvent],
  );

  return { handleCommand, handleMapEvent, handleMapEvents };
};
