import { DataTable } from 'primereact/datatable';
import { Column } from 'primereact/column';
import { useMemo } from 'react';
import { TrackingCharacter } from '@/hooks/Mapper/types';
import { CharacterCard } from '@/hooks/Mapper/components/ui-kit';
import { useTracking } from '@/hooks/Mapper/components/mapRootContent/components/TrackingDialog/TrackingProvider.tsx';
import { getSystemStaticInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic';
import { ProgressSpinner } from 'primereact/progressspinner';

const getRowClassName = () => ['text-xs', 'leading-tight'];

const renderCharacterName = (character: TrackingCharacter) => {
  return (
    <div className="flex items-center gap-2">
      <CharacterCard compact isOwn {...character.character} />
    </div>
  );
};

const renderSystemLocation = (character: TrackingCharacter) => {
  const char = character.character;

  if (!char.solar_system_id) {
    return <span className="text-stone-400">Unknown location</span>;
  }

  const systemStaticInfo = getSystemStaticInfo(char.solar_system_id);
  const systemName = systemStaticInfo?.solar_system_name || `System ${char.solar_system_id}`;

  return (
    <div className="flex flex-col">
      <span className="font-medium">{systemName}</span>
      {char.structure_id && <span className="text-xs text-stone-500">Structure {char.structure_id}</span>}
      {char.station_id && <span className="text-xs text-stone-500">Station {char.station_id}</span>}
    </div>
  );
};

const renderShipType = (character: TrackingCharacter) => {
  const char = character.character;

  if (!char.ship_name) {
    return <span className="text-stone-400">Unknown ship</span>;
  }

  const shipTypeName = char.ship_info?.ship_type_info?.name;

  return (
    <div className="flex items-center space-x-2">
      <span className="font-medium">{char.ship_name}</span>
      {shipTypeName && <span className="text-xs text-stone-500">({shipTypeName})</span>}
    </div>
  );
};

export const FleetReadinessContent = () => {
  const { trackingCharacters, loading } = useTracking();

  // Filter to only show ready characters
  const readyCharacters = useMemo(() => {
    return trackingCharacters.filter(char => char.ready);
  }, [trackingCharacters]);

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-full w-full">
        <ProgressSpinner className="w-[50px] h-[50px]" strokeWidth="4" />
        <div className="mt-4 text-text-color-secondary text-sm">Loading Fleet Readiness...</div>
      </div>
    );
  }

  if (readyCharacters.length === 0) {
    return (
      <div className="p-8 text-center text-text-color-secondary italic">
        No characters are currently marked as ready for combat. Characters must be online, tracked, and marked as ready
        to appear here.
        <div className="mt-4 text-xs text-stone-500">
          Tip: Right-click character portraits in the top bar to mark them as ready.
        </div>
      </div>
    );
  }

  return (
    <div className="w-full h-full flex flex-col overflow-hidden">
      {/* Data Table */}
      <div className="flex-1 overflow-auto custom-scrollbar">
        <DataTable
          value={readyCharacters}
          scrollable
          className="w-full"
          tableClassName="w-full border-0"
          emptyMessage="No ready characters found"
          size="small"
          rowClassName={getRowClassName}
          rowHover
        >
          <Column field="character.name" header="Character" body={renderCharacterName} sortable className="!py-[6px]" />
          <Column
            field="character.location"
            header="Location"
            body={renderSystemLocation}
            sortable
            className="!py-[6px]"
          />
          <Column field="character.ship" header="Ship" body={renderShipType} sortable className="!py-[6px]" />
        </DataTable>
      </div>
    </div>
  );
};
