import { CharacterTypeRaw, WithIsOwnCharacter } from '@/hooks/Mapper/types';

export type CharItemProps = {
  compact: boolean;
} & CharacterTypeRaw &
  WithIsOwnCharacter;

export type WindowLocalSettingsType = {
  compact: boolean;
  showOffline: boolean;
  version: number;
  showShipName: boolean;
};

export const STORED_DEFAULT_VALUES: WindowLocalSettingsType = {
  compact: true,
  showOffline: false,
  version: 0,
  showShipName: false,
};