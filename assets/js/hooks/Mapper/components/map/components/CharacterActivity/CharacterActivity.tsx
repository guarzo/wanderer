import React, { useState, useMemo, useCallback } from 'react';
import { DataTable, DataTableSortEvent } from 'primereact/datatable';
import { Column } from 'primereact/column';
import './CharacterActivity.css';

export interface ActivitySummary {
  character_name: string;
  eve_id?: string | number; // Add eve_id for character portraits
  corporation_ticker?: string;
  alliance_ticker?: string;
  passages_traveled?: number;
  connections_created?: number;
  signatures_scanned?: number;
  // Support for legacy format
  passages?: string[];
  connections?: string[];
  signatures?: string[];
}

interface FormattedActivityData {
  character_name: string;
  eve_id?: string | number;
  corporation_ticker?: string;
  passages_display: number;
  connections_display: number;
  signatures_display: number;
  total_activity: number;
}

interface CharacterActivityProps {
  activity: ActivitySummary[];
}

const CharacterActivity: React.FC<CharacterActivityProps> = ({ activity }) => {
  const [sortField, setSortField] = useState('total_activity');
  const [sortOrder, setSortOrder] = useState<1 | -1>(-1);
  const [error, setError] = useState<string | null>(null);

  // Format the data for display using useMemo to prevent unnecessary recalculations
  const formattedData = useMemo(() => {
    try {
      if (!activity || activity.length === 0) {
        return [];
      }
      
      return activity.map(item => {
        const passages = item.passages_traveled !== undefined ? item.passages_traveled : item.passages?.length || 0;
        const connections =
          item.connections_created !== undefined ? item.connections_created : item.connections?.length || 0;
        const signatures = item.signatures_scanned !== undefined ? item.signatures_scanned : item.signatures?.length || 0;

        return {
          character_name: item.character_name,
          eve_id: item.eve_id,
          corporation_ticker: item.corporation_ticker,
          passages_display: passages,
          connections_display: connections,
          signatures_display: signatures,
          total_activity: passages + connections + signatures,
        };
      });
    } catch (err) {
      setError(`Error formatting activity data: ${err instanceof Error ? err.message : String(err)}`);
      return [];
    }
  }, [activity]);

  // Character name template with portrait using useCallback
  const characterNameTemplate = useCallback((rowData: FormattedActivityData) => {
    try {
      const portraitUrl = rowData.eve_id
        ? `https://images.evetech.net/characters/${rowData.eve_id}/portrait`
        : 'https://images.evetech.net/characters/1/portrait'; // Default portrait if no eve_id

      return (
        <div className="character-name-cell">
          <div className="character-info">
            <div className="character-portrait">
              <img src={portraitUrl} alt={rowData.character_name} />
            </div>
            <div className="character-name">{rowData.character_name}</div>
          </div>
        </div>
      );
    } catch (err) {
      console.error('Error rendering character name template:', err);
      return <div className="character-name-cell">Error displaying character</div>;
    }
  }, []);

  // Activity value template using useCallback
  const activityValueTemplate = useCallback((rowData: FormattedActivityData, field: keyof FormattedActivityData) => {
    try {
      return <div className="activity-value-cell">{rowData[field]}</div>;
    } catch (err) {
      console.error(`Error rendering activity value for field ${String(field)}:`, err);
      return <div className="activity-value-cell">Error</div>;
    }
  }, []);

  // Handle sort event
  const handleSort = useCallback((e: DataTableSortEvent) => {
    if (e.sortField) {
      setSortField(e.sortField);
    }
    if (e.sortOrder !== undefined && (e.sortOrder === 1 || e.sortOrder === -1)) {
      setSortOrder(e.sortOrder);
    }
  }, []);

  if (error) {
    return (
      <div className="character-activity-container">
        <p className="empty-message error-message">{error}</p>
      </div>
    );
  }

  if (!activity || activity.length === 0) {
    return (
      <div className="character-activity-container">
        <p className="empty-message">No activity data available</p>
      </div>
    );
  }

  return (
    <div className="character-activity-container">
      <DataTable
        value={formattedData}
        sortField={sortField}
        sortOrder={sortOrder}
        onSort={handleSort}
        className="character-activity-datatable"
        emptyMessage="No activity data available"
        scrollable
        scrollHeight="350px"
        stripedRows
      >
        <Column
          field="character_name"
          header="Character"
          sortable
          body={characterNameTemplate}
          className="character-column"
        />
        <Column
          field="passages_display"
          header="Passages"
          sortable
          body={rowData => activityValueTemplate(rowData, 'passages_display')}
          className="numeric-column"
        />
        <Column
          field="connections_display"
          header="Connections"
          sortable
          body={rowData => activityValueTemplate(rowData, 'connections_display')}
          className="numeric-column"
        />
        <Column
          field="signatures_display"
          header="Signatures"
          sortable
          body={rowData => activityValueTemplate(rowData, 'signatures_display')}
          className="numeric-column"
        />
        <Column
          field="total_activity"
          header="Total Activity"
          sortable
          body={rowData => activityValueTemplate(rowData, 'total_activity')}
          className="numeric-column"
        />
      </DataTable>
    </div>
  );
};

export default CharacterActivity;
