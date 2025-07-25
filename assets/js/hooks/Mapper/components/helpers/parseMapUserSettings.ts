import { MapUserSettings, SettingsWithVersion } from '@/hooks/Mapper/mapRootProvider/types.ts';

const REQUIRED_KEYS = [
  'widgets',
  'interface',
  'onTheMap',
  'routes',
  'localWidget',
  'signaturesWidget',
  'killsWidget',
] as const;

type RequiredKeys = (typeof REQUIRED_KEYS)[number];

/** Custom error for any parsing / validation issue */
export class MapUserSettingsParseError extends Error {
  constructor(msg: string) {
    super(`MapUserSettings parse error: ${msg}`);
  }
}

const isNumber = (v: unknown): v is number => typeof v === 'number' && !Number.isNaN(v);

/** Minimal check that an object matches SettingsWithVersion<*> */
const isSettingsWithVersion = (v: unknown): v is SettingsWithVersion<unknown> =>
  typeof v === 'object' && v !== null && isNumber((v as any).version) && 'settings' in (v as any);

/** Ensure every required key is present */
const hasAllRequiredKeys = (v: unknown): v is Record<RequiredKeys, unknown> =>
  typeof v === 'object' && v !== null && REQUIRED_KEYS.every(k => k in v);

/* ------------------------------ Main parser ------------------------------- */

/**
 * Parses and validates a JSON string as `MapUserSettings`.
 *
 * @throws `MapUserSettingsParseError` – если строка не JSON или нарушена структура
 */
export const parseMapUserSettings = (json: unknown): MapUserSettings => {
  if (typeof json !== 'string') throw new MapUserSettingsParseError('Input must be a JSON string');

  let data: unknown;
  try {
    data = JSON.parse(json);
  } catch (e) {
    throw new MapUserSettingsParseError(`Invalid JSON: ${(e as Error).message}`);
  }

  if (!hasAllRequiredKeys(data)) {
    const missing = REQUIRED_KEYS.filter(k => !(k in (data as any)));
    throw new MapUserSettingsParseError(`Missing top-level field(s): ${missing.join(', ')}`);
  }

  for (const key of REQUIRED_KEYS) {
    if (!isSettingsWithVersion((data as any)[key])) {
      throw new MapUserSettingsParseError(`"${key}" must match SettingsWithVersion<T>`);
    }
  }

  // Everything passes, so cast is safe
  return data as MapUserSettings;
};

/* ------------------------------ Usage example ----------------------------- */

// const raw = fetchFromServer(); // string
// const settings = parseMapUserSettings(raw);
