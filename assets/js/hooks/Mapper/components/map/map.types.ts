import { SolarSystemConnection } from '@/hooks/Mapper/types/connection';
import { XYPosition } from 'reactflow';

export type MapSolarSystemType = {
  id: string;
  name: string;
  solar_system_id: number;
  position_x: number;
  position_y: number;
  status: number;
  visible: boolean;
  locked: boolean;
  tag: string | null;
  temporary_name: string | null;
  description: string | null;
  labels: string | null;
  custom_flags: string | null;
  owner_id: string | null;
  owner_type: string | null;
  owner_ticker: string | null;
  linked_sig_eve_id: string | null;
  system_static_info: SystemStaticInfoType;
  system_signatures: SignatureType[];
  comments_count: number;
};

export type SystemStaticInfoType = {
  solar_system_id: number;
  triglavian_invasion_status: string;
  system_class: number;
  security_status: number;
  security_class: string;
  region_name: string;
  constellation_name: string;
  solar_system_name: string;
  class_title: string;
};

export type SignatureType = {
  id: string;
  signature_id: string;
  signature_type: string;
  group: string;
  name: string | null;
  inserted_at: string;
  updated_at: string;
  system_id: string;
  linked_system: string | null;
};

export type OnMapSelectionChange = (event: {
  systems: string[];
  connections: Pick<SolarSystemConnection, 'source' | 'target'>[];
}) => void;

export type OnMapAddSystemCallback = (props: { coordinates: XYPosition | null }) => void;
