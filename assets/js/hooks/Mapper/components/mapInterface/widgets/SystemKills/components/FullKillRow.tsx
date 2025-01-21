import React from 'react';
import clsx from 'clsx';
import { DetailedKill } from '@/hooks/Mapper/types/kills';
import { KillRowSubInfo } from './KillRowSubInfo';
import { formatISK, formatTimeMixed, getAttackerSubscript } from '../helpers';
import { eveImageUrl, zkillLink } from '../helpers';
import classes from './SystemKillRow.module.scss';

export interface FullKillRowProps {
  killDetails: DetailedKill;
  systemName: string;
  onlyOneSystem: boolean;
}

export const FullKillRow: React.FC<FullKillRowProps> = ({ killDetails, systemName, onlyOneSystem }) => {
  const {
    killmail_id: killMailId,
    victim_ship_name: victimShipName = 'Unknown Ship',
    victim_alliance_ticker,
    victim_corp_ticker,
    final_blow_alliance_ticker,
    final_blow_corp_ticker,
    kill_time,
    total_value,
    victim_char_id,
    victim_corp_id,
    victim_alliance_id,
    victim_ship_type_id,
  } = killDetails;

  const victimAffiliationTicker = victim_alliance_ticker || victim_corp_ticker || 'No Ticker';
  const attackerAffiliationTicker = final_blow_alliance_ticker || final_blow_corp_ticker || 'No Ticker';
  const killTimeAgo = kill_time ? formatTimeMixed(kill_time) : '0h ago';
  const killValueFormatted = total_value && total_value > 0 ? `${formatISK(total_value)} ISK` : null;

  const victimPortraitUrl = victim_char_id ? eveImageUrl('characters', victim_char_id, 'portrait', 64) || null : null;
  const victimShipUrl = victim_ship_type_id ? eveImageUrl('types', victim_ship_type_id, 'render', 64) || null : null;
  const victimCorpLogoUrl = victim_corp_id ? eveImageUrl('corporations', victim_corp_id, 'logo', 32) || null : null;
  const victimAllianceLogoUrl = victim_alliance_id
    ? eveImageUrl('alliances', victim_alliance_id, 'logo', 32) || null
    : null;

  const attackerSubscript = getAttackerSubscript(killDetails);

  return (
    <div
      className={clsx('h-16 px-1 py-1', 'flex border-b border-stone-700', 'text-sm whitespace-nowrap overflow-hidden')}
    >
      <KillRowSubInfo
        victimCorpId={victim_corp_id}
        victimCorpLogoUrl={victimCorpLogoUrl}
        victimAllianceId={victim_alliance_id}
        victimAllianceLogoUrl={victimAllianceLogoUrl}
        victimCharacterId={victim_char_id}
        victimPortraitUrl={victimPortraitUrl}
      />
      <div className="flex flex-col ml-3 min-w-0 overflow-hidden gap-1">
        <div className="flex items-center gap-2 min-w-0 overflow-hidden">
          <span className="truncate text-stone-200 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">
            {victimShipName}
          </span>
          <span className="text-stone-500">|</span>
          <span className="truncate text-stone-400 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">
            {victimAffiliationTicker}
          </span>
        </div>
        <span className="text-stone-400 truncate">{killTimeAgo}</span>
      </div>

      <div className="flex ml-auto items-center min-w-0 overflow-hidden h-full">
        <div className="flex flex-col items-end justify-center min-w-0 overflow-hidden mr-3">
          {!onlyOneSystem && <span className="text-stone-300 text-sm truncate">{systemName}</span>}
          {killValueFormatted && <span className="text-green-400 text-xs truncate">{killValueFormatted}</span>}
          <span className="text-stone-300 text-sm truncate">{attackerAffiliationTicker}</span>
        </div>
        {victimShipUrl && (
          <a
            href={zkillLink('kill', killMailId)}
            target="_blank"
            rel="noopener noreferrer"
            className="relative shrink-0 h-full"
          >
            <img
              src={victimShipUrl}
              alt="VictimShip"
              className={clsx(classes.shipImage, 'border border-stone-600 rounded-none h-full w-auto object-contain')}
            />
            {attackerSubscript && (
              <span className={clsx(classes.attackerCountLabel, attackerSubscript.cssClass)}>
                {attackerSubscript.label}
              </span>
            )}
          </a>
        )}
      </div>
    </div>
  );
};
