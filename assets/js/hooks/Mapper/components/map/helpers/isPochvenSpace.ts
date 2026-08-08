import { SOLAR_SYSTEM_CLASS_IDS } from '@/hooks/Mapper/components/map/constants';

export const isPochvenSpace = (wormholeClassID: number) => {
  switch (wormholeClassID) {
    case SOLAR_SYSTEM_CLASS_IDS.pochven:
      return true;
  }

  return false;
};
