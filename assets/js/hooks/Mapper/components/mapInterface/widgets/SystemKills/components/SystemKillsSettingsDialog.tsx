import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Dialog } from 'primereact/dialog';
import { Button } from 'primereact/button';
import { WdImgButton, SystemView } from '@/hooks/Mapper/components/ui-kit';
import { PrimeIcons } from 'primereact/api';
import { useKillsWidgetSettings } from '../hooks/useKillsWidgetSettings';
import {
  AddSystemDialog,
  SearchOnSubmitCallback,
} from '@/hooks/Mapper/components/mapInterface/components/AddSystemDialog';

interface KillsSettingsDialogProps {
  visible: boolean;
  setVisible: (visible: boolean) => void;
}

export const KillsSettingsDialog: React.FC<KillsSettingsDialogProps> = ({ visible, setVisible }) => {
  // Get global kills settings
  const [globalSettings, setGlobalSettings] = useKillsWidgetSettings();
  // We'll store local settings in a ref (so we only push changes when user clicks "Apply")
  const localRef = useRef({
    compact: globalSettings.compact,
    showAll: globalSettings.showAll,
    excludedSystems: globalSettings.excludedSystems || [],
  });

  const [, forceRender] = useState(0);

  // We also need local state to show/hide the "Add System" dialog
  const [addSystemDialogVisible, setAddSystemDialogVisible] = useState(false);

  /**
   * Whenever the dialog becomes visible, reset localRef
   * so that we reflect the *latest* global settings.
   */
  useEffect(() => {
    if (visible) {
      localRef.current = {
        compact: globalSettings.compact,
        showAll: globalSettings.showAll,
        excludedSystems: globalSettings.excludedSystems || [],
      };
      forceRender(n => n + 1); // Trigger a re-render
    }
  }, [visible, globalSettings]);

  /**
   * Called when user checks/unchecks the "compact mode" toggle
   */
  const handleCompactChange = useCallback((checked: boolean) => {
    localRef.current = {
      ...localRef.current,
      compact: checked,
    };
    forceRender(n => n + 1);
  }, []);

  /**
   * Remove a system from the local excludedSystems array
   */
  const handleRemoveSystem = useCallback((sysId: number) => {
    localRef.current = {
      ...localRef.current,
      excludedSystems: localRef.current.excludedSystems.filter(id => id !== sysId),
    };
    forceRender(n => n + 1);
  }, []);

  /**
   * Called when user adds a system from the AddSystemDialog
   */
  const handleAddSystemSubmit: SearchOnSubmitCallback = useCallback(item => {
    // item.value is the numeric systemId
    // If the system is already in the list, do nothing
    if (localRef.current.excludedSystems.includes(item.value)) {
      return;
    }
    // Otherwise, add it
    localRef.current = {
      ...localRef.current,
      excludedSystems: [...localRef.current.excludedSystems, item.value],
    };
    forceRender(n => n + 1);
  }, []);

  /**
   * When user hits "Apply," update the global kills settings
   */
  const handleApply = useCallback(() => {
    setGlobalSettings(prev => ({
      ...prev,
      ...localRef.current,
    }));
    setVisible(false);
  }, [setGlobalSettings, setVisible]);

  /**
   * Close the dialog without saving
   */
  const handleHide = useCallback(() => {
    setVisible(false);
  }, [setVisible]);

  // Pull the local (in-progress) data for easy reading:
  const localData = localRef.current;
  const excluded = localData.excludedSystems || [];

  return (
    <Dialog header="Kills Settings" visible={visible} style={{ width: '440px' }} draggable={false} onHide={handleHide}>
      <div className="flex flex-col gap-3 p-2.5">
        {/* Compact mode toggle */}
        <div className="flex items-center gap-2">
          <input
            type="checkbox"
            id="kills-compact-mode"
            checked={localData.compact}
            onChange={e => handleCompactChange(e.target.checked)}
          />
          <label htmlFor="kills-compact-mode" className="cursor-pointer">
            Use compact mode
          </label>
        </div>

        {/* Excluded Systems Section */}
        <div className="flex flex-col gap-1">
          <div className="flex items-center justify-between">
            <label className="text-sm text-stone-400">Excluded Systems</label>
            <WdImgButton
              className={PrimeIcons.PLUS_CIRCLE}
              onClick={() => setAddSystemDialogVisible(true)}
              tooltip={{ content: 'Add system to excluded list' }}
            />
          </div>
          {excluded.length === 0 && <div className="text-stone-500 text-xs italic">No systems excluded.</div>}
          {excluded.map(sysId => (
            <div key={sysId} className="flex items-center justify-between border-b border-stone-600 py-1 px-1 text-xs">
              {/* Because <SystemView> requires a string ID, convert sysId -> string */}
              <SystemView systemId={sysId.toString()} hideRegion compact />

              <WdImgButton
                className={PrimeIcons.TRASH}
                onClick={() => handleRemoveSystem(sysId)}
                tooltip={{ content: 'Remove from excluded', position: 'top' }}
              />
            </div>
          ))}
        </div>

        {/* Apply + Close button row */}
        <div className="flex gap-2 justify-end mt-4">
          <Button onClick={handleApply} label="Apply" outlined size="small" />
        </div>
      </div>

      {/* AddSystemDialog for picking new systems to exclude */}
      <AddSystemDialog
        title="Add system to kills exclude list"
        visible={addSystemDialogVisible}
        setVisible={() => setAddSystemDialogVisible(false)}
        onSubmit={handleAddSystemSubmit}
        excludedSystems={excluded}
      />
    </Dialog>
  );
};
