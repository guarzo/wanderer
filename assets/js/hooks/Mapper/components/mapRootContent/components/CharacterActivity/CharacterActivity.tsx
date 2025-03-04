import { useState, useEffect, useCallback } from 'react';
import { Dialog } from 'primereact/dialog';
import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
import './CharacterActivity.scss';

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

interface CharacterActivityProps {
  show: boolean;
  onHide: () => void;
  activity: ActivitySummary[];
}

const getRowClassName = () => 'TableRowCompact';

const renderCharacterTemplate = (rowData: ActivitySummary) => {
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
};

const renderValueTemplate = (rowData: ActivitySummary, field: keyof ActivitySummary) => {
  return <div className="activity-value-cell">{rowData[field] as number}</div>;
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
export const CharacterActivity = ({ show, onHide, activity }: CharacterActivityProps) => {
  const [localActivity, setLocalActivity] = useState<ActivitySummary[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    try {
      if (Array.isArray(activity)) {
        setLocalActivity(activity);
        setError(null);
      } else {
        console.error('Invalid activity data format:', activity);
        setError('Invalid activity data format');
      }
    } catch (err) {
      console.error('Error processing activity data:', err);
      setError('Error processing activity data');
    }
  }, [activity]);

  // Explicitly handle the dialog hide event
  const handleHide = useCallback(() => {
    if (onHide) {
      onHide();
    }
  }, [onHide]);

  const renderHeader = () => (
    <div className="flex justify-between items-center">
      <h2 className="text-xl font-semibold">Character Activity</h2>
    </div>
  );

  return (
    <Dialog
      header={renderHeader}
      visible={show}
      style={{ width: '80vw', maxWidth: '650px' }}
      onHide={handleHide}
      className="character-activity-dialog"
      dismissableMask
      draggable={false}
      resizable={false}
      closeOnEscape
      appendTo={document.body}
      showHeader={true}
      closable={true}
    >
      <div className="character-activity-container">
        {error && <div className="error-message">{error}</div>}
        {!error && localActivity.length === 0 && (
          <div className="empty-message">No character activity data available</div>
        )}
        {!error && localActivity.length > 0 && (
          <DataTable
            value={localActivity}
            className="character-activity-datatable"
            scrollable
            scrollHeight="100%"
            emptyMessage="No character activity data available"
            sortField="passages"
            sortOrder={-1}
            responsiveLayout="scroll"
            tableStyle={{ tableLayout: 'fixed', width: '100%', margin: 0, padding: 0 }}
            size="small"
            rowClassName={getRowClassName}
          >
            <Column
              field="character_name"
              header="Character"
              body={renderCharacterTemplate}
              sortable
              className="character-column"
              headerClassName="header-character"
              style={{ width: '40%' }}
            />
            <Column
              field="passages"
              header="Passages"
              body={rowData => renderValueTemplate(rowData, 'passages')}
              sortable
              className="numeric-column"
              headerClassName="header-standard"
              style={{ width: '20%' }}
            />
            <Column
              field="connections"
              header="Connections"
              body={rowData => renderValueTemplate(rowData, 'connections')}
              sortable
              className="numeric-column"
              headerClassName="header-standard"
              style={{ width: '20%' }}
            />
            <Column
              field="signatures"
              header="Signatures"
              body={rowData => renderValueTemplate(rowData, 'signatures')}
              sortable
              className="numeric-column"
              headerClassName="header-standard"
              style={{ width: '20%' }}
            />
          </DataTable>
        )}
      </div>
    </Dialog>
  );
};
