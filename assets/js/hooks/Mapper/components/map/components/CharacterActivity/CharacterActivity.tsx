import React, { useState, useEffect, useMemo, useCallback } from 'react';
import { Dialog } from 'primereact/dialog';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
import './CharacterActivity.css';

/**
 * Summary of a character's activity
 */
export interface ActivitySummary {
  character_id: string;
  character_name: string;
  corporation_ticker: string;
  alliance_ticker?: string;
  portrait_url: string;
  passages: number;
  connections: number;
  signatures: number;
  user_id?: string;
  user_name?: string;
  is_user?: boolean;
}

/**
 * Props for the CharacterActivity component
 */
interface CharacterActivityProps {
  /** Whether the dialog should be shown */
  show: boolean;
  /** Callback for when the dialog is hidden */
  onHide: () => void;
  /** Array of character activity data */
  activity: ActivitySummary[];
}

// Header style for all columns to match the signatures widget
const headerStyle = {
  textTransform: 'uppercase' as const,
  letterSpacing: '0.5px',
  fontSize: '12px',
  lineHeight: '1.333',
  padding: '2px 4px',
};

// Header style specifically for the character column with more left padding
const characterHeaderStyle = {
  ...headerStyle,
  paddingLeft: '12px',
};

/**
 * Component that displays character activity in a dialog.
 *
 * This component shows a table of character activity, including:
 * - Character name and portrait
 * - Number of passages traveled
 * - Number of connections created
 * - Number of signatures scanned
 */
export const CharacterActivity: React.FC<CharacterActivityProps> = ({ show, onHide, activity }) => {
  const [localActivity, setLocalActivity] = useState<ActivitySummary[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    try {
      if (!activity) {
        setLocalActivity([]);
        setError('No activity data received');
        return;
      }

      const isActivitySummary = (item: unknown): item is ActivitySummary => {
        return (
          item !== null &&
          typeof item === 'object' &&
          'character_id' in (item as Record<string, unknown>) &&
          'character_name' in (item as Record<string, unknown>)
        );
      };

      if (Array.isArray(activity)) {
        const validActivity = activity.filter(isActivitySummary);

        if (validActivity.length === 0 && activity.length > 0) {
          console.error('Activity data items are missing required fields:', activity);
          setError('Activity data is in an invalid format');
          return;
        }

        setLocalActivity(validActivity);
        setError(null);
      } else if (isActivitySummary(activity)) {
        setLocalActivity([activity]);
        setError(null);
      } else if (
        typeof activity === 'object' &&
        activity !== null &&
        'activity' in (activity as Record<string, unknown>) &&
        Array.isArray((activity as Record<string, unknown>).activity)
      ) {
        const activityArray = (activity as Record<string, unknown>).activity as unknown[];
        const validActivity = activityArray.filter(isActivitySummary);
        setLocalActivity(validActivity);
        setError(null);
      } else {
        console.error('Invalid activity data format:', activity);
        setError('Invalid activity data format');
      }
    } catch (err) {
      console.error('Error processing activity data:', err, 'Raw data:', activity);
      setError('Error processing activity data');
    }
  }, [activity]);

  const renderHeader = useMemo(() => {
    return (
      <div className="flex justify-between items-center">
        <h2 className="text-xl font-semibold">Character Activity</h2>
      </div>
    );
  }, []);

  const characterTemplate = useCallback((rowData: ActivitySummary) => {
    return (
      <div className="character-name-cell">
        <div className="character-info">
          <div className="character-portrait">
            <img src={rowData.portrait_url} alt={rowData.character_name} />
          </div>
          <div className="character-name-container">
            <div className="character-name">
              {rowData.is_user ? (
                <>
                  <span className="name-text">{rowData.user_name}</span>{' '}
                  <span className="corporation-ticker">[{rowData.corporation_ticker}]</span>
                </>
              ) : (
                <>
                  <span className="name-text">{rowData.character_name}</span>{' '}
                  <span className="corporation-ticker">[{rowData.corporation_ticker}]</span>
                </>
              )}
            </div>
          </div>
        </div>
      </div>
    );
  }, []);

  const valueTemplate = useCallback((rowData: ActivitySummary, field: keyof ActivitySummary) => {
    return <div className="activity-value-cell">{rowData[field] as number}</div>;
  }, []);

  const rowClassName = useCallback(() => {
    return 'TableRowCompact';
  }, []);

  return (
    <Dialog
      header={renderHeader}
      visible={show}
      style={{ width: '80vw', maxWidth: '650px' }}
      onHide={onHide}
      className="DialogCharacterActivity"
      dismissableMask
      draggable={false}
      resizable={false}
      closeOnEscape
      appendTo={document.body}
    >
      <div className="character-activity-container">
        {error ? (
          <div className="error-message">{error}</div>
        ) : localActivity.length === 0 ? (
          <div className="empty-message">No character activity data available</div>
        ) : (
          <DataTable
            value={localActivity}
            className="character-activity-datatable"
            scrollable
            scrollHeight="350px"
            emptyMessage="No character activity data available"
            sortField="passages"
            sortOrder={-1}
            responsiveLayout="scroll"
            tableStyle={{ tableLayout: 'fixed' }}
            size="small"
            rowClassName={rowClassName}
          >
            <Column
              field="character_name"
              header="Character"
              body={characterTemplate}
              sortable
              className="character-column"
              style={{ width: '40%' }}
              headerStyle={characterHeaderStyle}
            />
            <Column
              field="passages"
              header="Passages"
              body={rowData => valueTemplate(rowData, 'passages')}
              sortable
              className="numeric-column"
              style={{ width: '20%' }}
              headerStyle={headerStyle}
            />
            <Column
              field="connections"
              header="Connections"
              body={rowData => valueTemplate(rowData, 'connections')}
              sortable
              className="numeric-column"
              style={{ width: '20%' }}
              headerStyle={headerStyle}
            />
            <Column
              field="signatures"
              header="Signatures"
              body={rowData => valueTemplate(rowData, 'signatures')}
              sortable
              className="numeric-column"
              style={{ width: '20%' }}
              headerStyle={headerStyle}
            />
          </DataTable>
        )}
      </div>
    </Dialog>
  );
};

export default CharacterActivity;
