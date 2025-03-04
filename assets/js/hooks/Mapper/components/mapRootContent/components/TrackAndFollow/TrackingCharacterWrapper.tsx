import { TrackingCharacter } from './types';
import { useState, useEffect } from 'react';
import { WdCheckbox } from '@/hooks/Mapper/components/ui-kit/WdCheckbox/WdCheckbox';
import { CheckboxChangeEvent } from 'primereact/checkbox';
import WdRadioButton from '@/hooks/Mapper/components/ui-kit/WdRadioButton';

interface TrackingCharacterWrapperProps {
  character: TrackingCharacter;
  onTrackChange: (characterId: string, checked: boolean) => void;
  onFollowChange: (characterId: string) => void;
}

/**
 * Component to display a single tracking character with track/follow controls
 */
export const TrackingCharacterWrapper = ({
  character,
  onTrackChange,
  onFollowChange,
}: TrackingCharacterWrapperProps) => {
  // Keep local state for immediate UI updates
  const [isTracked, setIsTracked] = useState(character.tracked);
  const [isFollowed, setIsFollowed] = useState(character.followed);

  // Update local state when props change
  useEffect(() => {
    setIsTracked(character.tracked);
    setIsFollowed(character.followed);
  }, [character.tracked, character.followed]);

  const handleTrackChange = (checked: boolean) => {
    // Update local state immediately
    setIsTracked(checked);
    // Notify parent
    onTrackChange(character.id, checked);
  };

  const handleFollowChange = () => {
    // Update local state immediately
    setIsFollowed(true);
    // Notify parent
    onFollowChange(character.id);
  };

  return (
    <tr key={character.id}>
      <td className="text-center">
        <WdCheckbox
          label=""
          value={isTracked}
          onChange={(event: CheckboxChangeEvent) => {
            handleTrackChange(event.checked || false);
          }}
        />
      </td>
      <td className="text-center">
        <WdRadioButton
          id={`follow-${character.id}`}
          name="followed_character"
          checked={isFollowed}
          onChange={() => {
            handleFollowChange();
          }}
        />
      </td>
      <td>
        <div className="character-info">
          <div className="character-portrait">
            <img src={character.portrait_url} alt={character.name} />
          </div>
          <div className="character-details">
            <span className="character-name">
              {character.name}
              <span className="character-corp ml-1 text-gray-400">[{character.corporation_ticker}]</span>
            </span>
            {character.alliance_ticker && <span className="alliance-ticker">[{character.alliance_ticker}]</span>}
          </div>
        </div>
      </td>
    </tr>
  );
};
