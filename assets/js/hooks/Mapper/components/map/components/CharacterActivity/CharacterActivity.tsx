import React, { useState, useEffect } from 'react';
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
  passages?: any;
  connections?: any;
  signatures?: any;
  timestamp?: string;
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

  // Sort activity by character name
  const sortedActivity = [...activity].sort((a, b) => 
    a.character_name.localeCompare(b.character_name)
  );

  return (
    <Dialog
      className="character-activity-modal"
      visible={show}
      style={{ width: '800px', maxWidth: '90vw' }}
      onHide={onHide}
      header={`Character Activity [${activity?.length || 0}]`}
      draggable={false}
      resizable={false}
      modal={true}
    >
      <div 
        className="character-activity-container"
        style={{
          height: 'auto',
          minHeight: '100px',
          display: 'flex',
          flexDirection: 'column',
          overflow: 'visible',
        }}
      >
        {activity.length > 0 ? (
          <div style={{ padding: '20px' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ backgroundColor: '#262626', color: '#f0f0f0' }}>
                  <th style={{ padding: '10px', textAlign: 'left' }}>Character</th>
                  <th style={{ padding: '10px', textAlign: 'center' }}>Passages</th>
                  <th style={{ padding: '10px', textAlign: 'center' }}>Connections</th>
                  <th style={{ padding: '10px', textAlign: 'center' }}>Signatures</th>
                </tr>
              </thead>
              <tbody>
                {sortedActivity.map((item, index) => (
                  <tr 
                    key={item.character_id || index} 
                    style={{ 
                      backgroundColor: index % 2 === 0 ? '#1e1e1e' : '#262626',
                      color: '#f0f0f0'
                    }}
                  >
                    <td style={{ padding: '10px' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                        <img 
                          src={`https://images.evetech.net/characters/${item.eve_id}/portrait`} 
                          alt={item.character_name}
                          style={{ width: '32px', height: '32px', borderRadius: '50%' }}
                        />
                        <div>
                          <div>
                            {item.character_name}
                            {item.corporation_ticker && <span style={{ color: '#aaa', marginLeft: '5px' }}>[{item.corporation_ticker}]</span>}
                          </div>
                          <div style={{ fontSize: '0.75rem', color: '#aaa' }}>
                            {item.alliance_ticker && <span>[{item.alliance_ticker}]</span>}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td style={{ padding: '10px', textAlign: 'center' }}>
                      {formatNumber(typeof item.passages_traveled === 'number' ? item.passages_traveled : 
                        (typeof item.passages === 'number' ? item.passages : 0))}
                    </td>
                    <td style={{ padding: '10px', textAlign: 'center' }}>
                      {formatNumber(typeof item.connections_created === 'number' ? item.connections_created : 
                        (typeof item.connections === 'number' ? item.connections : 0))}
                    </td>
                    <td style={{ padding: '10px', textAlign: 'center' }}>
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
