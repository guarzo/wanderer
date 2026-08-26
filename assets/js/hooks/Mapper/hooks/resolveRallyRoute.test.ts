import { CharacterTypeRaw, PingType, SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { PingData } from '@/hooks/Mapper/types/ping';
import { resolveRallyRoute } from './resolveRallyRoute';

const character = (over: Partial<CharacterTypeRaw> & { eve_id: string; solar_system_id: number }): CharacterTypeRaw =>
  ({
    name: `Character ${over.eve_id}`,
    online: false,
    ship: null,
    tracking_paused: false,
    ...over,
    location: { solar_system_id: over.solar_system_id, structure_id: null, station_id: null },
  }) as CharacterTypeRaw;

const system = (id: string) => ({ id }) as SolarSystemRawType;
const connection = (source: string, target: string) => ({ source, target }) as SolarSystemConnection;

const rallyPing = (solarSystemId: string) =>
  ({ id: 'ping-1', solar_system_id: solarSystemId, type: PingType.Rally }) as PingData;

// A three-system chain, plus an island the chain cannot reach.
const SYSTEMS = [system('30000001'), system('30000002'), system('30000003'), system('30002187')];
const CONNECTIONS = [connection('30000001', '30000002'), connection('30000002', '30000003')];

const RALLY = '30000003';

const resolve = (
  characters: CharacterTypeRaw[],
  mainCharacterEveId: string | null,
  followingCharacterEveId: string | null,
) =>
  resolveRallyRoute({
    characters,
    mainCharacterEveId,
    followingCharacterEveId,
    pings: [rallyPing(RALLY)],
    systems: SYSTEMS,
    connections: CONNECTIONS,
  });

describe('resolveRallyRoute', () => {
  it('draws the route from the main character when it is online and can reach the rally point', () => {
    const main = character({ eve_id: '111', online: true, solar_system_id: 30000001 });
    const followed = character({ eve_id: '222', online: true, solar_system_id: 30000002 });

    const result = resolve([main, followed], '111', '222');

    expect(result.isActive).toBe(true);
    expect(result.sourceCharacterSystemId).toBe('30000001');
    expect([...result.highlightedSystems]).toEqual(['30000001', '30000002', '30000003']);
  });

  it('falls back to the followed character when the main character cannot reach the rally point', () => {
    // The regression the fallback exists to prevent: main is online and located, but parked on an
    // island with no mapped path to the rally, while the followed character is two jumps away.
    const strandedMain = character({ eve_id: '111', online: true, solar_system_id: 30002187 });
    const followed = character({ eve_id: '222', online: true, solar_system_id: 30000001 });

    const result = resolve([strandedMain, followed], '111', '222');

    expect(result.isActive).toBe(true);
    expect(result.sourceCharacterSystemId).toBe('30000001');
    expect([...result.highlightedSystems]).toEqual(['30000001', '30000002', '30000003']);
  });

  it('reports no route when neither character can reach the rally point', () => {
    const strandedMain = character({ eve_id: '111', online: true, solar_system_id: 30002187 });
    const strandedFollowed = character({ eve_id: '222', online: true, solar_system_id: 30002187 });

    const result = resolve([strandedMain, strandedFollowed], '111', '222');

    expect(result.isActive).toBe(false);
    expect(result.highlightedSystems.size).toBe(0);
    expect(result.rallySystemId).toBe(RALLY);
  });

  it('highlights only the rally system when the source character is already there', () => {
    const main = character({ eve_id: '111', online: true, solar_system_id: 30000003 });

    const result = resolve([main], '111', null);

    expect(result.isActive).toBe(true);
    expect([...result.highlightedSystems]).toEqual([RALLY]);
    expect(result.highlightedConnections.size).toBe(0);
  });

  it('highlights the connections along the route', () => {
    const main = character({ eve_id: '111', online: true, solar_system_id: 30000001 });

    const result = resolve([main], '111', null);

    expect([...result.highlightedConnections].sort()).toEqual(['30000001-30000002', '30000002-30000003']);
  });

  it('is inactive when there is no rally ping', () => {
    const main = character({ eve_id: '111', online: true, solar_system_id: 30000001 });

    const result = resolveRallyRoute({
      characters: [main],
      mainCharacterEveId: '111',
      followingCharacterEveId: null,
      pings: [],
      systems: SYSTEMS,
      connections: CONNECTIONS,
    });

    expect(result.isActive).toBe(false);
    expect(result.rallySystemId).toBeNull();
  });

  it('is inactive when no character is available to route from', () => {
    const result = resolve([], null, null);

    expect(result.isActive).toBe(false);
    expect(result.sourceCharacterSystemId).toBeNull();
    expect(result.rallySystemId).toBe(RALLY);
  });
});
