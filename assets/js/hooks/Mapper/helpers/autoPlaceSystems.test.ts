import {
  autoPlaceSpawnedSystems,
  matchesServerRingPattern,
} from './autoPlaceSystems.ts';

// Faoble (zoo) theme grid. Columns are 238 apart, rows 51.
const ZOO_SNAP = { x: 238, y: 51 };

const node = (id: string, x: number, y: number) => ({ id, position: { x, y } });

// Where the server ring calculator (180x75 steps) puts a spawn of `parent`.
const spawnOf = (parent: { x: number; y: number }, dx = 180, dy = 75, id = '9001') => ({
  id,
  position: { x: parent.x + dx, y: parent.y + dy },
});

describe('matchesServerRingPattern', () => {
  const parent = { x: 476, y: 153 };

  it('recognizes a level-one server ring spawn', () => {
    expect(matchesServerRingPattern({ x: parent.x + 180, y: parent.y + 75 }, parent)).toBe(true);
  });

  it('recognizes farther ring levels in any direction', () => {
    expect(matchesServerRingPattern({ x: parent.x + 360, y: parent.y - 75 }, parent)).toBe(true);
    expect(matchesServerRingPattern({ x: parent.x - 180, y: parent.y - 150 }, parent)).toBe(true);
  });

  it('rejects positions the server would not have picked', () => {
    expect(matchesServerRingPattern({ x: parent.x + 181, y: parent.y + 75 }, parent)).toBe(false);
    expect(matchesServerRingPattern({ x: parent.x + 137, y: parent.y + 42 }, parent)).toBe(false);
  });

  it('rejects the parent position itself', () => {
    expect(matchesServerRingPattern(parent, parent)).toBe(false);
  });
});

describe('autoPlaceSpawnedSystems', () => {
  it('re-slots a spawned system onto the theme grid next to its parent', () => {
    const parent = node('1', 476, 153);
    const spawned = spawnOf(parent.position);

    const placements = autoPlaceSpawnedSystems([spawned], [parent], { snap: ZOO_SNAP });

    expect(placements.get('9001')).toEqual({ x: 714, y: 153 });
  });

  it('leaves systems that are not at a server ring position untouched', () => {
    const parent = node('1', 476, 153);
    const pasted = { id: '9001', position: { x: 1234, y: 567 } };

    expect(autoPlaceSpawnedSystems([pasted], [parent], { snap: ZOO_SNAP })).toEqual(new Map());
  });

  it('stacks a second sibling below the first in the shared column', () => {
    const parent = node('1', 476, 153);
    const firstChild = node('2', 714, 153);
    const spawned = spawnOf(parent.position, 180, 75, '3');

    const placements = autoPlaceSpawnedSystems([spawned], [parent, firstChild], { snap: ZOO_SNAP });

    expect(placements.get('3')).toEqual({ x: 714, y: 204 });
  });

  it('skips rows occupied by unrelated systems and stacks upward when boxed in', () => {
    const parent = node('1', 476, 153);
    // Both rows below the parent row in the children column are taken.
    const blockers = [node('2', 714, 153), node('3', 714, 204)];
    const spawned = spawnOf(parent.position, 180, 75, '4');

    const placements = autoPlaceSpawnedSystems([spawned], [parent, ...blockers], { snap: ZOO_SNAP });

    expect(placements.get('4')).toEqual({ x: 714, y: 102 });
  });

  it('fans out to the next column when the adjacent one is full', () => {
    const parent = node('1', 476, 153);
    // Every row of the children column within the stacking limit is taken.
    const rowOffsets = [0, ...Array.from({ length: 5 }, (_, k) => [k + 1, -(k + 1)]).flat()];
    const blockers = rowOffsets.map((offset, index) => node(`2${index}`, 714, 153 + offset * 51));
    const spawned = spawnOf(parent.position, 180, 75, '5');

    const placements = autoPlaceSpawnedSystems([spawned], [parent, ...blockers], { snap: ZOO_SNAP });

    expect(placements.get('5')).toEqual({ x: 952, y: 153 });
  });

  it('resolves chained spawns to the ancestor column so chains stack in one column', () => {
    const a = node('1', 476, 153);
    // B was already placed into the adjacent column by an earlier batch while
    // the server still has B at its ring position...
    const bPlaced = node('2', 714, 153);
    const bServer = { x: 656, y: 228 };
    // ...so C arrived anchored on B's server position.
    const cSpawned = spawnOf(bServer, 180, 75, '3');

    const placements = autoPlaceSpawnedSystems([cSpawned], [a, bPlaced], { snap: ZOO_SNAP });

    expect(placements.get('3')).toEqual({ x: 714, y: 204 });
  });

  it('places batch systems without overlapping each other, in id order', () => {
    const parent = node('100', 476, 153);
    const second = spawnOf(parent.position, 180, 75, '2');
    const first = spawnOf(parent.position, 180, -75, '1');

    const placements = autoPlaceSpawnedSystems([second, first], [parent], { snap: ZOO_SNAP });

    expect(placements.get('1')).toEqual({ x: 714, y: 153 });
    expect(placements.get('2')).toEqual({ x: 714, y: 204 });
  });

  it('snaps children of off-grid parents to the absolute theme grid', () => {
    // A system dragged before snapping was enforced can sit off-lattice; its
    // spawns still land on the shared grid.
    const parent = node('1', 500, 180);
    const spawned = spawnOf(parent.position);

    const placements = autoPlaceSpawnedSystems([spawned], [parent], { snap: ZOO_SNAP });

    expect(placements.get('9001')).toEqual({ x: 714, y: 204 });
  });

  it('keeps the server position when the whole searchable neighborhood is crowded', () => {
    const parent = node('1', 476, 153);
    const walls: ReturnType<typeof node>[] = [];

    // Wall off every column and row the slot search may try.
    for (let column = 1; column <= 6; column++) {
      for (const sign of [1, -1]) {
        const x = 476 + sign * column * 238;
        for (let row = -5; row <= 5; row++) {
          walls.push(node(`w_${x}_${row}`, x, 153 + row * 51));
        }
      }
    }

    const spawned = spawnOf(parent.position, 180, 75, '9');

    expect(autoPlaceSpawnedSystems([spawned], [parent, ...walls], { snap: ZOO_SNAP })).toEqual(new Map());
  });

  it('places below the parent for top-to-bottom maps', () => {
    const parent = node('1', 476, 153);
    const spawned = spawnOf(parent.position);

    const placements = autoPlaceSpawnedSystems([spawned], [parent], {
      snap: ZOO_SNAP,
      layout: 'top_to_bottom',
    });

    expect(placements.get('9001')).toEqual({ x: 476, y: 204 });
  });

  it('keeps default-theme slots clear of node rectangles at small grid sizes', () => {
    const parent = node('1', 100, 100);
    const spawned = spawnOf(parent.position);

    const placements = autoPlaceSpawnedSystems([spawned], [parent], { snap: { x: 25, y: 25 } });

    expect(placements.get('9001')).toEqual({ x: 300, y: 100 });
  });

  it('keeps the server position when the whole searchable neighborhood is crowded', () => {
    const parent = node('1', 476, 153);
    const walls: ReturnType<typeof node>[] = [];

    // Wall off every column and row the slot search may try.
    for (let column = 1; column <= 6; column++) {
      for (const sign of [1, -1]) {
        const x = 476 + sign * column * 238;
        for (let row = -12; row <= 12; row++) {
          walls.push(node(`w_${x}_${row}`, x, 153 + row * 51));
        }
      }
    }

    const spawned = spawnOf(parent.position, 180, 75, '9');

    expect(autoPlaceSpawnedSystems([spawned], [parent, ...walls], { snap: ZOO_SNAP })).toEqual(new Map());
  });
});
