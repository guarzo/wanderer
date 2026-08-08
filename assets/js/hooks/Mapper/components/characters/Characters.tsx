import { emitMapEvent } from '@/hooks/Mapper/events';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { useAutoAnimate } from '@formkit/auto-animate/react';
import clsx from 'clsx';
import React, { useCallback, useEffect, useMemo, useRef } from 'react';
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
  // previous one instead of onto a stale snapshot.
  //
  // The optimistic list is held until `data` actually reflects it. Dropping it
  // when the queue drains is too early: `outCommand` resolving does not mean
  // the map-state broadcast has landed, so the next toggle would re-derive from
  // `data` that still shows the pre-toggle set and repeat the toggle instead of
  // reversing it.
  const pendingReadyRef = useRef<string[] | null>(null);
  const inFlightRef = useRef(0);
  const readyQueueRef = useRef<Promise<unknown>>(Promise.resolve());
  const submittedReadyRef = useRef<string[] | null>(null);
  const settleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearPendingReady = useCallback(() => {
    pendingReadyRef.current = null;
    submittedReadyRef.current = null;

    if (settleTimerRef.current !== null) {
      clearTimeout(settleTimerRef.current);
      settleTimerRef.current = null;
    }
  }, []);

  // Release the optimistic list once the broadcast confirms the submitted set.
  useEffect(() => {
    const submitted = submittedReadyRef.current;
    if (submitted === null || inFlightRef.current > 0) return;

    const actual = (data || []).filter(char => char.ready).map(char => char.eve_id);

    if (actual.length === submitted.length && submitted.every(id => actual.includes(id))) {
      clearPendingReady();
    }
  }, [data, clearPendingReady]);

  useEffect(() => clearPendingReady, [clearPendingReady]);

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

          submittedReadyRef.current = newList;

          // A broadcast that never matches — the server clamped or rejected the
          // list — must not pin the optimistic view forever. Fall back to
          // whatever the server actually has after a bounded wait.
          //
          // Only when nothing is in flight. This timer belongs to the toggle
          // that armed it; a newer toggle issued just before it fires has
          // already read `pendingReadyRef` but has not yet resolved to re-arm.
          // Clearing there would send the toggle after it back to `data`, which
          // does not yet reflect the in-flight update — the exact stale-snapshot
          // compose this ref exists to prevent. The in-flight request re-arms on
          // resolve and clears outright on failure, so the fallback is deferred,
          // never lost.
          if (settleTimerRef.current !== null) clearTimeout(settleTimerRef.current);
          settleTimerRef.current = setTimeout(() => {
            if (inFlightRef.current === 0) clearPendingReady();
          }, 5000);
        } catch (err) {
          console.error('Failed to update ready characters:', err);
          // Drop the optimistic list so the next toggle re-derives from
          // whatever the server actually has.
          clearPendingReady();
        } finally {
          inFlightRef.current -= 1;
        }
      });

      readyQueueRef.current = run;
      await run;
    },
    [data, outCommand, clearPendingReady],
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
