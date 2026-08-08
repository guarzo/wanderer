/**
 * Zoo-Specific Constants
 *
 * This file contains zoo fork-specific constants that extend the upstream
 * Wanderer constants. Keeping them separate reduces merge conflict risk
 * when rebasing on upstream changes.
 *
 * @see constants.ts for how these are merged with upstream constants
 * @see zoo-theme.scss for corresponding CSS classes
 */

import { ConnectionType } from '../../types/connection';

/**
 * Zoo-specific connection types extending the upstream ConnectionType enum.
 *
 * Note: The `loop` connection type is already included in the upstream
 * ConnectionType enum (connection.ts), so we just re-export for clarity.
 */
export const ZOO_CONNECTION_TYPES = {
  ...ConnectionType,
  // loop is already in ConnectionType, but documented here for zoo-specific usage:
  // loop: 3 - Used for marking connections that loop back (self-referential chains)
};

/**
 * Zoo-specific bookmark/label background styles.
 *
 * These styles map to CSS classes defined in zoo-theme.scss.
 * They represent EVE Online wormhole-specific visual states:
 *
 * | Key            | CSS Class                          | Purpose                    |
 * |----------------|------------------------------------|-----------------------------|
 * | gas            | eve-zoo-effect-color-has-gas       | System has gas sites        |
 * | eol            | eve-zoo-effect-color-has-eol       | Wormhole is End of Life     |
 * | deadEnd        | eve-zoo-effect-color-is-dead-end   | Dead end system             |
 * | crit           | eve-zoo-effect-color-is-critical   | Wormhole at critical mass   |
 * | unSplashed     | eve-zoo-effect-color-unsplashed    | System not yet scouted      |
 * | de             | eve-zoo-effect-color-is-dead-end   | Alias for deadEnd           |
 * | wormhole       | eve-zoo-effect-color-wormhole      | Generic wormhole marker     |
 * | flygd          | eve-zoo-effect-color-flygd         | Flygd marker style          |
 * | wormholeMagic  | eve-zoo-effect-color-wormhole-magic    | Special wormhole variant |
 * | wormholeInfinity | eve-zoo-effect-color-wormhole-infinity | Infinity chain marker  |
 * | wormholePlanet | eve-zoo-effect-color-wormhole-planet   | Planet-related marker    |
 * | wormholeLoop   | eve-zoo-effect-color-wormhole-loop     | Loop connection marker   |
 */
export const ZOO_BOOKMARK_STYLES = {
  gas: 'eve-zoo-effect-color-has-gas',
  eol: 'eve-zoo-effect-color-has-eol',
  deadEnd: 'eve-zoo-effect-color-is-dead-end',
  crit: 'eve-zoo-effect-color-is-critical',
  unSplashed: 'eve-zoo-effect-color-unsplashed',
  de: 'eve-zoo-effect-color-is-dead-end',
  wormhole: 'eve-zoo-effect-color-wormhole',
  flygd: 'eve-zoo-effect-color-flygd',
  wormholeMagic: 'eve-zoo-effect-color-wormhole-magic',
  wormholeInfinity: 'eve-zoo-effect-color-wormhole-infinity',
  wormholePlanet: 'eve-zoo-effect-color-wormhole-planet',
  wormholeLoop: 'eve-zoo-effect-color-wormhole-loop',
} as const;

/**
 * Zoo-specific text color styles for labels.
 * These correspond to the background styles but for text coloring.
 */
export const ZOO_TEXT_STYLES = {
  gas: 'text-eve-zoo-effect-color-has-gas',
  eol: 'text-eve-zoo-effect-color-has-eol',
  deadEnd: 'text-eve-zoo-effect-color-is-dead-end',
  crit: 'text-eve-zoo-effect-color-is-critical',
  unSplashed: 'text-eve-zoo-effect-color-unsplashed',
  wormholeMagic: 'text-eve-zoo-effect-color-wormhole-magic',
  wormholeInfinity: 'text-eve-zoo-effect-color-wormhole-infinity',
  wormholePlanet: 'text-eve-zoo-effect-color-wormhole-planet',
  wormholeLoop: 'text-eve-zoo-effect-color-wormhole-loop',
} as const;

export type ZooBookmarkStyleKey = keyof typeof ZOO_BOOKMARK_STYLES;
export type ZooTextStyleKey = keyof typeof ZOO_TEXT_STYLES;
