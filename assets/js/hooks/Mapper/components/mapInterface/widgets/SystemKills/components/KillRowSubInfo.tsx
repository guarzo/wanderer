import React from 'react';
import { zkillLink } from '../helpers';

interface KillRowSubInfoProps {
  victimCorpId: number | null | undefined;
  victimCorpLogoUrl: string | null;
  victimAllianceId: number | null | undefined;
  victimAllianceLogoUrl: string | null;
  victimCharacterId: number | null | undefined;
  victimPortraitUrl: string | null;
}

export const KillRowSubInfo: React.FC<KillRowSubInfoProps> = ({
  victimCorpId,
  victimCorpLogoUrl,
  victimAllianceId,
  victimAllianceLogoUrl,
  victimCharacterId,
  victimPortraitUrl,
}) => {
  return (
    <div className="flex items-start gap-2 h-full">
      {victimPortraitUrl && victimCharacterId && (
        <a
          href={zkillLink('character', victimCharacterId)}
          target="_blank"
          rel="noopener noreferrer"
          className="shrink-0 h-full"
        >
          <img
            src={victimPortraitUrl}
            alt="VictimPortrait"
            className="border border-stone-600 rounded-none h-full w-auto object-contain"
          />
        </a>
      )}
      <div className="flex flex-col h-full">
        {victimCorpLogoUrl && victimCorpId && (
          <a
            href={zkillLink('corporation', victimCorpId)}
            target="_blank"
            rel="noopener noreferrer"
            className="shrink-0 h-1/2"
          >
            <img
              src={victimCorpLogoUrl}
              alt="VictimCorp"
              className="border border-stone-600 rounded-none w-auto h-full object-contain"
            />
          </a>
        )}
        {victimAllianceLogoUrl && victimAllianceId && (
          <a
            href={zkillLink('alliance', victimAllianceId)}
            target="_blank"
            rel="noopener noreferrer"
            className="shrink-0 h-1/2"
          >
            <img
              src={victimAllianceLogoUrl}
              alt="VictimAlliance"
              className="border border-stone-600 rounded-none w-auto h-full object-contain"
            />
          </a>
        )}
      </div>
    </div>
  );
};
