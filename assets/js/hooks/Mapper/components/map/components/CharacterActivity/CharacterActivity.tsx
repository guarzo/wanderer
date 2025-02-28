import React, { useState, useEffect, useMemo } from 'react';
import { Dialog } from 'primereact/dialog';
import './CharacterActivity.css';

/**
 * Summary of a character's activity
 */
export interface ActivitySummary {
  character_id?: string;
  character_name: string;
  eve_id: string;
  corporation_ticker: string;
  alliance_ticker?: string;
  passages_traveled?: number;
  connections_created?: number;
  signatures_scanned?: number;
  passages?: number | unknown;
  connections?: number | unknown;
  signatures?: number | unknown;
  timestamp?: string;
  user_id?: string;
}

/**
 * Props for the CharacterActivity component
 */
export interface CharacterActivityProps {
  /** Whether the dialog should be shown */
  show: boolean;
  /** Callback for when the dialog is hidden */
  onHide: () => void;
  /** Array of character activity data */
  activity: ActivitySummary[];
}

/**
 * Component that displays character activity in a dialog
 *
 * This component shows a table of character activity, including:
 * - Character name and portrait
 * - Number of passages traveled
 * - Number of connections created
 * - Number of signatures scanned
 */
export const CharacterActivity: React.FC<CharacterActivityProps> = ({ show, onHide, activity = [] }) => {
  // Simple state to force re-renders
  const [, setForceUpdate] = useState<number>(0);
  
  // Force a re-render when the component is shown or activity changes
  useEffect(() => {
    if (show) {
      console.log('CharacterActivity shown with', activity.length, 'items');
      
      // Log a sample of the data to help with debugging
      if (activity.length > 0) {
        console.log('Sample activity item:', activity[0]);
        
        // Check for duplicate character names
        const characterNames = activity.map(item => item.character_name);
        const uniqueNames = new Set(characterNames);
        console.log(`Character names: ${characterNames.length} total, ${uniqueNames.size} unique`);
        
        if (characterNames.length !== uniqueNames.size) {
          console.log('Duplicate character names detected:');
          const nameCounts = characterNames.reduce((acc, name) => {
            acc[name] = (acc[name] || 0) + 1;
            return acc;
          }, {} as Record<string, number>);
          
          Object.entries(nameCounts)
            .filter(([_, count]) => count > 1)
            .forEach(([name, count]) => {
              console.log(`  - ${name}: ${count} occurrences`);
            });
        }
        
        // Check for characters from the same user
        const userGroups: Record<string, string[]> = {};
        activity.forEach(item => {
          if (item.user_id) {
            if (!userGroups[item.user_id]) {
              userGroups[item.user_id] = [];
            }
            userGroups[item.user_id].push(item.character_name);
          }
        });
        
        // Log users with multiple characters
        const usersWithMultipleChars = Object.entries(userGroups)
          .filter(([_, chars]) => chars.length > 1);
        
        if (usersWithMultipleChars.length > 0) {
          console.log('Users with multiple characters:');
          usersWithMultipleChars.forEach(([userId, chars]) => {
            console.log(`  - User ${userId}: ${chars.join(', ')}`);
          });
        }
      }
      
      // Force a re-render after a short delay
      const timer = setTimeout(() => {
        setForceUpdate(prev => prev + 1);
      }, 100);
      return () => clearTimeout(timer);
    }
  }, [show, activity]);

  // Format numbers with commas
  const formatNumber = (value: number | undefined) => {
    if (value === undefined) return '0';
    return value.toLocaleString();
  };

  // Sort activity by character name
  const sortedActivity = useMemo(() => {
    if (!activity || !Array.isArray(activity) || activity.length === 0) {
      return [];
    }

    console.log('Sorting activity data with', activity.length, 'items');
    
    // The backend now handles deduplication, so we just need to sort
    return [...activity].sort((a, b) => 
      a.character_name.localeCompare(b.character_name)
    );
  }, [activity]);

  // Calculate the max height for the table container
  const calculateMaxHeight = () => {
    const rowHeight = 56; // Height of each row in pixels
    const headerHeight = 43; // Height of the header in pixels
    const maxVisibleRows = 10; // Maximum number of rows to show without scrolling
    const footerHeight = 20; // Extra padding at the bottom

    if (sortedActivity.length <= maxVisibleRows) {
      return `${sortedActivity.length * rowHeight + headerHeight + footerHeight}px`;
    } else {
      return `${maxVisibleRows * rowHeight + headerHeight + footerHeight}px`;
    }
  };

  return (
    <Dialog
      className="character-activity-modal"
      visible={show}
      style={{ width: '800px', maxWidth: '90vw' }}
      onHide={onHide}
      header={`Character Activity [${sortedActivity.length || 0}]`}
      draggable={false}
      resizable={false}
      modal={true}
    >
      <div className="character-activity-container">
        {sortedActivity.length > 0 ? (
          <div 
            className="table-container" 
            style={{ maxHeight: calculateMaxHeight() }}
          >
            <table className="activity-table">
              <thead>
                <tr className="table-header">
                  <th style={{ textAlign: 'left' }}>Character</th>
                  <th style={{ textAlign: 'center' }}>Passages</th>
                  <th style={{ textAlign: 'center' }}>Connections</th>
                  <th style={{ textAlign: 'center' }}>Signatures</th>
                </tr>
              </thead>
              <tbody>
                {sortedActivity.map((item, index) => (
                  <tr 
                    key={item.character_id || index} 
                    className="table-row"
                  >
                    <td>
                      <div className="character-info">
                        <div className="character-portrait">
                          <img 
                            src={`https://images.evetech.net/characters/${item.eve_id}/portrait`} 
                            alt={item.character_name}
                          />
                        </div>
                        <div className="character-name-container">
                          <div className="character-name">
                            {item.character_name}
                            {item.corporation_ticker && <span className="corporation-ticker">[{item.corporation_ticker}]</span>}
                          </div>
                          <div>
                            {item.alliance_ticker && <span className="alliance-ticker">[{item.alliance_ticker}]</span>}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td className="text-center">
                      {formatNumber(typeof item.passages_traveled === 'number' ? item.passages_traveled : 
                        (typeof item.passages === 'number' ? item.passages : 0))}
                    </td>
                    <td className="text-center">
                      {formatNumber(typeof item.connections_created === 'number' ? item.connections_created : 
                        (typeof item.connections === 'number' ? item.connections : 0))}
                    </td>
                    <td className="text-center">
                      {formatNumber(typeof item.signatures_scanned === 'number' ? item.signatures_scanned : 
                        (typeof item.signatures === 'number' ? item.signatures : 0))}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div style={{ padding: '20px', textAlign: 'center' }}>
            <p style={{ fontSize: '1.125rem', marginBottom: '0.5rem' }}>No activity data available</p>
            <p style={{ fontSize: '0.875rem', color: '#9aa5ce' }}>
              Character activity will appear here when your characters move around the map.
            </p>
          </div>
        )}
      </div>
    </Dialog>
  );
};

export default CharacterActivity;
