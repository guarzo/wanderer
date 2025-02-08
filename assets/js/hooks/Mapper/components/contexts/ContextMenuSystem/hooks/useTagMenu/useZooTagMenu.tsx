import { MenuItem } from 'primereact/menuitem';
import { PrimeIcons } from 'primereact/api';
import { useCallback, useRef } from 'react';
import { SolarSystemRawType } from '@/hooks/Mapper/types';
import { getSystemById } from '@/hooks/Mapper/helpers';
import clsx from 'clsx';
import { GRADIENT_MENU_ACTIVE_CLASSES } from '@/hooks/Mapper/constants';
import { getCustomTagsForTheme, CustomTags } from '@/hooks/Mapper/components/map/helpers/getThemeBehavior';
import { LayoutEventBlocker } from '@/hooks/Mapper/components/ui-kit';
import { Button } from 'primereact/button';

/**
 * Helper to determine if any tag is selected.
 *
 * @param systemTag - The tag string.
 * @returns True if the tag is truthy.
 */
function isAnyTagSelected(systemTag?: string): boolean {
  return Boolean(systemTag);
}

/**
 * Custom hook to generate a tag menu for a given system that always uses zoo theme settings.
 *
 * @param systems - Array of available systems.
 * @param systemId - ID of the current system.
 * @param onSystemTag - Callback to update the system tag.
 * @returns A memoized function that returns a MenuItem for the zoo theme.
 */
export const useZooTagMenu = (
  systems: SolarSystemRawType[],
  systemId: string | undefined,
  onSystemTag: (val?: string) => void,
): (() => MenuItem) => {
  // Keep the latest values in a ref to avoid extra dependencies.
  const ref = useRef({ onSystemTag, systems, systemId });
  ref.current = { onSystemTag, systems, systemId };

  // Always use the zoo theme's custom tags.
  const customTags: CustomTags = getCustomTagsForTheme('zoo');

  return useCallback(() => {
    const { systems, systemId, onSystemTag } = ref.current;
    const system = systemId ? getSystemById(systems, systemId) : undefined;
    const tag = system?.tag || '';
    const isSelected = isAnyTagSelected(tag);
    const zooTags = customTags.others ?? [];

    const menuItem: MenuItem = {
      label: 'Occupied',
      icon: PrimeIcons.HASHTAG,
      className: clsx({ [GRADIENT_MENU_ACTIVE_CLASSES]: isSelected }),
      items: [
        {
          label: 'Zoo Tags',
          icon: PrimeIcons.TAGS,
          className: '!h-[128px] suppress-menu-behaviour',
          template: () => (
            <LayoutEventBlocker className="flex flex-col gap-1 w-[200px] h-full px-2">
              <div className="grid grid-cols-3 gap-1">
                {zooTags.map(zooTag => (
                  <Button
                    outlined={tag !== zooTag}
                    severity="warning"
                    key={zooTag}
                    value={zooTag}
                    size="small"
                    className="p-[3px] justify-center"
                    onClick={() => tag !== zooTag && onSystemTag(zooTag)}
                  >
                    {zooTag}
                  </Button>
                ))}
                <Button
                  disabled={!isSelected}
                  icon="pi pi-ban"
                  size="small"
                  className="!p-0 !w-[initial] justify-center"
                  outlined
                  severity="help"
                  onClick={() => onSystemTag()}
                />
              </div>
            </LayoutEventBlocker>
          ),
        },
      ],
    };

    return menuItem;
  }, [customTags]);
};
