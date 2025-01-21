const zkillboardBaseURL = 'https://zkillboard.com';
const baseImageURL = 'https://images.evetech.net';

export function zkillLink(type: 'kill' | 'character' | 'corporation' | 'alliance', id?: number | null): string {
  if (!id) return `${zkillboardBaseURL}`;
  if (type === 'kill') return `${zkillboardBaseURL}/kill/${id}/`;
  if (type === 'character') return `${zkillboardBaseURL}/character/${id}/`;
  if (type === 'corporation') return `${zkillboardBaseURL}/corporation/${id}/`;
  if (type === 'alliance') return `${zkillboardBaseURL}/alliance/${id}/`;
  return `${zkillboardBaseURL}`;
}

export function eveImageUrl(
  category: 'characters' | 'corporations' | 'alliances' | 'types',
  id?: number | null,
  variation: string = 'icon',
  size?: number,
): string | undefined {
  if (!id || id <= 0) {
    return undefined;
  }

  let url = `${baseImageURL}/${category}/${id}/${variation}`;
  if (size) {
    url += `?size=${size}`;
  }
  return url;
}

export function getEveImageUrlOrNull(
  entityType: 'characters' | 'corporations' | 'alliances' | 'types',
  entityId: number | null | undefined,
  variant: string = 'logo',
  size: number = 64,
): string | null {
  if (!entityId) {
    return null;
  }
  return eveImageUrl(entityType, entityId, variant, size) || null;
}

export interface BuildVictimImageUrlsParams {
  victim_char_id?: number | null;
  victim_ship_type_id?: number | null;
  victim_corp_id?: number | null;
  victim_alliance_id?: number | null;
}

export function buildVictimImageUrls({
  victim_char_id,
  victim_ship_type_id,
  victim_corp_id,
  victim_alliance_id,
}: BuildVictimImageUrlsParams) {
  const victimPortraitUrl = victim_char_id ? eveImageUrl('characters', victim_char_id, 'portrait', 64) || null : null;

  const victimShipUrl = victim_ship_type_id ? eveImageUrl('types', victim_ship_type_id, 'render', 64) || null : null;

  const victimCorpLogoUrl = victim_corp_id ? eveImageUrl('corporations', victim_corp_id, 'logo', 32) || null : null;

  const victimAllianceLogoUrl = victim_alliance_id
    ? eveImageUrl('alliances', victim_alliance_id, 'logo', 32) || null
    : null;

  return {
    victimPortraitUrl,
    victimShipUrl,
    victimCorpLogoUrl,
    victimAllianceLogoUrl,
  };
}
