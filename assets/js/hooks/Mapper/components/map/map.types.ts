import { SolarSystemRawType } from '@/hooks/Mapper/types/system';
import { SolarSystemConnection } from '@/hooks/Mapper/types/connection';
import { XYPosition } from 'reactflow';

export type MapSolarSystemType = Omit<SolarSystemRawType, 'position'> & {
  solar_system_id: number;
  position_x: number;
  position_y: number;
  visible: boolean;
  owner_ticker: string | null;
};

export type OnMapSelectionChange = (event: {
  systems: string[];
  connections: Pick<SolarSystemConnection, 'source' | 'target'>[];
}) => void;

export type OnMapAddSystemCallback = (props: { coordinates: XYPosition | null }) => void;

export type MapViewport = { zoom: 1; x: 0; y: 0 };
