import { useState, useEffect, useCallback } from 'react';
import { Dialog } from 'primereact/dialog';
import './TrackAndFollow.scss';
import { TrackingCharacterWrapper } from './TrackingCharacterWrapper';
import { TrackingCharacter } from './types';

interface TrackAndFollowProps {
  visible: boolean;
  onHide: () => void;
  characters: TrackingCharacter[];
  onTrackChange: (characterId: string) => void;
  onFollowChange: (characterId: string) => void;
  onRefresh: () => void;
}

/**
 * Component for tracking and following characters
 */
export const TrackAndFollow = ({
  visible,
  onHide,
  characters,
  onTrackChange,
  onFollowChange,
  onRefresh,
}: TrackAndFollowProps) => {
  const [localCharacters, setLocalCharacters] = useState<TrackingCharacter[]>([]);

  // Update local state whenever the characters prop changes
  useEffect(() => {
    if (characters && Array.isArray(characters)) {
      setLocalCharacters([...characters]);
    }
  }, [characters]);

  const handleTrackChange = useCallback(
    (characterId: string, checked: boolean) => {
      // Update local state immediately for responsive UI
      const updatedCharacters = localCharacters.map(char => {
        if (char.id === characterId) {
          return { ...char, tracked: checked };
        }
        return char;
      });
      setLocalCharacters(updatedCharacters);
      // Call the parent handler to update server state
      onTrackChange(characterId);
    },
    [onTrackChange, localCharacters],
  );

  const handleFollowChange = useCallback(
    (characterId: string) => {
      // Update local state immediately for responsive UI
      const updatedCharacters = localCharacters.map(char => {
        if (char.id === characterId) {
          return { ...char, followed: true };
        }
        return { ...char, followed: false };
      });
      setLocalCharacters(updatedCharacters);
      // Call the parent handler to update server state
      onFollowChange(characterId);
    },
    [onFollowChange, localCharacters],
  );

  // Explicitly handle the dialog hide event
  const handleHide = useCallback(() => {
    if (onHide) {
      onHide();
    }
  }, [onHide]);

  const renderHeader = useCallback(() => {
    return (
      <div className="flex justify-between items-center">
        <h2 className="text-xl font-semibold">Track and Follow Characters</h2>
        <button
          className="p-2 rounded hover:bg-gray-700 transition-colors refresh-button"
          onClick={onRefresh}
          title="Refresh Characters"
        >
          <i className="pi pi-refresh"></i>
        </button>
      </div>
    );
  }, [onRefresh]);

  return (
    <Dialog
      header={renderHeader}
      visible={visible}
      style={{ width: '800px' }}
      onHide={handleHide}
      className="track-follow-dialog"
      dismissableMask
      draggable={false}
      resizable={false}
      closeOnEscape
      appendTo={document.body}
      showHeader={true}
      closable={true}
      modal={true}
      closeIcon="pi pi-times"
    >
      <div className="track-follow-container">
        {!localCharacters || localCharacters.length === 0 ? (
          <div className="empty-message">No characters available for tracking</div>
        ) : (
          <table className="character-table w-full">
            <thead>
              <tr>
                <th className="w-16 text-center">Track</th>
                <th className="w-16 text-center">Follow</th>
                <th>Character</th>
              </tr>
            </thead>
            <tbody>
              {localCharacters.map(character => (
                <TrackingCharacterWrapper
                  key={character.id}
                  character={character}
                  onTrackChange={handleTrackChange}
                  onFollowChange={handleFollowChange}
                />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </Dialog>
  );
};
