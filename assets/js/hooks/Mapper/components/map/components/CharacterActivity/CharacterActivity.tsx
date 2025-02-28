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

  // Deduplicate activity by character name and user_id
  const deduplicatedActivity = useMemo(() => {
    if (!activity || !Array.isArray(activity) || activity.length === 0) {
      return [];
    }

    console.log('Starting deduplication of', activity.length, 'items');

    // First, group by user_id if available
    const userGroupedActivity = new Map<string, ActivitySummary[]>();
    
    // Group characters by user_id
    activity.forEach(item => {
      const userId = item.user_id || 'unknown';
      if (!userGroupedActivity.has(userId)) {
        userGroupedActivity.set(userId, []);
      }
      userGroupedActivity.get(userId)!.push(item);
    });

    console.log('Grouped into', userGroupedActivity.size, 'unique users');

    // For each user, consolidate their characters into one entry
    const userConsolidated: ActivitySummary[] = [];
    userGroupedActivity.forEach((userItems, userId) => {
      if (userItems.length === 1) {
        // If only one character for this user, add it directly
        userConsolidated.push(userItems[0]);
      } else {
        // If multiple characters, consolidate them
        const primaryItem = userItems[0]; // Use first character as primary
        
        // Sum up all activity
        const passages = userItems.reduce(
          (sum, item) => sum + (typeof item.passages_traveled === 'number' ? item.passages_traveled : 0), 
          0
        );
        
        const connections = userItems.reduce(
          (sum, item) => sum + (typeof item.connections_created === 'number' ? item.connections_created : 0), 
          0
        );
        
        const signatures = userItems.reduce(
          (sum, item) => sum + (typeof item.signatures_scanned === 'number' ? item.signatures_scanned : 0), 
          0
        );
        
        // Create consolidated entry
        userConsolidated.push({
          ...primaryItem,
          passages_traveled: passages,
          connections_created: connections,
          signatures_scanned: signatures
        });
      }
    });

    console.log('Consolidated to', userConsolidated.length, 'entries after user grouping');

    // Final deduplication by character name for any remaining duplicates
    const activityMap = new Map<string, ActivitySummary>();
    
    userConsolidated.forEach(item => {
      const key = item.character_name;
      
      if (activityMap.has(key)) {
        const existingItem = activityMap.get(key)!;
        
        // Sum up the activity counts
        const passages = 
          (typeof existingItem.passages_traveled === 'number' ? existingItem.passages_traveled : 0) + 
          (typeof item.passages_traveled === 'number' ? item.passages_traveled : 0);
        
        const connections = 
          (typeof existingItem.connections_created === 'number' ? existingItem.connections_created : 0) + 
          (typeof item.connections_created === 'number' ? item.connections_created : 0);
        
        const signatures = 
          (typeof existingItem.signatures_scanned === 'number' ? existingItem.signatures_scanned : 0) + 
          (typeof item.signatures_scanned === 'number' ? item.signatures_scanned : 0);
        
        // Update the existing item
        activityMap.set(key, {
          ...existingItem,
          passages_traveled: passages,
          connections_created: connections,
          signatures_scanned: signatures
        });
      } else {
        // Add the new item to the map
        activityMap.set(key, item);
      }
    });

    const result = Array.from(activityMap.values());
    console.log('Final deduplication result:', result.length, 'unique characters');
    
    return result;
  }, [activity]);

  // Sort activity by character name
  const sortedActivity = useMemo(() => {
    return [...deduplicatedActivity].sort((a, b) => 
      a.character_name.localeCompare(b.character_name)
    );
  }, [deduplicatedActivity]);

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
      header={`Character Activity [${deduplicatedActivity.length || 0}]`}
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
