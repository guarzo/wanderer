import { SOLAR_SYSTEM_CLASS_IDS } from '@/hooks/Mapper/components/map/constants.ts';

export const JUMP_PLANNER_SPACE = [SOLAR_SYSTEM_CLASS_IDS.hs, SOLAR_SYSTEM_CLASS_IDS.ls, SOLAR_SYSTEM_CLASS_IDS.ns];

export enum JumpPlannerField {
  From = 'from',
  Destination = 'destination',
}
