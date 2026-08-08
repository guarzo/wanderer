// useZooTagMenu.ts
import { useCallback, useRef } from 'react';
import { MenuItem } from 'primereact/menuitem';
import { PrimeIcons } from 'primereact/api';
import clsx from 'clsx';
import { SolarSystemRawType } from '@/hooks/Mapper/types';
import { getSystemById } from '@/hooks/Mapper/helpers';
import { GRADIENT_MENU_ACTIVE_CLASSES } from '@/hooks/Mapper/constants';
import { getCustomTagsForTheme, CustomTags } from '@/hooks/Mapper/components/map/helpers/getThemeBehavior';

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
 * Builds a zoo theme tag menu.
 * This menu renders a top-level list of tags based on the zoo theme.
 *
 * @param system - The system object which may have an existing tag.
 * @param onSystemTag - Callback to update the system tag.
 * @param customTags - Custom tag definitions (should come from the zoo theme).
 * @param disabled - Whether the menu and its entries are read-only.
 * @returns A MenuItem representing the zoo theme tag menu.
 */
function buildZooThemeMenu(
  system: SolarSystemRawType | undefined,
  onSystemTag: (val?: string) => void,
  customTags: CustomTags,
  disabled: boolean,
): MenuItem {
  const tag = system?.tag || '';
  const isSelected = isAnyTagSelected(tag);
  const zooTags = customTags.others ?? [];

  return {
    label: 'Occupied',
    icon: PrimeIcons.HASHTAG,
    disabled,
    className: clsx({ [GRADIENT_MENU_ACTIVE_CLASSES]: isSelected }),
    items: [
      // Include a "Clear" option if a tag is already set.
      ...(tag
        ? [
            {
              label: 'Clear',
              icon: PrimeIcons.BAN,
              disabled,
              command: () => onSystemTag(),
            },
          ]
        : []),
      // Build a menu item for each zoo tag.
      ...zooTags.map(zooTag => ({
        label: zooTag,
        icon: PrimeIcons.TAG,
        disabled,
        command: () => onSystemTag(zooTag),
        className: clsx({ [GRADIENT_MENU_ACTIVE_CLASSES]: tag === zooTag }),
      })),
    ],
  };
}

/**
 * Custom hook to generate a tag menu for a given system that always uses zoo theme settings.
 *
 * @param systems - Array of available systems.
 * @param systemId - ID of the current system.
 * @param onSystemTag - Callback to update the system tag.
 * @param disabled - Whether the menu and its entries are read-only.
 * @returns A memoized function that returns a MenuItem for the zoo theme.
 */
export const useZooTagMenu = (
  systems: SolarSystemRawType[],
  systemId: string | undefined,
  onSystemTag: (val?: string) => void,
  disabled = false,
): (() => MenuItem) => {
  // Keep the latest values in a ref to avoid extra dependencies.
  const ref = useRef({ onSystemTag, systems, systemId, disabled });
  ref.current = { onSystemTag, systems, systemId, disabled };

  // Always use the zoo theme's custom tags.
  const customTags: CustomTags = getCustomTagsForTheme('zoo');

  return useCallback(() => {
    const { systems, systemId, onSystemTag, disabled } = ref.current;
    const system = systemId ? getSystemById(systems, systemId) : undefined;
    return buildZooThemeMenu(system, onSystemTag, customTags, disabled);
  }, [customTags]);
};
