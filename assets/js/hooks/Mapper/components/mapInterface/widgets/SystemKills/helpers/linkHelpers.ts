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
