import React, { useState, useEffect } from 'react';
import { Dialog } from 'primereact/dialog';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { CharacterTrackingData } from './TrackAndFollow';

// Sample character data for testing
const sampleCharacters: CharacterTrackingData[] = [
  {
    character_id: 'test-char-1',
    character_name: 'Test Character 1',
    eve_id: '2115778369',
    corporation_ticker: 'TEST1',
    alliance_ticker: 'TST1',
    tracked: true,
    followed: false
  },
  {
    character_id: 'test-char-2',
    character_name: 'Test Character 2',
    eve_id: '2115778316',
    corporation_ticker: 'TEST2',
    alliance_ticker: 'TST2',
    tracked: true,
    followed: false
  },
  {
    character_id: 'test-char-3',
    character_name: 'Test Character 3',
    eve_id: '2115769050',
    corporation_ticker: 'TEST3',
    alliance_ticker: 'TST3',
    tracked: false,
    followed: true
  }
];

const TestCharacterData: React.FC = () => {
  const [show, setShow] = useState(false);
  const [characters, setCharacters] = useState<CharacterTrackingData[]>([]);
  const [logs, setLogs] = useState<string[]>([]);

  const addLog = (message: string) => {
    setLogs(prevLogs => {
      const timestamp = new Date().toISOString().substr(11, 8);
      return [`[${timestamp}] ${message}`, ...prevLogs.slice(0, 19)];
    });
  };

  useEffect(() => {
    addLog(`Characters state updated: ${characters.length} characters`);
  }, [characters]);

  const loadSampleData = () => {
    addLog('Loading sample character data');
    setCharacters(sampleCharacters);
    setShow(true);
  };

  const loadLoadingIndicator = () => {
    addLog('Loading indicator character');
    setCharacters([
      {
        character_id: 'loading-indicator',
        character_name: 'Loading Characters...',
        eve_id: '1',
        corporation_ticker: 'LOAD',
        alliance_ticker: 'ING',
        tracked: false,
        followed: false
      }
    ]);
    setShow(true);
  };

  const loadNoCharactersPlaceholder = () => {
    addLog('Loading no characters placeholder');
    setCharacters([
      {
        character_id: 'no-characters-found',
        character_name: 'No Characters Found',
        eve_id: '1',
        corporation_ticker: 'NONE',
        alliance_ticker: 'FOUND',
        tracked: false,
        followed: false
      }
    ]);
    setShow(true);
  };

  const clearData = () => {
    addLog('Clearing character data');
    setCharacters([]);
  };

  const characterNameTemplate = (rowData: CharacterTrackingData) => {
    const portraitUrl = rowData.eve_id
      ? `https://images.evetech.net/characters/${rowData.eve_id}/portrait`
      : 'https://images.evetech.net/characters/1/portrait';

    return (
      <div className="character-name-cell">
        <div className="character-info">
          <div className="character-portrait">
            <img src={portraitUrl} alt={rowData.character_name} />
          </div>
          <div className="character-name">
            {rowData.character_name}
            {rowData.corporation_ticker && (
              <span className="corporation-ticker">[{rowData.corporation_ticker}]</span>
            )}
          </div>
        </div>
      </div>
    );
  };

  return (
    <div style={{ 
      position: 'fixed', 
      bottom: '80px', 
      right: '10px', 
      zIndex: 9998,
      background: 'rgba(0, 0, 0, 0.7)',
      padding: '10px',
      borderRadius: '5px',
      color: 'white',
      fontSize: '12px',
      maxWidth: '300px'
    }}>
      <div style={{ marginBottom: '5px', fontWeight: 'bold' }}>Test Character Data</div>
      
      <div style={{ display: 'flex', flexDirection: 'column', gap: '5px', marginBottom: '10px' }}>
        <button
          onClick={loadSampleData}
          style={{ 
            padding: '5px 10px',
            background: '#4CAF50',
            color: '#fff',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer'
          }}
        >
          Load Sample Data
        </button>
        
        <button
          onClick={loadLoadingIndicator}
          style={{ 
            padding: '5px 10px',
            background: '#2196F3',
            color: '#fff',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer'
          }}
        >
          Show Loading Indicator
        </button>
        
        <button
          onClick={loadNoCharactersPlaceholder}
          style={{ 
            padding: '5px 10px',
            background: '#FF9800',
            color: '#fff',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer'
          }}
        >
          Show No Characters
        </button>
        
        <button
          onClick={clearData}
          style={{ 
            padding: '5px 10px',
            background: '#F44336',
            color: '#fff',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer'
          }}
        >
          Clear Data
        </button>
        
        <button
          onClick={() => setShow(!show)}
          style={{ 
            padding: '5px 10px',
            background: '#9C27B0',
            color: '#fff',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer'
          }}
        >
          {show ? 'Hide Dialog' : 'Show Dialog'}
        </button>
      </div>
      
      <div style={{ 
        maxHeight: '150px', 
        overflowY: 'auto', 
        border: '1px solid #555', 
        padding: '5px',
        fontSize: '10px',
        fontFamily: 'monospace'
      }}>
        {logs.map((log, index) => (
          <div key={index} style={{ marginBottom: '2px' }}>{log}</div>
        ))}
      </div>
      
      <Dialog
        header="Test Character Data"
        visible={show}
        style={{ width: '90%', maxWidth: '800px' }}
        className="DialogTrackAndFollow"
        onHide={() => setShow(false)}
        draggable={false}
        resizable={false}
        modal={true}
      >
        <div className="track-follow-container">
          {characters.length === 0 ? (
            <div className="empty-message">No characters available</div>
          ) : (
            <DataTable
              value={characters}
              className="track-follow-datatable"
              emptyMessage="No characters available"
              scrollable
              scrollHeight="350px"
              stripedRows
            >
              <Column
                field="character_name"
                header="Character"
                body={characterNameTemplate}
                className="character-column"
              />
              <Column field="tracked" header="Track" className="track-column" />
              <Column field="followed" header="Follow" className="follow-column" />
            </DataTable>
          )}
        </div>
      </Dialog>
    </div>
  );
};

export default TestCharacterData; 