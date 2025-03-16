import { useCallback, useEffect, useMemo, useState } from 'react';
import { Dialog } from 'primereact/dialog';
import { VirtualScroller } from 'primereact/virtualscroller';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { TrackingCharacterWrapper } from './TrackingCharacterWrapper';
import { TrackingCharacter } from './types';

interface TrackAndFollowProps {
  visible: boolean;
  onHide: () => void;
}

export const TrackAndFollow = ({ visible, onHide }: TrackAndFollowProps) => {
  const [trackedCharacters, setTrackedCharacters] = useState<string[]>([]);
  const [followedCharacter, setFollowedCharacter] = useState<string | null>(null);

  const { outCommand, data } = useMapRootState();
  const { trackingCharactersData } = data;

  const characters = useMemo(() => trackingCharactersData || [], [trackingCharactersData]);

  useEffect(() => {
    if (!trackingCharactersData) return;

    const newTracked = trackingCharactersData.filter(tc => tc.tracked).map(tc => tc.character.eve_id);

    const followedChar = trackingCharactersData.find(tc => tc.followed);
    const newFollowed = followedChar?.character?.eve_id || null;

    setTrackedCharacters(prev =>
      JSON.stringify(prev.sort()) !== JSON.stringify(newTracked.sort()) ? newTracked : prev,
    );

    setFollowedCharacter(prev => (prev !== newFollowed ? newFollowed : prev));
  }, [trackingCharactersData]);

  /**
   * A small helper that handles the optimistic update + revert pattern.
   */
  const safeToggle = useCallback(
    async (
      onOptimistic: () => void,
      onRevert: () => void,
      outCommandPayload: { type: OutCommand; data: Record<string, string> },
    ) => {
      onOptimistic();
      try {
        await outCommand(outCommandPayload);
      } catch (error) {
        console.error('Error in toggle operation:', error);
        onRevert();
      }
    },
    [outCommand],
  );

  const handleTrackToggle = useCallback(
    async (characterId: string) => {
      const isCurrentlyTracked = trackedCharacters.includes(characterId);
      const isCurrentlyFollowed = followedCharacter === characterId;

      // If untracking a followed character, also unfollow
      if (isCurrentlyFollowed && isCurrentlyTracked) {
        // 1) Unfollow
        await safeToggle(
          () => setFollowedCharacter(null),
          () => setFollowedCharacter(characterId),
          { type: OutCommand.toggleFollow, data: { 'character-id': characterId } },
        );

        // 2) Untrack
        await safeToggle(
          () => setTrackedCharacters(prev => prev.filter(id => id !== characterId)),
          () => setTrackedCharacters(prev => [...prev, characterId]),
          { type: OutCommand.toggleTrack, data: { 'character-id': characterId } },
        );
        return;
      }

      // Normal track toggle
      if (isCurrentlyTracked) {
        await safeToggle(
          () => setTrackedCharacters(prev => prev.filter(id => id !== characterId)),
          () => setTrackedCharacters(prev => [...prev, characterId]),
          { type: OutCommand.toggleTrack, data: { 'character-id': characterId } },
        );
      } else {
        await safeToggle(
          () => setTrackedCharacters(prev => [...prev, characterId]),
          () => setTrackedCharacters(prev => prev.filter(id => id !== characterId)),
          { type: OutCommand.toggleTrack, data: { 'character-id': characterId } },
        );
      }
    },
    [trackedCharacters, followedCharacter, safeToggle],
  );

  const handleFollowToggle = useCallback(
    async (characterEveId: string) => {
      const isCurrentlyFollowed = followedCharacter === characterEveId;
      const isCurrentlyTracked = trackedCharacters.includes(characterEveId);

      // If not followed and not tracked, track first then follow
      if (!isCurrentlyFollowed && !isCurrentlyTracked) {
        // Track
        await safeToggle(
          () => setTrackedCharacters(prev => [...prev, characterEveId]),
          () => setTrackedCharacters(prev => prev.filter(id => id !== characterEveId)),
          { type: OutCommand.toggleTrack, data: { 'character-id': characterEveId } },
        );

        // Follow
        await safeToggle(
          () => setFollowedCharacter(characterEveId),
          () => setFollowedCharacter(null),
          { type: OutCommand.toggleFollow, data: { 'character-id': characterEveId } },
        );
      } else {
        // Toggle follow alone
        await safeToggle(
          () => setFollowedCharacter(isCurrentlyFollowed ? null : characterEveId),
          () => setFollowedCharacter(isCurrentlyFollowed ? characterEveId : null),
          { type: OutCommand.toggleFollow, data: { 'character-id': characterEveId } },
        );
      }
    },
    [followedCharacter, trackedCharacters, safeToggle],
  );

  const isCharacterTrackedInUI = useCallback(
    (characterEveId: string) => trackedCharacters.includes(characterEveId) || followedCharacter === characterEveId,
    [trackedCharacters, followedCharacter],
  );

  const rowTemplate = (tc: TrackingCharacter) => {
    const characterEveId = tc.character.eve_id;
    const isTrackedInUI = isCharacterTrackedInUI(characterEveId);
    const isFollowedInUI = followedCharacter === characterEveId;

    return (
      <TrackingCharacterWrapper
        key={characterEveId}
        character={tc.character}
        isTracked={isTrackedInUI}
        isFollowed={isFollowedInUI}
        onTrackToggle={() => handleTrackToggle(characterEveId)}
        onFollowToggle={() => handleFollowToggle(characterEveId)}
      />
    );
  };

  return (
    <Dialog
      header={<div className="dialog-header">Track &amp; Follow</div>}
      visible={visible}
      onHide={onHide}
      className="w-[500px] text-text-color"
      contentClassName="!p-0"
    >
      <div className="w-full overflow-hidden">
        <div className="grid grid-cols-[5rem_5rem_1fr] items-center p-1 font-normal text-sm border-b border-neutral-800">
          <div className="text-center">Track</div>
          <div className="text-center">Follow</div>
          <div className="px-2">Character</div>
        </div>
        <VirtualScroller items={characters} itemSize={48} itemTemplate={rowTemplate} className="h-72 w-full" />
      </div>
    </Dialog>
  );
};
