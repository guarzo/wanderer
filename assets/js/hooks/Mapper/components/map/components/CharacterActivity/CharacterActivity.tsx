import React, { useState, useEffect } from 'react';
import { VirtualScroller } from 'primereact/virtualscroller';
import './CharacterActivity.css';

// Define the types for our component
interface Character {
  id: string;
  name: string;
  corporation_ticker?: string;
  alliance_ticker?: string;
  eve_id?: string;
}

interface ActivitySummary {
  character: Character;
  passages: number;
  connections: number;
  signatures: number;
}

interface CharacterActivityProps {
  activity: ActivitySummary[];
  onClose?: () => void;
}

type SortField = 'character_name' | 'passages' | 'connections' | 'signatures';
type SortDirection = 'asc' | 'desc';

const CharacterActivity: React.FC<CharacterActivityProps> = ({ activity, onClose }) => {
  // State for sorting
  const [sortBy, setSortBy] = useState<SortField>('character_name');
  const [sortDir, setSortDir] = useState<SortDirection>('asc');
  const [sortedActivity, setSortedActivity] = useState<ActivitySummary[]>([]);

  // Sort the activity data when sort parameters or activity changes
  useEffect(() => {
    const sorted = [...activity].sort((a, b) => {
      let valueA, valueB;
      
      if (sortBy === 'character_name') {
        valueA = a.character.name.toLowerCase();
        valueB = b.character.name.toLowerCase();
      } else {
        valueA = a[sortBy] || 0;
        valueB = b[sortBy] || 0;
      }
      
      if (valueA === valueB) {
        return 0;
      }
      
      if (sortDir === 'asc') {
        return valueA > valueB ? 1 : -1;
      } else {
        return valueA < valueB ? 1 : -1;
      }
    });
    
    setSortedActivity(sorted);
  }, [activity, sortBy, sortDir]);

  // Handle sort column click
  const handleSort = (field: SortField) => {
    if (field === sortBy) {
      setSortDir(sortDir === 'asc' ? 'desc' : 'asc');
    } else {
      setSortBy(field);
      setSortDir('asc');
    }
  };

  // Render sort indicator
  const renderSortIndicator = (field: SortField) => {
    if (sortBy !== field) return null;
    return <span className="sort-indicator">{sortDir === 'asc' ? '↑' : '↓'}</span>;
  };

  // Render character avatar
  const renderCharacterAvatar = (character: Character) => {
    if (character.eve_id) {
      return (
        <div className="avatar">
          <div className="rounded-md w-12 h-12">
            <img 
              src={`https://images.evetech.net/characters/${character.eve_id}/portrait?size=64`} 
              alt={character.name} 
            />
          </div>
        </div>
      );
    } else {
      return (
        <div className="avatar placeholder">
          <div className="rounded-md w-12 h-12 bg-neutral-focus text-neutral-content">
            <span className="text-xl">T</span>
          </div>
        </div>
      );
    }
  };

  return (
    <div className="character-activity-container">
      <div className="character-activity-header">
        <h2>Character Activity</h2>
        {onClose && <button className="close-button" onClick={onClose}>×</button>}
      </div>
      
      <div className="table-header">
        <div 
          className={`header-cell character-header sortable ${sortBy === 'character_name' ? 'sorted' : ''}`}
          onClick={() => handleSort('character_name')}
        >
          Character {renderSortIndicator('character_name')}
        </div>
        <div 
          className={`header-cell text-center sortable ${sortBy === 'passages' ? 'sorted' : ''}`}
          onClick={() => handleSort('passages')}
        >
          Passages {renderSortIndicator('passages')}
        </div>
        <div 
          className={`header-cell text-center sortable ${sortBy === 'connections' ? 'sorted' : ''}`}
          onClick={() => handleSort('connections')}
        >
          Connections {renderSortIndicator('connections')}
        </div>
        <div 
          className={`header-cell text-center sortable ${sortBy === 'signatures' ? 'sorted' : ''}`}
          onClick={() => handleSort('signatures')}
        >
          Signatures {renderSortIndicator('signatures')}
        </div>
      </div>
      
      <div className="virtual-scroller-container">
        <VirtualScroller
          items={sortedActivity}
          itemSize={60}
          className="virtual-scroller"
          style={{ height: '100%' }}
          itemTemplate={(item: ActivitySummary) => (
            <div className="activity-row" key={item.character.id}>
              <div className="activity-row-content">
                <div className="character-cell">
                  <div className="character-info">
                    {renderCharacterAvatar(item.character)}
                    <div className="character-name">
                      {item.character.name}
                      {item.character.corporation_ticker && (
                        <span className="ticker">[{item.character.corporation_ticker}]</span>
                      )}
                    </div>
                  </div>
                </div>
                <div className="text-center">{item.passages}</div>
                <div className="text-center">{item.connections}</div>
                <div className="text-center">{item.signatures}</div>
              </div>
            </div>
          )}
        />
      </div>
    </div>
  );
};

export default CharacterActivity; 