import { useMemo } from 'react';
import { SystemKillsContent } from '../../../mapInterface/widgets/SystemKills/SystemKillsContent/SystemKillsContent';
import { useKillsCounter } from '../../hooks/useKillsCounter';
import { WdTooltipWrapper } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper';
import { WithChildren, WithClassName } from '@/hooks/Mapper/types/common';
import { useKillsWidgetSettings } from '../../../mapInterface/widgets/SystemKills/hooks/useKillsWidgetSettings';

const ITEM_HEIGHT = 35;
const MIN_TOOLTIP_HEIGHT = 40;

type TooltipSize = 'xs' | 'sm' | 'md' | 'lg';

type KillsBookmarkTooltipProps = {
  killsCount: number;
  killsActivityType: string | null;
  systemId: string;
  className?: string;
  size?: TooltipSize;
} & WithChildren &
  WithClassName;

export const KillsCounter = ({ killsCount, systemId, className, children, size = 'xs' }: KillsBookmarkTooltipProps) => {
  const [settings] = useKillsWidgetSettings();
  const {
    isLoading,
    kills: detailedKills,
    systemNameMap,
  } = useKillsCounter({
    realSystemId: systemId,
  });

  const limitedKills = useMemo(() => {
    if (!detailedKills || detailedKills.length === 0) return [];

    const cutoffTime = new Date();
    cutoffTime.setHours(cutoffTime.getHours() - settings.timeRange);

    const timeFilteredKills = detailedKills.filter(kill => {
      if (!kill.kill_time) return false;
      const killTime = new Date(kill.kill_time).getTime();
      return killTime >= cutoffTime.getTime();
    });

    return timeFilteredKills.slice(0, killsCount);
  }, [detailedKills, killsCount, settings.timeRange]);

  if (!killsCount || !systemId || isLoading) {
    return null;
  }

  const tooltipContent =
    limitedKills.length > 0 ? (
      <div
        style={{
          width: '400px',
          height: `${Math.max(MIN_TOOLTIP_HEIGHT, Math.min(limitedKills.length * ITEM_HEIGHT + 10, 500))}px`,
          display: 'flex',
          flexDirection: 'column',
        }}
        className="overflow-hidden"
      >
        <div className="flex-1 h-full">
          <SystemKillsContent
            kills={limitedKills}
            systemNameMap={systemNameMap}
            onlyOneSystem
            timeRange={settings.timeRange}
          />
        </div>
      </div>
    ) : null;

  return (
    <WdTooltipWrapper content={tooltipContent} className={className} size={size} interactive={limitedKills.length > 0}>
      {children}
    </WdTooltipWrapper>
  );
};
