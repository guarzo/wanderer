import { SOLAR_SYSTEM_CLASS_IDS } from '@/hooks/Mapper/components/map/constants';

export const isZarzakhSpace = (wormholeClassID: number) => {
  switch (wormholeClassID) {
    case SOLAR_SYSTEM_CLASS_IDS.zarzakh:
      return true;
  }

  return false;
};
