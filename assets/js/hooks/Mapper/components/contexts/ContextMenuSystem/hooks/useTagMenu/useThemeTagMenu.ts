import { useTheme } from '@/hooks/Mapper/hooks/useTheme';
import { AvailableThemes } from '@/hooks/Mapper/mapRootProvider/types';
import { useTagMenu } from './useTagMenu';
import { useZooTagMenu } from './useZooTagMenu';
import type { SolarSystemRawType } from '@/hooks/Mapper/types';
import type { MenuItem } from 'primereact/menuitem';

export const useThemeTagMenu = (
  systems: SolarSystemRawType[],
  systemId: string | undefined,
  onSystemTag: (val?: string) => void,
): (() => MenuItem) => {
  const theme = useTheme();

  const zooTags = useZooTagMenu(systems, systemId, onSystemTag);
  const defaultTags = useTagMenu(systems, systemId, onSystemTag);

  return theme === AvailableThemes.zoo ? zooTags : defaultTags;
};
