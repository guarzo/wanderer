import { SolarSystemNodeDefault, SolarSystemNodeTheme, SolarSystemNodeZoo } from '../components/SolarSystemNode';
import type { NodeProps } from 'reactflow';
import type { ComponentType } from 'react';
import { MapSolarSystemType } from '../map.types';
import { ConnectionMode } from 'reactflow';

export type SolarSystemNodeComponent = ComponentType<NodeProps<MapSolarSystemType>>;

export interface CustomTags {
  letters?: string[];
  digits?: string[];
  others?: string[];
}

interface ThemeBehavior {
  isPanAndDrag: boolean;
  nodeComponent: SolarSystemNodeComponent;
  connectionMode: ConnectionMode;
  customTags?: CustomTags;
}

const THEME_BEHAVIORS: { [key: string]: ThemeBehavior } = {
  default: {
    isPanAndDrag: false,
    nodeComponent: SolarSystemNodeDefault,
    connectionMode: ConnectionMode.Loose,
    customTags: {
      letters: ['A', 'B', 'C', 'D', 'E', 'F', 'X', 'Y', 'Z'],
      digits: ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'],
    },
  },
  pathfinder: {
    isPanAndDrag: true,
    nodeComponent: SolarSystemNodeTheme,
    connectionMode: ConnectionMode.Loose,
  },
  zoo: {
    isPanAndDrag: true,
    nodeComponent: SolarSystemNodeZoo,
    connectionMode: ConnectionMode.Strict,
    customTags: {
      others: ['1', '2', '3', '4', '5', '6', '7', '8', '10+', '20+', 'Baiting'],
    },
  },
};


export function getBehaviorForTheme(themeName: string): ThemeBehavior {
  return THEME_BEHAVIORS[themeName] ?? THEME_BEHAVIORS.default;
}

export function getCustomTagsForTheme(themeName: string): CustomTags {
  return getBehaviorForTheme(themeName).customTags ?? {};
}
