import { XYPosition } from 'reactflow';

/**
 * Deterministic client-side placement for newly spawned systems.
 *
 * The server places every spawned system on a square ring around the system
 * its character jumped from (see lib/wanderer_app/map/map_position_calculator.ex:
 * node 130x34 + margins 50x41 -> ring steps of 180x75). Those coordinates never
 * line up with the grid a theme constrains dragging to (Faoble/zoo snaps to
 * 238x51), and second siblings land on far ring corners where they can visually
 * collide once users re-arrange the map.
 *
 * This module detects systems that are still at their server ring position and
 * re-slots them onto the active theme grid: one column to the right of the
 * parent, stacking tightly along y (rows) next to systems already sharing that
 * column, skipping occupied slots. Systems that do not match the ring pattern
 * (pasted systems, manually placed coordinates) are left untouched.
 */

// Ring geometry from map_position_calculator.ex (@w + @m_x, @h + @m_y).
const SERVER_RING_STEP_X = 180;
const SERVER_RING_STEP_Y = 75;
// Max ring level accepted when matching a spawned position, so pathological
// distances (e.g. a paste that happens to be axis-aligned) are not re-placed.
const SERVER_RING_MAX_LEVEL = 8;

// Nominal node size (convertSystem2Node) and the spacing the server itself
// keeps between nodes; reused so auto-placed maps look like the server intends.
const NODE_WIDTH = 130;
const NODE_HEIGHT = 34;
const NODE_GAP_X = 50;
const NODE_GAP_Y = 17;
// Extra breathing room required between node rectangles.
const NODE_PADDING = 4;
// Search bounds: rows checked per column before moving to the next column (the
// "limited" part of the sticky stacking - a column taller than ~11 systems
// spills into the neighbor column), and columns checked each way before giving
// up and keeping the server position.
const MAX_ROW_STEPS = 5;
const MAX_COLUMN_STEPS = 6;

const EPSILON = 1e-6;

export interface AutoPlaceSystem {
  id: string;
  position: XYPosition;
}

export interface AutoPlaceNode {
  id: string;
  position: XYPosition;
  width?: number | null;
  height?: number | null;
}

export interface AutoPlaceSnap {
  x: number;
  y: number;
}

export interface AutoPlaceOptions {
  snap: AutoPlaceSnap;
  layout?: string;
}

interface Rect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

// Never intersects anything: stands in for a reservation that is temporarily
// up for grabs (the owning system is searching for a new slot).
const EMPTY_RECT: Rect = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity };

const isDivisible = (value: number, step: number) =>
  Math.abs(value / step - Math.round(value / step)) < EPSILON;

const snapTo = (value: number, step: number) => Math.round(value / step) * step;

const stepSize = (snap: number, nodeSize: number, gap: number) =>
  snap * Math.max(1, Math.ceil((nodeSize + gap) / snap));

/**
 * True when `position` sits exactly where the server ring calculator puts a
 * spawn relative to `parent` — i.e. this system has not been positioned by a
 * user yet and is safe to auto-place.
 */
export function matchesServerRingPattern(position: XYPosition, parent: XYPosition): boolean {
  const dx = position.x - parent.x;
  const dy = position.y - parent.y;

  if (!isDivisible(dx, SERVER_RING_STEP_X) || !isDivisible(dy, SERVER_RING_STEP_Y)) {
    return false;
  }

  const gx = Math.round(dx / SERVER_RING_STEP_X);
  const gy = Math.round(dy / SERVER_RING_STEP_Y);

  return (gx !== 0 || gy !== 0) && Math.max(Math.abs(gx), Math.abs(gy)) <= SERVER_RING_MAX_LEVEL;
}

/**
 * Finds the closest existing system the spawned one ring-anchors to (its
 * parent). For chain spawns the server anchors on the previous system, whose
 * client position may already have been adjusted — the ring check still
 * resolves to an ancestor, which keeps chains stacking in the same column.
 */
export function findSpawnParent(system: AutoPlaceSystem, nodes: AutoPlaceNode[]): AutoPlaceNode | null {
  let parent: AutoPlaceNode | null = null;
  let parentDistance = Infinity;

  for (const node of nodes) {
    if (`${node.id}` === `${system.id}`) {
      continue;
    }

    if (!matchesServerRingPattern(system.position, node.position)) {
      continue;
    }

    const distance =
      Math.abs(system.position.x - node.position.x) + Math.abs(system.position.y - node.position.y);

    if (distance < parentDistance) {
      parent = node;
      parentDistance = distance;
    }
  }

  return parent;
}

const nodeRect = (position: XYPosition, width?: number | null, height?: number | null): Rect => ({
  left: position.x - NODE_PADDING,
  top: position.y - NODE_PADDING,
  right: position.x + (width ?? NODE_WIDTH) + NODE_PADDING,
  bottom: position.y + (height ?? NODE_HEIGHT) + NODE_PADDING,
});

const intersects = (a: Rect, b: Rect) =>
  a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

/**
 * First free grid slot for a spawn of `parent`: the adjacent column (row, for
 * top-to-bottom maps), with rows searched outward from the parent row so
 * siblings stack tightly and share the column. The parent's own column is
 * never used; further columns fan out only when the adjacent ones are crowded.
 * Returns null when every candidate slot is occupied.
 */
export function computeSpawnSlot(
  parent: AutoPlaceNode,
  occupied: Rect[],
  options: AutoPlaceOptions,
): XYPosition | null {
  const { snap, layout } = options;
  const verticalLayout = layout === 'top_to_bottom';
  const xStep = stepSize(snap.x, NODE_WIDTH, NODE_GAP_X);
  const yStep = stepSize(snap.y, NODE_HEIGHT, NODE_GAP_Y);
  const anchorX = snapTo(parent.position.x, snap.x);
  const anchorY = snapTo(parent.position.y, snap.y);

  const outwardOffsets = (max: number) => {
    const offsets: number[] = [];
    for (let step = 1; step <= max; step++) {
      offsets.push(step, -step);
    }
    return offsets;
  };

  // Offsets along the parent->children axis: adjacent lane first, then farther
  // along the reading direction, mirroring lanes behind the parent only last.
  const primaryOffsets = [
    ...Array.from({ length: MAX_COLUMN_STEPS }, (_, k) => k + 1),
    ...Array.from({ length: MAX_COLUMN_STEPS }, (_, k) => -(k + 1)),
  ];
  // Offsets along the stacking axis: parent row first, expanding both ways.
  const secondaryOffsets = [0, ...outwardOffsets(MAX_ROW_STEPS)];

  for (const primaryOffset of primaryOffsets) {
    const baseX = anchorX + (verticalLayout ? 0 : primaryOffset * xStep);
    const baseY = anchorY + (verticalLayout ? primaryOffset * yStep : 0);

    for (const secondaryOffset of secondaryOffsets) {
      const candidate = verticalLayout
        ? { x: baseX + secondaryOffset * xStep, y: baseY }
        : { x: baseX, y: baseY + secondaryOffset * yStep };

      if (!occupied.some(rect => intersects(nodeRect(candidate), rect))) {
        return candidate;
      }
    }
  }

  return null;
}

/**
 * Reads the active theme's snap grid from its CSS variables, mirroring
 * useBackgroundVars (which only feeds reactflow's drag snapping).
 */
export function readSnapGridFromDom(): AutoPlaceSnap {
  let themeEl = document.querySelector('[class$="-theme"]');

  if (!themeEl) {
    themeEl = document.documentElement;
  }

  const style = getComputedStyle(themeEl as HTMLElement);
  const fallback = style.getPropertyValue('--rf-snap-size');
  const rawX = style.getPropertyValue('--rf-snap-sizeX') || fallback;
  const rawY = style.getPropertyValue('--rf-snap-sizeY') || fallback;

  return { x: parseInt(rawX, 10) || 25, y: parseInt(rawY, 10) || 25 };
}

/**
 * Computes adjusted positions for spawned systems. Returns only the systems
 * whose position actually changes, keyed by id. Batch-safe: earlier placements
 * become obstacles for later ones, and systems are processed in id order so
 * every client computing on the same map state gets the same result.
 */
export function autoPlaceSpawnedSystems(
  systems: AutoPlaceSystem[],
  nodes: AutoPlaceNode[],
  options: AutoPlaceOptions,
): Map<string, XYPosition> {
  const placements = new Map<string, XYPosition>();
  const occupied = nodes.map(node => nodeRect(node.position, node.width, node.height));
  const placed: AutoPlaceNode[] = [];

  const sorted = [...systems].sort((a, b) => Number(a.id) - Number(b.id));

  // Reserve every incoming system's position up front so a spawn never takes
  // the spot of a batch-mate that will not move (no parent found); each
  // reservation is swapped for the system's final position as it is placed.
  const reservations = new Map<string, number>(
    sorted.map((system, index) => [`${system.id}`, nodes.length + index]),
  );
  for (const system of sorted) {
    occupied.push(nodeRect(system.position));
  }

  for (const system of sorted) {
    const parent = findSpawnParent(system, [...nodes, ...placed]);
    const reservedIndex = reservations.get(`${system.id}`);

    if (!parent) {
      placed.push(system);
      continue;
    }

    // The system is free to leave its own reserved spot, so take it out of the
    // collision set while searching; the final position takes its place below.
    if (reservedIndex !== undefined) {
      occupied[reservedIndex] = EMPTY_RECT;
    }

    const slot = computeSpawnSlot(parent, occupied, options);

    // A fully crowded neighborhood keeps the server position rather than
    // stacking the system onto something visible.
    const position = slot ? { ...system.position, ...slot } : system.position;

    if (position.x !== system.position.x || position.y !== system.position.y) {
      placements.set(`${system.id}`, position);
    }

    if (reservedIndex !== undefined) {
      occupied[reservedIndex] = nodeRect(position);
    }

    placed.push({ ...system, position });
  }

  return placements;
}
