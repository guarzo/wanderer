import { WdCheckbox } from '@/hooks/Mapper/components/ui-kit/WdCheckbox/WdCheckbox';
import WdRadioButton from '@/hooks/Mapper/components/ui-kit/WdRadioButton';
import { CharacterCard, TooltipPosition, WdTooltipWrapper } from '../../../ui-kit';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';

interface TrackingCharacterWrapperProps {
  character: CharacterTypeRaw;
  isTracked: boolean;
  isFollowed: boolean;
  onTrackToggle: () => void;
  onFollowToggle: () => void;
}

export const TrackingCharacterWrapper = ({
  character,
  isTracked,
  isFollowed,
  onTrackToggle,
  onFollowToggle,
}: TrackingCharacterWrapperProps) => {
  const trackCheckboxId = `track-${character.eve_id}`;
  const followRadioId = `follow-${character.eve_id}`;

  return (
    <div className="grid grid-cols-[5rem_5rem_1fr] items-center min-h-8 hover:bg-neutral-800 border-b border-neutral-800">
      <div className="flex justify-center items-center p-0.5">
        <WdTooltipWrapper content="Track this character on the map" position={TooltipPosition.top}>
          <div className="flex justify-center items-center w-full">
            <WdCheckbox id={trackCheckboxId} label="" value={isTracked} onChange={onTrackToggle} />
          </div>
        </WdTooltipWrapper>
      </div>
      <div className="flex justify-center items-center p-0.5">
        <WdTooltipWrapper content="Follow this character's movements on the map" position={TooltipPosition.top}>
          <div className="flex justify-center items-center w-full">
            <div onClick={onFollowToggle} className="cursor-pointer">
              <WdRadioButton id={followRadioId} name="followed_character" checked={isFollowed} onChange={() => {}} />
            </div>
          </div>
        </WdTooltipWrapper>
      </div>
      <div className="flex items-center px-2">
        <CharacterCard showShipName={false} showSystem={false} isOwn {...character} />
      </div>
    </div>
  );
};
