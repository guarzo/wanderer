import React from 'react';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
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
}

const CharacterActivity: React.FC<CharacterActivityProps> = ({ activity }) => {
  // Render character avatar and name
  const characterBodyTemplate = (rowData: ActivitySummary) => {
    const character = rowData.character;
    
    return (
      <div className="character-info">
        {character.eve_id ? (
          <div className="avatar">
            <div className="rounded-md w-12 h-12">
              <img
                src={`https://images.evetech.net/characters/${character.eve_id}/portrait?size=64`}
                alt={character.name}
              />
            </div>
          </div>
        ) : (
          <div className="avatar placeholder">
            <div className="rounded-md w-12 h-12 bg-neutral-focus text-neutral-content">
              <span className="text-xl">T</span>
            </div>
          </div>
        )}
        <div className="character-name">
          {character.name}
          {character.corporation_ticker && <span className="ticker">[{character.corporation_ticker}]</span>}
        </div>
      </div>
    );
  };

  return (
    <div className="character-activity-container">
      <DataTable
        value={activity}
        scrollable
        scrollHeight="100%"
        className="character-activity-table"
        sortField="character.name"
        sortOrder={1}
        removableSort
        resizableColumns
        columnResizeMode="fit"
        emptyMessage="No activity data available"
        dataKey="character.id"
      >
        <Column
          field="character.name"
          header="Character"
          body={characterBodyTemplate}
          sortable
          className="character-column"
        />
        <Column
          field="passages"
          header="Passages"
          sortable
          className="numeric-column"
          headerClassName="text-center"
          bodyClassName="text-center"
        />
        <Column
          field="connections"
          header="Conn."
          sortable
          className="numeric-column"
          headerClassName="text-center"
          bodyClassName="text-center"
        />
        <Column
          field="signatures"
          header="Sigs"
          sortable
          className="numeric-column"
          headerClassName="text-center"
          bodyClassName="text-center"
        />
      </DataTable>
    </div>
  );
};

export default CharacterActivity; 