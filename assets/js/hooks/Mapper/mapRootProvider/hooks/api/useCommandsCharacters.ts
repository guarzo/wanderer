import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import {
  CommandCharacterAdded,
  CommandCharacterRemoved,
  CommandCharactersUpdated,
  CommandCharacterUpdated,
  CommandPresentCharacters,
  CommandReadyCharactersUpdated,
  CommandAllReadyCharactersCleared,
} from '@/hooks/Mapper/types';
import { useCallback, useRef } from 'react';

export const useCommandsCharacters = () => {
  const { update } = useMapRootState();

  const ref = useRef({ update });
  ref.current = { update };

  const charactersUpdated = useCallback((updatedCharacters: CommandCharactersUpdated) => {
    ref.current.update(state => {
      const existing = state.characters ?? [];
      // Put updatedCharacters into a map keyed by ID
      const updatedMap = new Map(updatedCharacters.map(c => [c.eve_id, c]));

      // 1. Update existing characters when possible
      const merged = existing.map(character => {
        const updated = updatedMap.get(character.eve_id);
        if (updated) {
          updatedMap.delete(character.eve_id); // Mark as processed
          return { ...character, ...updated };
        }
        return character;
      });

      // 2. Any remaining items in updatedMap are NEW characters → add them
      const newCharacters = Array.from(updatedMap.values());

      return { characters: [...merged, ...newCharacters] };
    });
  }, []);

  const characterAdded = useCallback((value: CommandCharacterAdded) => {
    ref.current.update(state => {
      return { characters: [...state.characters.filter(x => x.eve_id !== value.eve_id), value] };
    });
  }, []);

  const characterRemoved = useCallback((value: CommandCharacterRemoved) => {
    ref.current.update(state => {
      return { characters: [...state.characters.filter(x => x.eve_id !== value.eve_id)] };
    });
  }, []);

  const characterUpdated = useCallback((value: CommandCharacterUpdated) => {
    console.log('READY_DEBUG: characterUpdated called with:', value);
    ref.current.update(state => {
      const existingCharacter = state.characters.find(x => x.eve_id === value.eve_id);
      const updatedCharacter =
        existingCharacter && value.ready === undefined ? { ...value, ready: existingCharacter.ready } : value;
      return { characters: [...state.characters.filter(x => x.eve_id !== value.eve_id), updatedCharacter] };
    });
  }, []);

  const presentCharacters = useCallback((value: CommandPresentCharacters) => {
    ref.current.update(() => ({ presentCharacters: value }));
  }, []);

  const readyCharactersUpdated = useCallback((value: CommandReadyCharactersUpdated) => {
    const { ready_character_eve_ids } = value;
    ref.current.update(state => ({
      characters: state.characters.map(char => ({
        ...char,
        ready: ready_character_eve_ids.includes(char.eve_id),
      })),
    }));
  }, []);

  const allReadyCharactersCleared = useCallback(
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    (_value: CommandAllReadyCharactersCleared) => {
      // Clear all ready status for all characters
      // Note: _value contains cleared_by_user_id but we don't need it for this operation
      ref.current.update(state => ({
        characters: state.characters.map(char => ({
          ...char,
          ready: false,
        })),
      }));
    },
    [],
  );

  return {
    charactersUpdated,
    characterAdded,
    characterRemoved,
    characterUpdated,
    presentCharacters,
    readyCharactersUpdated,
    allReadyCharactersCleared,
  };
};
