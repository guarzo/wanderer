import React from 'react';
import clsx from 'clsx';
import { DetailedKill } from '@/hooks/Mapper/types/kills';
import { KillRowSubInfo } from './KillRowSubInfo';
import { formatISK, formatTimeMixed, getAttackerSubscript } from '../helpers';
import { buildVictimImageUrls, zkillLink } from '../helpers';
import classes from './SystemKillRow.module.scss';

export interface CompactKillRowProps {
  killDetails: DetailedKill;
  systemName: string;
  onlyOneSystem: boolean;
}

export const CompactKillRow: React.FC<CompactKillRowProps> = ({ killDetails, systemName, onlyOneSystem }) => {
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

  const { victimPortraitUrl, victimShipUrl, victimCorpLogoUrl, victimAllianceLogoUrl } = buildVictimImageUrls({
    victim_char_id,
    victim_ship_type_id,
    victim_corp_id,
    victim_alliance_id,
  });

  const attackerSubscript = getAttackerSubscript(killDetails);

  return (
    <div
      className={clsx(
        'h-10 px-1 py-1',
        'flex items-center border-b border-stone-700',
        'text-xs whitespace-nowrap overflow-hidden',
      )}
    >
      <KillRowSubInfo
        victimCorpId={victim_corp_id}
        victimCorpLogoUrl={victimCorpLogoUrl}
        victimAllianceId={victim_alliance_id}
        victimAllianceLogoUrl={victimAllianceLogoUrl}
        victimCharacterId={victim_char_id}
        victimPortraitUrl={victimPortraitUrl}
      />
      <div className="flex flex-col ml-2 leading-tight min-w-0">
        <span className="whitespace-nowrap overflow-hidden text-ellipsis truncate text-stone-200">
          {victimShipName}
        </span>
        <span className="whitespace-nowrap overflow-hidden text-ellipsis truncate text-stone-400">
          {victimAffiliationTicker}
        </span>
      </div>
      <div className="flex items-center ml-auto gap-2 text-stone-400 text-xs">
        <span>{killTimeAgo}</span>
        <span className="text-stone-600">|</span>

        {!onlyOneSystem && (
          <>
            <span className="text-stone-300">{systemName}</span>
            <span className="text-stone-600">|</span>
          </>
        )}

        <span className="text-red-400 truncate">{attackerAffiliationTicker}</span>

        {killValueFormatted && (
          <>
            <span className="text-stone-600">|</span>
            <span className="text-green-400 truncate">{killValueFormatted}</span>
          </>
        )}
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
