import { useCallback, useMemo, useState } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { Widget } from '@/hooks/Mapper/components/mapInterface/components';
import { SystemKillsList } from './SystemKillsList';
import { KillsHeader } from './components/SystemKillsHeader';
import { useSystemKills } from './hooks/useSystemKills';
import { KillsSettingsDialog } from './components/SystemKillsSettingsDialog';
import { isWormholeSpace } from '@/hooks/Mapper/components/map/helpers/isWormholeSpace';
import { getSystemStaticInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic';

const SystemKillsContent = () => {
  const {
    data: { selectedSystems, isSubscriptionActive },
    outCommand,
    storedSettings: { settingsKills },
  } = useMapRootState();

  const [systemId] = selectedSystems || [];

  const systemStaticInfo = getSystemStaticInfo(systemId)!;

  const { kills, isLoading, error } = useSystemKills({
    systemId,
    outCommand,
    showAllVisible: settingsKills.showAll,
    sinceHours: settingsKills.timeRange,
  });

  const isNothingSelected = !systemId && !settingsKills.showAll;
  const showLoading = isLoading && kills.length === 0;

  const filteredKills = useMemo(() => {
    if (!settingsKills.whOnly || !settingsKills.showAll) return kills;
    return kills.filter(kill => {
      if (!systemStaticInfo) {
        console.warn(`System with id ${kill.solar_system_id} not found.`);
        return false;
      }
      return isWormholeSpace(systemStaticInfo.system_class);
    });
  }, [kills, settingsKills.whOnly, systemStaticInfo, settingsKills.showAll]);

  if (!isSubscriptionActive) {
    return (
      <div className="w-full h-full flex items-center justify-center">
        <span className="select-none text-center text-stone-400/80 text-sm">
          Kills available with &#39;Active&#39; map subscription only (contact map administrators)
        </span>
      </div>
    );
  }

  if (isNothingSelected) {
    return (
      <div className="w-full h-full flex items-center justify-center">
        <span className="select-none text-center text-stone-400/80 text-sm">
          No system selected (or toggle &quot;Show all systems&quot;)
        </span>
      </div>
    );
  }

  if (showLoading) {
    return (
      <div className="w-full h-full flex items-center justify-center">
        <span className="select-none text-center text-stone-400/80 text-sm">Loading Kills...</span>
      </div>
    );
  }

  if (error) {
    return (
      <div className="w-full h-full flex items-center justify-center">
        <span className="select-none text-center text-red-400 text-sm">{error}</span>
      </div>
    );
  }

  if (!filteredKills || filteredKills.length === 0) {
    return (
      <div className="w-full h-full flex items-center justify-center">
        <span className="select-none text-center text-stone-400/80 text-sm">No kills found</span>
      </div>
    );
  }

  return (
    <SystemKillsList kills={filteredKills} onlyOneSystem={!settingsKills.showAll} timeRange={settingsKills.timeRange} />
  );
};

export const WSystemKills = () => {
  const [settingsDialogVisible, setSettingsDialogVisible] = useState(false);
  const {
    data: { selectedSystems },
  } = useMapRootState();

  const [systemId] = selectedSystems || [];

  const handleOpenSettings = useCallback(() => setSettingsDialogVisible(true), []);

  return (
    <Widget label={<KillsHeader systemId={systemId} onOpenSettings={handleOpenSettings} />}>
      <SystemKillsContent />
      {settingsDialogVisible && <KillsSettingsDialog visible setVisible={setSettingsDialogVisible} />}
    </Widget>
  );
};
