import { emitMapEvent } from '@/hooks/Mapper/events';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { useAutoAnimate } from '@formkit/auto-animate/react';
import clsx from 'clsx';
import React, { useCallback, useMemo, useRef } from 'react';
import {
  TooltipPosition,
  WdEveEntityPortrait,
  WdEveEntityPortraitSize,
  WdTooltipWrapper,
} from '@/hooks/Mapper/components/ui-kit';
import { WdCharStateWrapper } from '@/hooks/Mapper/components/characters/components/WdCharStateWrapper.tsx';

interface CharactersProps {
  data: CharacterTypeRaw[];
}

function getTooltipContent(
  name: string,
  isExpired: boolean,
  trackingPaused: boolean,
  online: boolean,
  isReady: boolean,
): string {
  if (isExpired) return `Token is expired for ${name}`;
  if (trackingPaused) return `${name} - Tracking Paused (click to resume)`;
  if (!online) return `${name} - Offline`;
  if (isReady) return `${name} - Ready for combat (right-click to unready)`;
  return `${name} (right-click to mark as ready)`;
}

export const Characters = ({ data }: CharactersProps) => {
  const [parent] = useAutoAnimate();

  const {
    outCommand,
    data: { mainCharacterEveId, followingCharacterEveId, expiredCharacters },
  } = useMapRootState();

  const handleSelect = useCallback(
    async (character: CharacterTypeRaw) => {
      if (!character) return;

      await outCommand({
        type: OutCommand.startTracking,
        data: { character_eve_id: character.eve_id },
      });
      emitMapEvent({
        name: Commands.centerSystem,
        data: character.location?.solar_system_id?.toString() ?? '',
      });
    },
    [outCommand],
  );

  // The server takes the whole ready list, not an add/remove, so two toggles
  // fired inside one round-trip would both derive their replacement list from
  // the same rendered `data` and the second would undo the first. Chain the
  // requests and keep the list we last sent, so each toggle composes onto the
  // previous one instead of onto a stale snapshot. The optimistic list is held
  // only while requests are in flight — the window in which `data` is stale —
  // and dropped once the queue drains and the broadcast has landed.
  const pendingReadyRef = useRef<string[] | null>(null);
  const inFlightRef = useRef(0);
  const readyQueueRef = useRef<Promise<unknown>>(Promise.resolve());

  const handleToggleReady = useCallback(
    async (character: CharacterTypeRaw, e: React.MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (!character.online) return;

      inFlightRef.current += 1;

      const run = readyQueueRef.current.then(async () => {
        const currentReadyCharacters =
          pendingReadyRef.current ?? (data || []).filter(char => char.ready).map(char => char.eve_id);
        const newList = currentReadyCharacters.includes(character.eve_id)
          ? currentReadyCharacters.filter(id => id !== character.eve_id)
          : [...currentReadyCharacters, character.eve_id];

        pendingReadyRef.current = newList;

        try {
          await outCommand({
            type: OutCommand.updateReadyCharacters,
            data: { ready_character_eve_ids: newList },
          });
        } catch (err) {
          console.error('Failed to update ready characters:', err);
          // Drop the optimistic list so the next toggle re-derives from
          // whatever the server actually has.
          pendingReadyRef.current = null;
        } finally {
          inFlightRef.current -= 1;

          if (inFlightRef.current === 0) {
            pendingReadyRef.current = null;
          }
        }
      });

      readyQueueRef.current = run;
      await run;
    },
    [data, outCommand],
  );

  const items = useMemo(
    () =>
      (data || []).map(character => {
        const isExpired = expiredCharacters.includes(character.eve_id);
        const isReady = character.ready || false;
        const tooltip = getTooltipContent(
          character.name,
          isExpired,
          character.tracking_paused,
          character.online,
          isReady,
        );

        return (
          <li
            key={character.eve_id}
            className="flex flex-col items-center justify-center"
            onClick={() => handleSelect(character)}
            onContextMenu={e => handleToggleReady(character, e)}
          >
            <WdTooltipWrapper position={TooltipPosition.bottom} content={tooltip}>
              <WdCharStateWrapper
                eve_id={character.eve_id}
                location={character.location}
                isExpired={isExpired}
                isMain={mainCharacterEveId === character.eve_id}
                isFollowing={followingCharacterEveId === character.eve_id}
                isOnline={character.online}
                isReady={isReady}
                isTrackingPaused={character.tracking_paused}
              >
                <WdEveEntityPortrait
                  eveId={character.eve_id}
                  size={WdEveEntityPortraitSize.w33}
                  className={clsx(
                    'flex w-full h-full bg-transparent cursor-pointer',
                    'bg-center bg-no-repeat bg-[length:100%]',
                    'transition-opacity',
                    'shadow-[inset_0_1px_6px_1px_#000000]',
                    {
                      ['opacity-60']: !isExpired && !character.online,
                      ['opacity-100']: !isExpired && character.online,
                      ['opacity-50']: isExpired,
                    },
                    '!border-0',
                  )}
                />
              </WdCharStateWrapper>
            </WdTooltipWrapper>
          </li>
        );
      }),
    [data, handleSelect, handleToggleReady, mainCharacterEveId, followingCharacterEveId, expiredCharacters],
  );

  return (
    <ul className="flex gap-1 characters" id="characters" ref={parent}>
      {items}
    </ul>
  );
};
