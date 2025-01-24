import { MenuItem } from 'primereact/menuitem';
import { PrimeIcons } from 'primereact/api';
import { useCallback, useRef } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { SolarSystemRawType } from '@/hooks/Mapper/types';
import { getSystemById } from '@/hooks/Mapper/helpers';
import clsx from 'clsx';
import { GRADIENT_MENU_ACTIVE_CLASSES } from '@/hooks/Mapper/constants.ts';

const AVAILABLE_LETTERS = ['A', 'B', 'C', 'D', 'E', 'F', 'X', 'Y', 'Z'];
const AVAILABLE_NUMBERS = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
const AVAILABLE_ZOOTAGS = ['1', '2', '3', '4', '5', '6', '7', '8', '10+', '20+', 'Baiting'];

/**
 * A small helper that checks if the system tag is included in any
 * of our known arrays (letters, numbers, zoo, etc.)
 */
function isAnyTagSelected(systemTag?: string) {
  if (!systemTag) return false;
  return (
    AVAILABLE_LETTERS.includes(systemTag) ||
    AVAILABLE_NUMBERS.includes(systemTag) ||
    AVAILABLE_ZOOTAGS.includes(systemTag) ||
    systemTag === 'Occupied'
  );
}

/**
 * -----------
 * THEME BUILDERS
 * -----------
 * Each theme's function returns the full "Tag" menu item. If a theme
 * wants to reuse or modify the default structure, it can do so.
 */
const buildDefaultThemeMenu = (
  system: SolarSystemRawType | undefined,
  onSystemTag: (val?: string) => void,
): MenuItem => {
  const tag = system?.tag;
  const isSelected = isAnyTagSelected(tag);

  const isSelectedLetters = AVAILABLE_LETTERS.includes(tag ?? '');
  const isSelectedNumbers = AVAILABLE_NUMBERS.includes(tag ?? '');

  // Top-level
  const menuItem: MenuItem = {
    label: 'Tag',
    icon: PrimeIcons.HASHTAG,
    className: clsx({ [GRADIENT_MENU_ACTIVE_CLASSES]: isSelected }),
    items: [
      // "Clear" if there's already a tag set
      ...(tag
        ? [
            {
              label: 'Clear',
              icon: PrimeIcons.BAN,
              command: () => onSystemTag(),
            },
          ]
        : []),

      {
        label: 'Letter',
        icon: PrimeIcons.TAGS,
        className: clsx({
          [GRADIENT_MENU_ACTIVE_CLASSES]: isSelectedLetters,
        }),
        items: AVAILABLE_LETTERS.map(letter => ({
          label: letter,
          icon: PrimeIcons.TAG,
          command: () => onSystemTag(letter),
          className: clsx({
            [GRADIENT_MENU_ACTIVE_CLASSES]: tag === letter,
          }),
        })),
      },
      {
        label: 'Digit',
        icon: PrimeIcons.TAGS,
        className: clsx({
          [GRADIENT_MENU_ACTIVE_CLASSES]: isSelectedNumbers,
        }),
        items: AVAILABLE_NUMBERS.map(digit => ({
          label: digit,
          icon: PrimeIcons.TAG,
          command: () => onSystemTag(digit),
          className: clsx({
            [GRADIENT_MENU_ACTIVE_CLASSES]: tag === digit,
          }),
        })),
      },
    ],
  };

  return menuItem;
};

const buildZooThemeMenu = (system: SolarSystemRawType | undefined, onSystemTag: (val?: string) => void): MenuItem => {
  const tag = system?.tag;
  const isSelected = isAnyTagSelected(tag);

  return {
    label: 'Occupied',
    icon: PrimeIcons.HASHTAG,
    className: clsx({ [GRADIENT_MENU_ACTIVE_CLASSES]: isSelected }),
    items: [
      // If there's already a tag, show "Clear"
      ...(tag
        ? [
            {
              label: 'Clear',
              icon: PrimeIcons.BAN,
              command: () => onSystemTag(),
            },
          ]
        : []),
      // Each zoo tag at the top level (rather than a sub-menu)
      ...AVAILABLE_ZOOTAGS.map(zooTag => ({
        label: zooTag,
        icon: PrimeIcons.TAG,
        command: () => onSystemTag(zooTag),
        className: clsx({
          [GRADIENT_MENU_ACTIVE_CLASSES]: tag === zooTag,
        }),
      })),
    ],
  };
};

const THEME_MENU_BUILDERS: Record<
  string,
  (system: SolarSystemRawType | undefined, onSystemTag: (val?: string) => void) => MenuItem
> = {
  default: buildDefaultThemeMenu,
  zoo: buildZooThemeMenu,
};

export const useTagMenu = (
  systems: SolarSystemRawType[],
  systemId: string | undefined,
  onSystemTag: (val?: string) => void,
): (() => MenuItem) => {
  const ref = useRef({ onSystemTag, systems, systemId });
  ref.current = { onSystemTag, systems, systemId };

  const { interfaceSettings } = useMapRootState();
  const themeClass = interfaceSettings.theme ?? 'default';

  return useCallback(() => {
    const { systems, systemId, onSystemTag } = ref.current;
    const system = systemId ? getSystemById(systems, systemId) : undefined;

    // Find a builder for the current theme, or fallback to 'default'
    const builder = THEME_MENU_BUILDERS[themeClass] || THEME_MENU_BUILDERS.default;

    // Build the full MenuItem
    const menuItem = builder(system, onSystemTag);
    return menuItem;
  }, [themeClass]);
};
