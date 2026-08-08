import { MdOutlineBlock, MdLocalFireDepartment } from 'react-icons/md';
import { FaIndustry, FaHourglassEnd, FaExclamationTriangle, FaSkull } from 'react-icons/fa';

/**
 * Zoo-Specific Label System
 *
 * The zoo fork repurposes upstream's generic labels (A/B/C/1/2/3) with
 * EVE Online wormhole-specific meanings:
 *
 * | Stored key | Enum member | Upstream | Zoo Meaning   | Use Case                           |
 * |------------|-------------|----------|---------------|------------------------------------|
 * | de         | la          | Label A  | Dead End      | System with no exit wormholes      |
 * | gas        | lb          | Label B  | Gas Site      | System has harvestable gas sites   |
 * | eol        | lc          | Label C  | End of Life   | Wormhole about to collapse (<4h)   |
 * | crit       | l1          | Label 1  | Critical Mass | Wormhole at mass verge             |
 * | structure  | l2          | Label 2  | Structure     | System has attackable structure    |
 * | steve      | l3          | Label 3  | Steve/Danger  | High danger (historic: player named Steve) |
 *
 * Note: it is the enum *value* that is persisted, so `system.labels` contains `de`, `gas`,
 * `eol`, `crit`, `structure`, `steve` -- never `la`, `lb`, `lc`. The `la`..`l3` member names
 * exist only to keep the mapping back to upstream legible and never leave the frontend.
 *
 * @see constants.ts for MARKER_BOOKMARK_BG_STYLES using these labels
 * @see zoo-theme.scss for corresponding CSS classes
 */

// Extend the LABELS enum with new wormhole keys
export enum LABELS {
  clear = 'clear',
  la = 'de',
  lb = 'gas',
  lc = 'eol',
  l1 = 'crit',
  l2 = 'structure',
  l3 = 'steve',
}

export type LabelIcon = {
  icon: React.ReactNode;
  colorClass: string;
  backgroundColor: string;
};

export type LabelInfo = {
  id: string;
  name: string;
  shortName: string;
  icon: string;
};

// Additional label info for tooltips or lists, etc.
export const LABELS_INFO: Record<string, LabelInfo> = {
  [LABELS.clear]: { id: 'clear', name: 'Clear', shortName: '', icon: '' },
  [LABELS.la]: { id: 'de', name: 'Dead End', shortName: 'DE', icon: '' },
  [LABELS.lb]: { id: 'gas', name: 'Gas', shortName: 'GAS', icon: '' },
  [LABELS.lc]: { id: 'eol', name: 'Eol', shortName: 'EOL', icon: '' },
  [LABELS.l1]: { id: 'crit', name: 'Crit', shortName: 'CRIT', icon: '' },
  [LABELS.l2]: { id: 'structure', name: 'Structure', shortName: 'LP', icon: '' },
  [LABELS.l3]: { id: 'steve', name: 'Steve', shortName: 'DB', icon: '' },
};

export const LABELS_ORDER = [LABELS.clear, LABELS.la, LABELS.lb, LABELS.lc, LABELS.l1, LABELS.l2, LABELS.l3];

// Mapping each label to its icon, text class, and background color.
export const LABEL_ICON_MAP: Record<string, LabelIcon> = {
  // Dead End: 🚫 "No Entry"
  [LABELS.la]: {
    icon: <MdOutlineBlock size={8} color="#FFFFFF" />,
    colorClass: 'text-white',
    backgroundColor: '#8B0000', // Dark Red
  },
  // Gas Cloud: 🏭 "Harvestable Resource"
  [LABELS.lb]: {
    icon: <FaIndustry size={8} color="#004D40" />, // Dark Cyan
    colorClass: 'text-cyan-900',
    backgroundColor: '#00BFA5', // Greenish-Cyan
  },
  // End of Life (EOL): ⏳ "Fading Time"
  [LABELS.lc]: {
    icon: <FaHourglassEnd size={8} color="#FFFFFF" />, // White hourglass
    colorClass: 'text-white',
    backgroundColor: '#FF4500', // Orange-Red
  },
  // Critically Closing (CRIT): ⚠️ "Danger, Closing Soon"
  [LABELS.l1]: {
    icon: <FaExclamationTriangle size={8} color="#FFFFFF" />,
    colorClass: 'text-white',
    backgroundColor: '#B22222', // Firebrick Red
  },
  // Low Power Structure (🔥 More Contrast)
  [LABELS.l2]: {
    icon: <MdLocalFireDepartment size={8} color="#FFD700" />, // Bright Gold Fire
    colorClass: 'text-yellow-500',
    backgroundColor: '#5D1E1E', // Deep Maroon
  },
  // Death immenient (Steve): 💀 "Danger"
  [LABELS.l3]: {
    icon: <FaSkull size={8} color="#000000" />, // Black Skull
    colorClass: 'text-black',
    backgroundColor: '#FFFFFF', // Pure White Background - should not appear red
  },
};
