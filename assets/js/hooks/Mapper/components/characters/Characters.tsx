import { emitMapEvent } from '@/hooks/Mapper/events';
import { isDocked } from '@/hooks/Mapper/helpers/isDocked';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { useAutoAnimate } from '@formkit/auto-animate/react';
import clsx from 'clsx';
import { PrimeIcons } from 'primereact/api';
import React, { useCallback, useEffect, useState, useMemo } from 'react';
import classes from './Characters.module.scss';
import { useMapEventListener } from '@/hooks/Mapper/events';

interface CharactersProps {
  data: CharacterTypeRaw[];
}

function getCharacterTitle(name: string, trackingPaused: boolean, online: boolean, isReady: boolean): string {
  if (trackingPaused) {
    return `${name} - Tracking Paused (click to resume)`;
  }
  if (!online) {
    return `${name} - Offline (cannot mark as ready)`;
  }
  if (isReady) {
    return `${name} - Ready for combat (right-click to unready)`;
  }
  return `${name} (right-click to mark as ready)`;
}

export const Characters: React.FC<CharactersProps> = ({ data }) => {
  const [parent] = useAutoAnimate();
  const [readyCharacters, setReadyCharacters] = useState<string[]>([]);

  const {
    outCommand,
    data: { mainCharacterEveId, followingCharacterEveId },
  } = useMapRootState();

  // Load ready characters on mount and when data changes
  useEffect(() => {
    const loadReady = async () => {
      try {
        const res = await outCommand({
          type: OutCommand.getCharactersTrackingInfo,
          data: {},
        });
        const responseData = res as { data?: { ready_characters?: string[] } };
        setReadyCharacters(responseData.data?.ready_characters || []);
      } catch (err) {
        console.error('Failed to load ready characters:', err);
      }
    };
    loadReady();
  }, [outCommand, data]);

  // Listen for tracking updates that might affect ready status
  useMapEventListener(event => {
    if (event.name === Commands.updateTracking || event.name === Commands.charactersUpdated) {
      // Reload ready characters when tracking data is updated
      const loadReady = async () => {
        try {
          const res = await outCommand({
            type: OutCommand.getCharactersTrackingInfo,
            data: {},
          });
          const responseData = res as { data?: { ready_characters?: string[] } };
          setReadyCharacters(responseData.data?.ready_characters || []);
        } catch (err) {
          console.error('Failed to reload ready characters:', err);
        }
      };
      loadReady();
      return true;
    }
    return false;
  });

  const handleSelect = useCallback(
    async (character: CharacterTypeRaw) => {
      await outCommand({
        type: OutCommand.startTracking,
        data: { character_eve_id: character.eve_id },
      });
      emitMapEvent({
        name: Commands.centerSystem,
        data: character.solar_system_id?.toString() ?? '',
      });
    },
    [outCommand],
  );

  const handleToggleReady = useCallback(
    async (character: CharacterTypeRaw, e: React.MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (!character.online) return;

      const isCurrentlyReady = readyCharacters.includes(character.eve_id);
      const newList = isCurrentlyReady
        ? readyCharacters.filter(id => id !== character.eve_id)
        : [...readyCharacters, character.eve_id];

      try {
        await outCommand({
          type: OutCommand.updateReadyCharacters,
          data: { ready_character_eve_ids: newList },
        });
        setReadyCharacters(newList);
      } catch (err) {
        console.error('Failed to update ready characters:', err);
      }
    },
    [readyCharacters, outCommand],
  );

  // Memoize items so we only re-render when data or readyCharacters change
  const items = useMemo(
    () =>
      data.map(character => {
        const isReady = readyCharacters.includes(character.eve_id);
        const title = getCharacterTitle(character.name, character.tracking_paused, character.online, isReady);

        return (
          <li
            key={character.eve_id}
            className="flex flex-col items-center justify-center"
            onClick={() => handleSelect(character)}
            onContextMenu={e => handleToggleReady(character, e)}
            title={title}
          >
            <div
              className={clsx(
                'overflow-hidden relative flex w-[35px] h-[35px] rounded-[4px] border-[1px] bg-transparent cursor-pointer transition-colors duration-250 hover:bg-stone-300/90',
                {
                  'border-stone-800/90': !character.online && !isReady,
                  'border-lime-600/70': character.online && !isReady,
                  'border-orange-500/90': isReady && character.online,
                  'border-orange-700/70': isReady && !character.online,
                },
              )}
            >
              {character.tracking_paused && (
                <span
                  className={clsx(
                    'absolute top-0 left-0 w-[35px] h-[35px] flex items-center justify-center text-yellow-500 text-[9px] z-10 bg-gray-800/40 pi',
                    PrimeIcons.PAUSE,
                  )}
                />
              )}

              {mainCharacterEveId === character.eve_id && (
                <span
                  className={clsx(
                    'absolute top-[2px] left-[22px] w-[9px] h-[9px] flex items-center justify-center text-yellow-500 text-[9px] rounded-[1px] z-10 pi',
                    PrimeIcons.STAR_FILL,
                  )}
                />
              )}

              {followingCharacterEveId === character.eve_id && (
                <span
                  className={clsx(
                    'absolute top-[23px] left-[22px] w-[10px] h-[10px] flex items-center justify-center text-sky-300 text-[10px] rounded-[1px] z-10 pi pi-angle-double-right',
                  )}
                />
              )}

              {isReady && (
                <span
                  className={clsx(
                    'absolute top-[2px] left-[2px] w-[8px] h-[8px] flex items-center justify-center text-orange-500 text-[8px] rounded-[1px] z-10 pi',
                    PrimeIcons.BOLT,
                  )}
                />
              )}

              {isDocked({
                solar_system_id: character.solar_system_id,
                structure_id: character.structure_id ?? null,
                station_id: character.station_id ?? null,
              }) && <div className={classes.Docked} />}

              <div
                className={clsx(
                  'flex w-full h-full bg-center bg-no-repeat bg-[length:100%] transition-opacity shadow-[inset_0_1px_6px_1px_#000000] cursor-pointer',
                  {
                    'opacity-60': !character.online,
                    'opacity-100': character.online,
                  },
                )}
                style={{
                  backgroundImage: `url(https://images.evetech.net/characters/${character.eve_id}/portrait)`,
                }}
              />
            </div>
          </li>
        );
      }),
    [data, readyCharacters, handleSelect, handleToggleReady, mainCharacterEveId, followingCharacterEveId],
  );

  return (
    <ul className="flex gap-1 characters" id="characters" ref={parent}>
      {items}
    </ul>
  );
};
