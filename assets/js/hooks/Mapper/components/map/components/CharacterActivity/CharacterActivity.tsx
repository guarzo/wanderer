import React, { useMemo, useState, useEffect, useRef } from 'react';
import { Dialog } from 'primereact/dialog';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
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
 * Component that displays character activity in a dialog.
 *
 * This component shows a table of character activity, including:
 * - Character name and portrait
 * - Number of passages traveled
 * - Number of connections created
 * - Number of signatures scanned
 */
export const CharacterActivity: React.FC<CharacterActivityProps> = ({ show, onHide, activity = [] }) => {
  const [useVirtualScroller, setUseVirtualScroller] = useState(false);
  const tableRef = useRef<DataTable<ActivitySummary[]>>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const [containerHeight, setContainerHeight] = useState('auto');
  
  // Utility to format numbers with commas.
  const formatNumber = (value: number | undefined) => {
    if (value === undefined) return '0';
    return value.toLocaleString();
  };

  // Sort activity by character name.
  const sortedActivity = useMemo(() => {
    if (!activity || !Array.isArray(activity) || activity.length === 0) {
      return [];
    }
    return [...activity].sort((a, b) => a.character_name.localeCompare(b.character_name));
  }, [activity]);

  // Calculate the maximum height for the table container.
  const calculateMaxHeight = () => {
    const rowHeight = 56; // Height of each row in pixels.
    const headerHeight = 43; // Height of the header in pixels.
    const maxVisibleRows = 10; // Maximum rows to show without scrolling.
    const footerHeight = 20; // Extra padding.
    if (sortedActivity.length <= maxVisibleRows) {
      return `${sortedActivity.length * rowHeight + headerHeight + footerHeight}px`;
    } else {
      return `${maxVisibleRows * rowHeight + headerHeight + footerHeight}px`;
    }
  };

  // Setup virtual scroller when dialog is shown
  useEffect(() => {
    if (show) {
      // Determine if we should use virtual scroller based on data size
      setUseVirtualScroller(sortedActivity.length > 20);
      
      // Calculate container height
      setContainerHeight(calculateMaxHeight());
    }
  }, [show, sortedActivity.length]);

  return (
    <Dialog
      className="character-activity-modal DialogCharacterActivity"
      visible={show}
      style={{ width: '800px', maxWidth: '90vw' }}
      onHide={onHide}
      header={`Character Activity [${sortedActivity.length || 0}]`}
      draggable={false}
      resizable={false}
      modal={true}
    >
      <div className="character-activity-container" ref={containerRef} style={{ height: containerHeight }}>
        {sortedActivity.length > 0 ? (
          <DataTable
            ref={tableRef}
            value={sortedActivity}
            className="character-activity-datatable"
            scrollable
            scrollHeight={useVirtualScroller ? 'flex' : calculateMaxHeight()}
            emptyMessage="No activity data available"
            dataKey="eve_id"
            virtualScrollerOptions={
              useVirtualScroller
                ? {
                    itemSize: 56,
                    scrollHeight: calculateMaxHeight(),
                    lazy: false,
                    showLoader: false,
                    delay: 0,
                    loading: false,
                    numToleratedItems: 10,
                    autoSize: true,
                  }
                : undefined
            }
          >
            <Column
              field="character_name"
              header="Character"
              className="character-column"
              body={rowData => (
                <div className="character-info">
                  <div className="character-portrait">
                    <img
                      src={`https://images.evetech.net/characters/${rowData.eve_id}/portrait`}
                      alt={rowData.character_name}
                    />
                  </div>
                  <div className="character-name-container">
                    <div className="character-name">
                      {rowData.character_name}
                      {rowData.corporation_ticker && (
                        <span className="corporation-ticker">[{rowData.corporation_ticker}]</span>
                      )}
                    </div>
                    <div>
                      {rowData.alliance_ticker && <span className="alliance-ticker">[{rowData.alliance_ticker}]</span>}
                    </div>
                  </div>
                </div>
              )}
            />
            <Column
              field="passages_traveled"
              header="Passages"
              className="numeric-column"
              headerClassName="text-center"
              bodyClassName="text-center"
              body={rowData =>
                formatNumber(
                  typeof rowData.passages_traveled === 'number'
                    ? rowData.passages_traveled
                    : typeof rowData.passages === 'number'
                      ? rowData.passages
                      : 0,
                )
              }
            />
            <Column
              field="connections_created"
              header="Connections"
              className="numeric-column"
              headerClassName="text-center"
              bodyClassName="text-center"
              body={rowData =>
                formatNumber(
                  typeof rowData.connections_created === 'number'
                    ? rowData.connections_created
                    : typeof rowData.connections === 'number'
                      ? rowData.connections
                      : 0,
                )
              }
            />
            <Column
              field="signatures_scanned"
              header="Signatures"
              className="numeric-column"
              headerClassName="text-center"
              bodyClassName="text-center"
              body={rowData =>
                formatNumber(
                  typeof rowData.signatures_scanned === 'number'
                    ? rowData.signatures_scanned
                    : typeof rowData.signatures === 'number'
                      ? rowData.signatures
                      : 0,
                )
              }
            />
          </DataTable>
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
