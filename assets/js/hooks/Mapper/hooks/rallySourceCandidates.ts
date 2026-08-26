import { CharacterTypeRaw } from '@/hooks/Mapper/types';

export interface RallySourceIds {
  mainEveId: string | null;
  followingEveId: string | null;
}

const findByEveId = (characters: CharacterTypeRaw[], eveId: string | null): CharacterTypeRaw | null => {
  if (eveId == null) {
    return null;
  }

  return characters.find(char => String(char.eve_id) === String(eveId)) ?? null;
};

/**
 * The characters the rally route may be drawn from, best first.
 *
 * The main character leads whenever it is on the map, online, and has a location; the followed
 * character always follows as a fallback, regardless of its online state. Returning an ordered list
 * rather than a single pick is what lets the caller fall through to the followed character when the
 * main character turns out to have no route to the rally point — preferring the main character must
 * never take away a route that would otherwise be drawn.
 *
 * The ids are passed as a named object on purpose: as two positional `string | null` parameters,
 * swapping them would type-check and silently invert the whole feature.
 */
export function rallySourceCandidates(
  characters: CharacterTypeRaw[],
  { mainEveId, followingEveId }: RallySourceIds,
): CharacterTypeRaw[] {
  const mainCharacter = findByEveId(characters, mainEveId);
  const followedCharacter = findByEveId(characters, followingEveId);

  const candidates: CharacterTypeRaw[] = [];

  if (mainCharacter && mainCharacter.online && mainCharacter.location?.solar_system_id) {
    candidates.push(mainCharacter);
  }

  if (followedCharacter && followedCharacter !== mainCharacter) {
    candidates.push(followedCharacter);
  }

  return candidates;
}
