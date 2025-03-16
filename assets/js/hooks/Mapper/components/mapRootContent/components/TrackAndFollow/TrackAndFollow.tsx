import { useCallback, useMemo } from 'react';
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
  const { outCommand, data } = useMapRootState();
  const { trackingCharactersData } = data;

  const characters = useMemo(() => trackingCharactersData || [], [trackingCharactersData]);

  const handleTrackToggle = useCallback(
    async (characterId: string) => {
      try {
        await outCommand({
          type: OutCommand.toggleTrack,
          data: { 'character-id': characterId },
        });
      } catch (error) {
        console.error('Error toggling track:', error);
      }
    },
    [outCommand],
  );

  const handleFollowToggle = useCallback(
    async (characterId: string) => {
      try {
        await outCommand({
          type: OutCommand.toggleFollow,
          data: { 'character-id': characterId },
        });
      } catch (error) {
        console.error('Error toggling follow:', error);
      }
    },
    [outCommand],
  );

  const rowTemplate = (tc: TrackingCharacter) => {
    const characterEveId = tc.character.eve_id;

    return (
      <TrackingCharacterWrapper
        key={characterEveId}
        character={tc.character}
        isTracked={tc.tracked}
        isFollowed={tc.followed}
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
