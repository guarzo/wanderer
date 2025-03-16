import { useEffect, useMemo, useState } from 'react';
import { Dialog } from 'primereact/dialog';
import { VirtualScroller } from 'primereact/virtualscroller';
import { Toast } from 'primereact/toast';
import { useRef } from 'react';
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
  const [loadingTrack, setLoadingTrack] = useState<string | null>(null);
  const [loadingFollow, setLoadingFollow] = useState<string | null>(null);
  const toast = useRef<Toast>(null);
  const { outCommand, data } = useMapRootState();
  const { trackingCharactersData } = data;
  const characters = useMemo(() => trackingCharactersData || [], [trackingCharactersData]);

  // Log when tracking data is received from backend
  useEffect(() => {
    if (trackingCharactersData) {
      console.log('Received tracking data from backend:', trackingCharactersData);
    }
  }, [trackingCharactersData]);

  // Separate useEffect for tracked characters and followed character
  useEffect(() => {
    if (trackingCharactersData) {
      // Update tracked characters
      const newTrackedCharacters = trackingCharactersData.filter(tc => tc.tracked).map(tc => tc.character.eve_id);

      setTrackedCharacters(newTrackedCharacters);

      // Clear loading state when we receive updated data
      setLoadingTrack(null);
    }
  }, [trackingCharactersData]);

  // Separate useEffect for followed character to avoid circular dependency
  useEffect(() => {
    if (trackingCharactersData) {
      // Find the followed character
      const followedChar = trackingCharactersData.find(tc => tc.followed);
      const newFollowedCharacterId = followedChar?.character?.eve_id || null;

      // Use functional update to avoid dependency on current state
      setFollowedCharacter(prevFollowed => {
        if (prevFollowed !== newFollowedCharacterId) {
          console.log('Updating followed character:', {
            previous: prevFollowed,
            new: newFollowedCharacterId,
          });
          return newFollowedCharacterId;
        }
        return prevFollowed;
      });

      // Clear loading state when we receive updated data
      setLoadingFollow(null);
    }
  }, [trackingCharactersData]);

  const handleTrackToggle = async (characterId: string) => {
    const isCurrentlyTracked = trackedCharacters.includes(characterId);
    const isCurrentlyFollowed = followedCharacter === characterId;

    console.log('Track toggle:', {
      characterId,
      isCurrentlyTracked,
      isCurrentlyFollowed,
      willBe: !isCurrentlyTracked,
    });

    // Set loading state
    setLoadingTrack(characterId);

    // If the character is followed and we're untracking it,
    // we should also unfollow it to maintain consistency
    if (isCurrentlyFollowed && isCurrentlyTracked) {
      console.log('Untracking a followed character - will also unfollow it');

      // Set loading state for follow as well
      setLoadingFollow(characterId);

      // Optimistic UI updates for both track and follow
      setTrackedCharacters(prev => prev.filter(id => id !== characterId));
      setFollowedCharacter(null);

      try {
        // First unfollow the character
        console.log('Sending unfollow command first:', {
          type: OutCommand.toggleFollow,
          data: { 'character-id': characterId },
        });

        await outCommand({
          type: OutCommand.toggleFollow,
          data: { 'character-id': characterId },
        });

        // Then untrack the character
        console.log('Sending untrack command:', {
          type: OutCommand.toggleTrack,
          data: { 'character-id': characterId },
        });

        await outCommand({
          type: OutCommand.toggleTrack,
          data: { 'character-id': characterId },
        });
      } catch (error) {
        console.error('Error during untrack/unfollow sequence:', error);

        // Revert optimistic updates if there was an error
        setTrackedCharacters(prev => [...prev, characterId]);
        setFollowedCharacter(characterId);

        // Clear loading states
        setLoadingTrack(null);
        setLoadingFollow(null);
      }

      return;
    }

    // Normal track toggle for non-followed characters
    // Optimistic UI update
    if (isCurrentlyTracked) {
      setTrackedCharacters(prev => prev.filter(id => id !== characterId));
    } else {
      setTrackedCharacters(prev => [...prev, characterId]);
    }

    try {
      console.log('Sending track command:', {
        type: OutCommand.toggleTrack,
        data: { 'character-id': characterId },
      });

      await outCommand({
        type: OutCommand.toggleTrack,
        data: { 'character-id': characterId },
      });
    } catch (error) {
      console.error('Error during track operation:', error);

      // Revert optimistic update if there was an error
      if (isCurrentlyTracked) {
        setTrackedCharacters(prev => [...prev, characterId]);
      } else {
        setTrackedCharacters(prev => prev.filter(id => id !== characterId));
      }

      // Clear loading state
      setLoadingTrack(null);
    }
  };

  const handleFollowToggle = async (characterEveId: string) => {
    const isCurrentlyFollowed = followedCharacter === characterEveId;
    const isCurrentlyTracked = trackedCharacters.includes(characterEveId);

    console.log('Follow toggle:', {
      characterEveId,
      isCurrentlyFollowed,
      isCurrentlyTracked,
      allTrackedCharacters: trackedCharacters,
      currentFollowedCharacter: followedCharacter,
    });

    // Set loading state
    setLoadingFollow(characterEveId);

    // If not followed and not tracked, we need to track it first
    if (!isCurrentlyFollowed && !isCurrentlyTracked) {
      console.log('Character is not tracked, tracking first before following');

      // Update local state optimistically
      setTrackedCharacters(prev => [...prev, characterEveId]);
      setLoadingTrack(characterEveId);

      try {
        // Send track command first and wait for it to complete
        console.log('Sending track command:', {
          type: OutCommand.toggleTrack,
          data: { 'character-id': characterEveId },
        });

        await outCommand({
          type: OutCommand.toggleTrack,
          data: { 'character-id': characterEveId },
        });

        // Clear track loading state
        setLoadingTrack(null);

        // Wait a moment to ensure backend state is updated
        await new Promise(resolve => setTimeout(resolve, 300));

        // Then send follow command after track completes
        console.log('Sending follow command after track completed:', {
          type: OutCommand.toggleFollow,
          data: { 'character-id': characterEveId },
        });

        // Optimistic UI update for follow
        setFollowedCharacter(characterEveId);

        await outCommand({
          type: OutCommand.toggleFollow,
          data: { 'character-id': characterEveId },
        });
      } catch (error) {
        console.error('Error during track/follow sequence:', error);

        // Revert optimistic updates if there was an error
        setTrackedCharacters(prev => prev.filter(id => id !== characterEveId));

        // If we were trying to follow, revert that too
        if (followedCharacter !== characterEveId) {
          setFollowedCharacter(followedCharacter);
        }

        // Clear loading states
        setLoadingTrack(null);
        setLoadingFollow(null);
      }
    } else {
      // Otherwise just toggle follow
      console.log('Sending follow command directly:', {
        type: OutCommand.toggleFollow,
        data: { 'character-id': characterEveId },
      });

      // Optimistic UI update
      if (isCurrentlyFollowed) {
        setFollowedCharacter(null);
      } else {
        setFollowedCharacter(characterEveId);
      }

      try {
        await outCommand({
          type: OutCommand.toggleFollow,
          data: { 'character-id': characterEveId },
        });
      } catch (error) {
        console.error('Error during follow operation:', error);

        // Revert optimistic update if there was an error
        setFollowedCharacter(isCurrentlyFollowed ? characterEveId : null);

        // Clear loading state
        setLoadingFollow(null);
      }
    }
  };

  // Determine if a character should appear tracked in the UI
  // A character should appear tracked if:
  // 1. It's actually tracked in the backend, OR
  // 2. It's the followed character (even if not tracked in the backend)
  const isCharacterTrackedInUI = (characterEveId: string) => {
    const isActuallyTracked = trackedCharacters.includes(characterEveId);
    const isFollowed = followedCharacter === characterEveId;

    // If a character is followed, it should always appear as tracked in the UI
    // This handles the case where a character is followed but not tracked in the backend
    return isActuallyTracked || isFollowed;
  };

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
        isTrackLoading={loadingTrack === characterEveId}
        isFollowLoading={loadingFollow === characterEveId}
        onTrackToggle={() => handleTrackToggle(characterEveId)}
        onFollowToggle={() => handleFollowToggle(characterEveId)}
      />
    );
  };

  return (
    <>
      <Toast ref={toast} position="top-right" />
      <Dialog
        header={
          <div className="dialog-header">
            <span>Track & Follow</span>
          </div>
        }
        visible={visible}
        onHide={onHide}
        className="w-[500px] text-text-color"
        contentClassName="!p-0"
      >
        <div className="w-full overflow-hidden">
          <div className="grid grid-cols-[80px_80px_1fr] p-1 font-normal text-sm text-center border-b border-[#383838]">
            <div>Track</div>
            <div>Follow</div>
            <div className="text-center">Character</div>
          </div>
          <VirtualScroller items={characters} itemSize={48} itemTemplate={rowTemplate} className="h-72 w-full" />
        </div>
      </Dialog>
    </>
  );
};
