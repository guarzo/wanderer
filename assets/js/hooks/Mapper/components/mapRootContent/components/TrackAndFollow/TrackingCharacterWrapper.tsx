import { WdCheckbox } from '@/hooks/Mapper/components/ui-kit/WdCheckbox/WdCheckbox';
import WdRadioButton from '@/hooks/Mapper/components/ui-kit/WdRadioButton';
import { CharacterCard, TooltipPosition, WdTooltipWrapper } from '../../../ui-kit';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';

interface TrackingCharacterWrapperProps {
  character: CharacterTypeRaw;
  isTracked: boolean;
  isFollowed: boolean;
  isTrackLoading?: boolean;
  isFollowLoading?: boolean;
  onTrackToggle: () => void;
  onFollowToggle: () => void;
}

export const TrackingCharacterWrapper = ({
  character,
  isTracked,
  isFollowed,
  isTrackLoading = false,
  isFollowLoading = false,
  onTrackToggle,
  onFollowToggle,
}: TrackingCharacterWrapperProps) => {
  const trackCheckboxId = `track-${character.eve_id}`;
  const followRadioId = `follow-${character.eve_id}`;
  const isDisabled = isTrackLoading || isFollowLoading;

  return (
    <div className="grid grid-cols-[80px_80px_1fr] items-center min-h-8 hover:bg-neutral-800 border-b border-[#383838]">
      <div className="flex justify-center items-center p-0.5 text-center">
        <WdTooltipWrapper content="Track this character on the map" position={TooltipPosition.top}>
          <div className="flex justify-center items-center w-full">
            {isTrackLoading ? (
              <div className="w-4 h-4 rounded-full border-2 border-t-transparent border-blue-500 animate-spin"></div>
            ) : (
              <div className={isDisabled ? 'opacity-50' : ''}>
                <WdCheckbox
                  id={trackCheckboxId}
                  label=""
                  value={isTracked}
                  onChange={isDisabled ? () => {} : onTrackToggle}
                />
              </div>
            )}
          </div>
        </WdTooltipWrapper>
      </div>
      <div className="flex justify-center items-center p-0.5 text-center">
        <WdTooltipWrapper content="Follow this character's movements on the map" position={TooltipPosition.top}>
          <div className="flex justify-center items-center w-full">
            {isFollowLoading ? (
              <div className="w-4 h-4 rounded-full border-2 border-t-transparent border-blue-500 animate-spin"></div>
            ) : (
              <div
                onClick={isDisabled ? () => {} : onFollowToggle}
                className={`cursor-pointer ${isDisabled ? 'opacity-50 pointer-events-none' : ''}`}
              >
                <WdRadioButton id={followRadioId} name="followed_character" checked={isFollowed} onChange={() => {}} />
              </div>
            )}
          </div>
        </WdTooltipWrapper>
      </div>
      <div className="flex items-center justify-center">
        <CharacterCard showShipName={false} showSystem={false} isOwn {...character} />
      </div>
    </div>
  );
};
