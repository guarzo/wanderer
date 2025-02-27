import React, { useState, useCallback, useEffect, useMemo } from 'react';
import { Dialog } from 'primereact/dialog';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { WdCheckbox, WdRadioButton } from '@/hooks/Mapper/components/ui-kit';
import './TrackAndFollow.css';

export interface CharacterTrackingData {
  character_id: string;
  character_name: string;
  eve_id?: string | number;
  corporation_ticker?: string;
  alliance_ticker?: string;
  tracked: boolean;
  followed: boolean;
}

interface TrackAndFollowProps {
  show: boolean;
  onHide: () => void;
  characters?: CharacterTrackingData[];
  onToggleTrack?: (characterId: string) => void;
  onToggleFollow?: (characterId: string) => void;
}

/**
 * Component that displays a dialog for tracking and following characters
 *
 * This component allows users to:
 * - Track multiple characters (checkbox)
 * - Follow a single character (radio button)
 * - View character portraits and affiliation information
 */
const TrackAndFollow: React.FC<TrackAndFollowProps> = ({
  show,
  onHide,
  characters = [],
  onToggleTrack,
  onToggleFollow,
}) => {
  const [followedCharacter, setFollowedCharacter] = useState<string | null>(null);
  const [localCharacters, setLocalCharacters] = useState<CharacterTrackingData[]>([]);

  useEffect(() => {
    if (characters && characters.length > 0) {
      setLocalCharacters([...characters]);

      const followed = characters.find(char => char.followed);
      if (followed) {
        setFollowedCharacter(followed.character_id);
      } else {
        setFollowedCharacter(null);
      }
    }
  }, [characters, show]);

  const handleToggleTrack = useCallback(
    (characterId: string) => {
      const character = localCharacters.find(c => c.character_id === characterId);

      if (character?.tracked && character?.followed) {
        setLocalCharacters(prev =>
          prev.map(char => (char.character_id === characterId ? { ...char, tracked: false, followed: false } : char)),
        );

        setFollowedCharacter(null);

        if (onToggleTrack) {
          onToggleTrack(characterId);
        }

        if (onToggleFollow) {
          onToggleFollow(characterId);
        }
      } else {
        setLocalCharacters(prev =>
          prev.map(char => (char.character_id === characterId ? { ...char, tracked: !char.tracked } : char)),
        );

        if (onToggleTrack) {
          onToggleTrack(characterId);
        }
      }
    },
    [localCharacters, onToggleTrack, onToggleFollow],
  );

  const handleToggleFollow = useCallback(
    (characterId: string) => {
      const character = localCharacters.find(c => c.character_id === characterId);

      if (character && !character.tracked) {
        setLocalCharacters(prev =>
          prev.map(char => {
            if (char.character_id === characterId) {
              return { ...char, tracked: true, followed: true };
            } else {
              return { ...char, followed: false }; // Unfollow all other characters
            }
          }),
        );

        setFollowedCharacter(characterId);

        if (onToggleTrack) {
          onToggleTrack(characterId);
        }

        if (onToggleFollow) {
          onToggleFollow(characterId);
        }
      } else {
        const isAlreadyFollowed = followedCharacter === characterId;

        if (isAlreadyFollowed) {
          setLocalCharacters(prev =>
            prev.map(char => ({
              ...char,
              followed: false, // Unfollow all characters
            })),
          );

          setFollowedCharacter(null);
        } else {
          setLocalCharacters(prev =>
            prev.map(char => ({
              ...char,
              followed: char.character_id === characterId,
            })),
          );

          setFollowedCharacter(characterId);
        }

        if (onToggleFollow) {
          onToggleFollow(characterId);
        }
      }
    },
    [followedCharacter, localCharacters, onToggleFollow, onToggleTrack],
  );

  const characterNameTemplate = useCallback((rowData: CharacterTrackingData) => {
    const portraitUrl = rowData.eve_id
      ? `https://images.evetech.net/characters/${rowData.eve_id}/portrait`
      : 'https://images.evetech.net/characters/1/portrait';

    return (
      <div className="character-name-cell">
        <div className="character-info">
          <div className="character-portrait">
            <img src={portraitUrl} alt={rowData.character_name} />
          </div>
          <div>
            <div className="character-name">
              {rowData.character_name}
              {rowData.corporation_ticker && <span className="corporation-ticker">[{rowData.corporation_ticker}]</span>}
            </div>
            <div className="character-affiliation">
              {rowData.alliance_ticker && <span className="alliance-ticker">[{rowData.alliance_ticker}]</span>}
            </div>
          </div>
        </div>
      </div>
    );
  }, []);

  const trackedTemplate = useCallback(
    (rowData: CharacterTrackingData) => {
      return (
        <div
          className="tracked-cell"
          style={{
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
          }}
        >
          <WdCheckbox
            value={rowData.tracked}
            onChange={() => handleToggleTrack(rowData.character_id)}
            size="m"
            label={undefined}
          />
        </div>
      );
    },
    [handleToggleTrack],
  );

  const followedTemplate = useCallback(
    (rowData: CharacterTrackingData) => {
      // Create a direct click handler that updates local state immediately
      const handleRadioClick = () => {
        // If the character is not tracked, we need to track it first
        // and then follow it (this is handled in handleToggleFollow)
        handleToggleFollow(rowData.character_id);
      };

      return (
        <div
          className="followed-cell"
          style={{
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
          }}
        >
          <WdRadioButton
            key={`radio-${rowData.character_id}-${rowData.followed}`}
            value={rowData.character_id}
            name="followed-character"
            checked={rowData.followed}
            onChange={handleRadioClick}
            size="m"
            label={undefined}
            // Don't disable the radio button even if not tracked
            // Instead, we'll handle the tracking logic in handleToggleFollow
            disabled={false}
            // Use the inactive prop to visually indicate when the track checkbox is unchecked
            inactive={!rowData.tracked}
          />
        </div>
      );
    },
    [handleToggleFollow],
  );

  const sortedCharacters = useMemo(() => {
    return [...localCharacters].sort((a, b) => a.character_name.localeCompare(b.character_name));
  }, [localCharacters]);

  const displayCharacters = useMemo(() => {
    if (sortedCharacters.length === 0) {
      return [
        {
          character_id: 'loading-indicator',
          character_name: 'Loading characters...',
          tracked: false,
          followed: false,
        } as CharacterTrackingData,
      ];
    }
    return sortedCharacters;
  }, [sortedCharacters]);

  const useVirtualScroller = useMemo(() => {
    return sortedCharacters.length > 10;
  }, [sortedCharacters.length]);

  const shouldShowScrollbar = useMemo(() => {
    return sortedCharacters.length > 10;
  }, [sortedCharacters.length]);

  const scrollHeight = useMemo(() => {
    const rowHeight = 56;
    const headerHeight = 43;

    if (useVirtualScroller) {
      return `${10 * rowHeight + headerHeight}px`;
    }

    const calculatedHeight = displayCharacters.length * rowHeight + headerHeight;
    return `${calculatedHeight}px`;
  }, [displayCharacters.length, useVirtualScroller]);

  if (!show) {
    return null;
  }

  return (
    <Dialog
      className="DialogTrackAndFollow"
      visible={true}
      style={{ width: '600px', maxWidth: '90vw' }}
      onHide={onHide}
      header={`Track and Follow Characters [${characters.length}]`}
      draggable={false}
      resizable={false}
      modal={true}
    >
      <div className="track-follow-container">
        <DataTable
          value={displayCharacters}
          className={`track-follow-datatable ${shouldShowScrollbar ? '' : 'no-scrollbar'}`}
          emptyMessage="No characters available for tracking"
          scrollable={shouldShowScrollbar}
          scrollHeight={scrollHeight}
          stripedRows
          virtualScrollerOptions={useVirtualScroller ? { itemSize: 56 } : undefined}
          loading={characters.length === 1 && characters[0].character_id === 'loading-indicator'}
        >
          <Column field="character_name" header="Character" body={characterNameTemplate} sortable />
          <Column
            field="tracked"
            header="Track"
            body={trackedTemplate}
            style={{ width: '80px', textAlign: 'center' }}
          />
          <Column
            field="followed"
            header="Follow"
            body={followedTemplate}
            style={{ width: '80px', textAlign: 'center' }}
          />
        </DataTable>
      </div>
    </Dialog>
  );
};

export default TrackAndFollow;
