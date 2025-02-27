import React, { useMemo, useCallback, useEffect } from 'react';
import { Dialog } from 'primereact/dialog';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
import './CharacterActivity.css';

/**
 * Represents a system passage by a character
 */
interface Passage {
  id: string;
  system_id: string;
  system_name: string;
  timestamp: string;
}

/**
 * Represents a connection created by a character
 */
interface Connection {
  id: string;
  from_system_id: string;
  to_system_id: string;
  from_system_name: string;
  to_system_name: string;
  timestamp: string;
}

/**
 * Represents a signature scanned by a character
 */
interface Signature {
  id: string;
  system_id: string;
  system_name: string;
  signature_id: string;
  signature_type: string;
  timestamp: string;
}

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
  passages?: Passage[] | number;
  connections?: Connection[] | number;
  signatures?: Signature[] | number;
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
  // Log activity data for debugging
  useEffect(() => {
    if (show) {
      console.log('CharacterActivity dialog shown');
      console.log('Activity data type:', typeof activity);
      console.log('Activity is array:', Array.isArray(activity));
      console.log('Activity length:', activity?.length || 0);
      
      if (activity && activity.length > 0) {
        console.log('First activity item:', activity[0]);
        
        // Check if the data has the expected structure
        const hasExpectedStructure = activity.every(
          item => typeof item === 'object' && item !== null && 'character_name' in item,
        );
        
        console.log('Data has expected structure:', hasExpectedStructure);
        
        // Log any items that don't have the expected structure
        if (!hasExpectedStructure) {
          const invalidItems = activity.filter(
            item => typeof item !== 'object' || item === null || !('character_name' in item),
          );
          console.log('Invalid items:', invalidItems);
        }
      }
    }
  }, [show, activity]);

  // Sort activity by character name
  const sortedActivity = useMemo(() => {
    if (!activity || !Array.isArray(activity)) {
      console.warn('Activity is not an array:', activity);
      return [];
    }
    return [...activity].sort((a, b) => a.character_name.localeCompare(b.character_name));
  }, [activity]);

  // Determine if we should use virtual scroller based on row count
  const useVirtualScroller = useMemo(() => {
    return sortedActivity.length > 10;
  }, [sortedActivity.length]);

  // Determine if we should show scrollbar
  const shouldShowScrollbar = useMemo(() => {
    return sortedActivity.length > 10;
  }, [sortedActivity.length]);

  // Calculate appropriate scrollHeight based on number of rows
  const scrollHeight = useMemo(() => {
    // Row height and header height in pixels
    const rowHeight = 56; // Height of each row in pixels
    const headerHeight = 43; // Height of the header in pixels
    const maxVisibleRows = 10; // Maximum number of rows to show without scrolling

    if (sortedActivity.length === 0) {
      // For empty state, show minimal height
      return '300px';
    } else if (sortedActivity.length <= maxVisibleRows) {
      // For 10 or fewer rows, calculate based on actual count
      const calculatedHeight = sortedActivity.length * rowHeight + headerHeight;
      return `${calculatedHeight}px`;
    } else {
      // For more than 10 rows, show exactly 10 rows plus header
      return `${maxVisibleRows * rowHeight + headerHeight}px`;
    }
  }, [sortedActivity.length]);

  // Format numbers with commas
  const formatNumber = useCallback((value: number | undefined) => {
    if (value === undefined) return '0';
    return value.toLocaleString();
  }, []);

  // Character name template with portrait
  const characterNameTemplate = useCallback((rowData: ActivitySummary) => {
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

  // Templates for numeric columns
  const passagesTemplate = useCallback(
    (rowData: ActivitySummary) => {
      // Handle both number and array formats
      const passages =
        typeof rowData.passages_traveled === 'number'
          ? rowData.passages_traveled
          : typeof rowData.passages === 'number'
            ? rowData.passages
            : 0;
      
      return <div className="text-center">{formatNumber(passages)}</div>;
    },
    [formatNumber],
  );

  const connectionsTemplate = useCallback(
    (rowData: ActivitySummary) => {
      // Handle both number and array formats
      const connections =
        typeof rowData.connections_created === 'number'
          ? rowData.connections_created
          : typeof rowData.connections === 'number'
            ? rowData.connections
            : 0;
      
      return <div className="text-center">{formatNumber(connections)}</div>;
    },
    [formatNumber],
  );

  const signaturesTemplate = useCallback(
    (rowData: ActivitySummary) => {
      // Handle both number and array formats
      const signatures =
        typeof rowData.signatures_scanned === 'number'
          ? rowData.signatures_scanned
          : typeof rowData.signatures === 'number'
            ? rowData.signatures
            : 0;
      
      return <div className="text-center">{formatNumber(signatures)}</div>;
    },
    [formatNumber],
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
          overflow: 'hidden',
        }}
      >
        {activity && activity.length > 0 ? (
          <DataTable
            value={sortedActivity}
            className={`character-activity-datatable ${shouldShowScrollbar ? '' : 'no-scrollbar'}`}
            emptyMessage="No activity data available"
            scrollable={true}
            scrollHeight={scrollHeight}
            stripedRows
            virtualScrollerOptions={
              useVirtualScroller
                ? {
                    itemSize: 56,
                    showLoader: false,
                    loading: false,
                    delay: 250,
                    lazy: false,
                  }
                : undefined
            }
          >
            <Column
              field="character_name"
              header="Character"
              body={characterNameTemplate}
              sortable
              style={{ width: '40%' }}
            />
            <Column
              field="passages_traveled"
              header="Passages"
              body={passagesTemplate}
              sortable
              style={{ width: '20%', textAlign: 'center' }}
            />
            <Column
              field="connections_created"
              header="Connections"
              body={connectionsTemplate}
              sortable
              style={{ width: '20%', textAlign: 'center' }}
            />
            <Column
              field="signatures_scanned"
              header="Signatures"
              body={signaturesTemplate}
              sortable
              style={{ width: '20%', textAlign: 'center' }}
            />
          </DataTable>
        ) : (
          <div className="p-4 text-center">
            <p className="text-lg mb-2">No activity data available</p>
            <p className="text-sm text-gray-400">
              Character activity will appear here when your characters move around the map.
            </p>
          </div>
        )}
      </div>
    </Dialog>
  );
};

export default CharacterActivity;
