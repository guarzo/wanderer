import React, { useState, useEffect, useCallback } from 'react';
import { Dialog } from 'primereact/dialog';
import { Checkbox } from 'primereact/checkbox';
import { RadioButton } from 'primereact/radiobutton';
import './TrackAndFollow.css';

export interface TrackingCharacter {
  id: string;
  name: string;
  corporation_ticker: string;
  alliance_ticker?: string;
  portrait_url: string;
  tracked: boolean;
  followed: boolean;
}

interface TrackAndFollowProps {
  visible: boolean;
  onHide: () => void;
  characters: TrackingCharacter[];
  onTrackChange: (characterId: string) => void;
  onFollowChange: (characterId: string) => void;
  onRefresh: () => void;
}

export const TrackAndFollow: React.FC<TrackAndFollowProps> = ({
  visible,
  onHide,
  characters,
  onTrackChange,
  onFollowChange,
  onRefresh,
}) => {
  const [localCharacters, setLocalCharacters] = useState<TrackingCharacter[]>([]);

  useEffect(() => {
    setLocalCharacters(characters);
  }, [characters]);

  const handleTrackChange = useCallback(
    (characterId: string, checked: boolean) => {
      setLocalCharacters(prev => prev.map(char => (char.id === characterId ? { ...char, tracked: checked } : char)));

      onTrackChange(characterId);
    },
    [onTrackChange],
  );

  const handleFollowChange = useCallback(
    (characterId: string) => {
      setLocalCharacters(prev =>
        prev.map(char => ({
          ...char,
          followed: char.id === characterId,
        })),
      );

      onFollowChange(characterId);
    },
    [onFollowChange],
  );

  const renderHeader = useCallback(() => {
    return (
      <div className="flex justify-between items-center">
        <h2 className="text-xl font-semibold">Track and Follow Characters</h2>
        <button
          className="p-2 rounded hover:bg-gray-700 transition-colors"
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
      onHide={onHide}
      className="DialogTrackAndFollow"
      dismissableMask
      draggable={false}
      resizable={false}
      closeOnEscape
      appendTo={document.body}
    >
      <div className="track-follow-container">
        {localCharacters.length === 0 ? (
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
                <tr key={character.id}>
                  <td className="text-center">
                    <Checkbox
                      checked={character.tracked}
                      onChange={e => handleTrackChange(character.id, e.checked || false)}
                    />
                  </td>
                  <td className="text-center">
                    <RadioButton
                      inputId={`follow-${character.id}`}
                      name="followed_character"
                      value={character.id}
                      onChange={() => handleFollowChange(character.id)}
                      checked={character.followed}
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
                        {character.alliance_ticker && (
                          <span className="alliance-ticker">[{character.alliance_ticker}]</span>
                        )}
                      </div>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </Dialog>
  );
};

export default TrackAndFollow;
