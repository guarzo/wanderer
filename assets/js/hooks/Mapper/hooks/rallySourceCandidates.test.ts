import { CharacterTypeRaw } from '@/hooks/Mapper/types';
import { rallySourceCandidates } from './rallySourceCandidates';

const character = (over: Partial<CharacterTypeRaw> & { eve_id: string }): CharacterTypeRaw => ({
  name: `Character ${over.eve_id}`,
  online: false,
  location: { solar_system_id: 30000142, structure_id: null, station_id: null },
  ship: null,
  alliance_id: null,
  alliance_name: null,
  alliance_ticker: null,
  corporation_id: 1,
  corporation_name: 'Corp',
  corporation_ticker: 'CORP',
  tracking_paused: false,
  ...over,
});

const main = character({ eve_id: '111', online: true });
const followed = character({ eve_id: '222', online: false });
const onlineFollowed = character({ eve_id: '222', online: true });

const ids = (characters: CharacterTypeRaw[]) => characters.map(char => char.eve_id);

describe('rallySourceCandidates', () => {
  it('puts the main character ahead of the followed character when both are online', () => {
    // The headline behavior: with both online, main must win. Without this case a
    // reversed preference passes every other test in this file.
    expect(ids(rallySourceCandidates([main, onlineFollowed], { mainEveId: '111', followingEveId: '222' }))).toEqual([
      '111',
      '222',
    ]);
  });

  it('offers the followed character as a fallback behind an eligible main', () => {
    expect(ids(rallySourceCandidates([main, followed], { mainEveId: '111', followingEveId: '222' }))).toEqual([
      '111',
      '222',
    ]);
  });

  it('drops an offline main character from the candidates', () => {
    const offlineMain = { ...main, online: false };
    expect(ids(rallySourceCandidates([offlineMain, followed], { mainEveId: '111', followingEveId: '222' }))).toEqual([
      '222',
    ]);
  });

  it('drops a main character that has no location', () => {
    const locationlessMain = { ...main, location: null };
    expect(
      ids(rallySourceCandidates([locationlessMain, followed], { mainEveId: '111', followingEveId: '222' })),
    ).toEqual(['222']);
  });

  it('drops a main character that is not on the map', () => {
    expect(ids(rallySourceCandidates([followed], { mainEveId: '111', followingEveId: '222' }))).toEqual(['222']);
  });

  it('uses the followed character when no main character is set', () => {
    expect(ids(rallySourceCandidates([main, followed], { mainEveId: null, followingEveId: '222' }))).toEqual(['222']);
  });

  it('keeps the followed character even though it is offline', () => {
    expect(ids(rallySourceCandidates([followed], { mainEveId: null, followingEveId: '222' }))).toEqual(['222']);
  });

  it('lists the character only once when the main character is also the followed one', () => {
    expect(ids(rallySourceCandidates([main], { mainEveId: '111', followingEveId: '111' }))).toEqual(['111']);
  });

  it('returns no candidates when neither character is on the map', () => {
    expect(rallySourceCandidates([], { mainEveId: '111', followingEveId: '222' })).toEqual([]);
  });

  it('returns no candidates when no main or followed character is set', () => {
    expect(rallySourceCandidates([main, followed], { mainEveId: null, followingEveId: null })).toEqual([]);
  });

  it('matches ids across string and number representations', () => {
    const numericId = character({ eve_id: 333 as unknown as string, online: true });
    expect(
      ids(rallySourceCandidates([numericId], { mainEveId: 333 as unknown as string, followingEveId: null })),
    ).toEqual([333 as unknown as string]);
  });
});
