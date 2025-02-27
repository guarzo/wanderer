import React, { useState, useEffect } from 'react';
import { CharacterTrackingData } from './TrackAndFollow';

interface DebugPanelProps {
  characters: CharacterTrackingData[];
  show: boolean;
  forceVisible: boolean;
  setForceVisible: (visible: boolean) => void;
}

const DebugPanel: React.FC<DebugPanelProps> = ({ 
  characters, 
  show, 
  forceVisible, 
  setForceVisible 
}) => {
  const [logs, setLogs] = useState<string[]>([]);
  const [expanded, setExpanded] = useState(false);

  // Add a log entry
  const addLog = (message: string) => {
    setLogs(prevLogs => {
      const timestamp = new Date().toISOString().substr(11, 8);
      return [`[${timestamp}] ${message}`, ...prevLogs.slice(0, 49)];
    });
  };

  // Log changes to character data
  useEffect(() => {
    addLog(`Characters updated: ${characters.length} characters`);
    
    if (characters.length === 0) {
      addLog('No characters available');
      return;
    }
    
    // Check if we have a loading indicator
    const isLoadingIndicator = characters.length === 1 && 
      (characters[0].character_id === 'loading-indicator' || 
       characters[0].character_id === 'loading-character' || 
       characters[0].character_name === 'Loading Characters...');
    
    if (isLoadingIndicator) {
      addLog('Loading indicator detected');
      return;
    }
    
    // Check if we have a "no characters found" placeholder
    const isNoCharactersPlaceholder = characters.length === 1 && 
      characters[0].character_id === 'no-characters-found';
    
    if (isNoCharactersPlaceholder) {
      addLog('No characters placeholder detected');
      return;
    }
    
    // Log real character data
    addLog(`Real characters: ${characters.length}`);
    const characterIds = characters.map(char => char.character_id);
    addLog(`Character IDs: ${characterIds.join(', ')}`);
  }, [characters]);

  // Log changes to visibility
  useEffect(() => {
    if (show) {
      addLog('Modal visibility set to true via props');
    } else {
      addLog('Modal visibility set to false via props');
    }
  }, [show]);

  useEffect(() => {
    if (forceVisible) {
      addLog('Modal forced visible via debug panel');
    } else if (!show) {
      addLog('Modal hidden (not forced visible)');
    }
  }, [forceVisible, show]);

  // Trigger loading characters
  const triggerLoadCharacters = () => {
    addLog('Manually triggering character loading');
    
    // Find the window object
    if (typeof window !== 'undefined') {
      // Check if the outCommand function is available
      if (window.outCommand) {
        addLog('Using window.outCommand to trigger add_character');
        window.outCommand({
          type: 'add_character',
          data: null
        });
      } else {
        addLog('ERROR: window.outCommand not available');
      }
    }
  };

  // Force show modal
  const forceShowModal = () => {
    addLog('Forcing modal visibility');
    setForceVisible(true);
  };

  // Log character data
  const logCharacterData = () => {
    addLog(`Logging character data (${characters.length} characters)`);
    
    if (characters.length === 0) {
      addLog('No characters available to log');
      return;
    }
    
    characters.forEach((char, index) => {
      addLog(`Character ${index + 1}: ${char.character_name} (${char.character_id})`);
    });
  };

  return (
    <div style={{ 
      position: 'fixed', 
      bottom: '10px', 
      left: '10px', 
      zIndex: 9999,
      background: 'rgba(0, 0, 0, 0.8)',
      padding: '10px',
      borderRadius: '5px',
      color: '#00ff00',
      fontFamily: 'monospace',
      fontSize: '12px',
      width: expanded ? '500px' : '200px',
      maxHeight: expanded ? '400px' : '40px',
      overflow: 'hidden',
      transition: 'all 0.3s ease'
    }}>
      <div 
        style={{ 
          display: 'flex', 
          justifyContent: 'space-between', 
          alignItems: 'center',
          marginBottom: expanded ? '10px' : '0',
          cursor: 'pointer'
        }}
        onClick={() => setExpanded(!expanded)}
      >
        <strong>TrackAndFollow Debug</strong>
        <span>{expanded ? '▼' : '▲'}</span>
      </div>
      
      {expanded && (
        <>
          <div style={{ 
            display: 'flex', 
            gap: '5px', 
            marginBottom: '10px',
            flexWrap: 'wrap'
          }}>
            <button
              onClick={triggerLoadCharacters}
              style={{ 
                background: '#333',
                color: '#fff',
                border: 'none',
                padding: '5px 10px',
                cursor: 'pointer',
                borderRadius: '3px',
                fontSize: '11px'
              }}
            >
              Load Characters
            </button>
            
            <button
              onClick={() => setForceVisible(!forceVisible)}
              style={{ 
                background: forceVisible ? '#990000' : '#333',
                color: '#fff',
                border: 'none',
                padding: '5px 10px',
                cursor: 'pointer',
                borderRadius: '3px',
                fontSize: '11px'
              }}
            >
              {forceVisible ? 'Disable Force' : 'Force Visible'}
            </button>
            
            <button
              onClick={logCharacterData}
              style={{ 
                background: '#333',
                color: '#fff',
                border: 'none',
                padding: '5px 10px',
                cursor: 'pointer',
                borderRadius: '3px',
                fontSize: '11px'
              }}
            >
              Log Characters
            </button>
          </div>
          
          <div style={{ 
            fontSize: '11px', 
            marginBottom: '5px',
            display: 'flex',
            flexWrap: 'wrap',
            gap: '10px'
          }}>
            <span>Show: {show ? 'true' : 'false'}</span>
            <span>Force: {forceVisible ? 'true' : 'false'}</span>
            <span>Chars: {characters.length}</span>
            <span>
              Type: {
                characters.length === 0 ? 'None' :
                characters.length === 1 && 
                (characters[0].character_id === 'loading-indicator' || 
                 characters[0].character_id === 'loading-character' || 
                 characters[0].character_name === 'Loading Characters...') ? 'Loading' :
                characters.length === 1 && 
                characters[0].character_id === 'no-characters-found' ? 'No Chars' :
                'Real Data'
              }
            </span>
          </div>
          
          <div style={{ 
            maxHeight: '300px', 
            overflowY: 'auto', 
            border: '1px solid #333', 
            padding: '5px',
            fontSize: '10px'
          }}>
            {logs.map((log, index) => (
              <div key={index} style={{ marginBottom: '2px' }}>{log}</div>
            ))}
          </div>
        </>
      )}
    </div>
  );
};

export default DebugPanel; 