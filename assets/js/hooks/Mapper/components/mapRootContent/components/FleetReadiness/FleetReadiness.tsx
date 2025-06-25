import { Dialog } from 'primereact/dialog';
import {
  TrackingProvider,
  useTracking,
} from '@/hooks/Mapper/components/mapRootContent/components/TrackingDialog/TrackingProvider.tsx';
import { FleetReadinessContent } from './FleetReadinessContent';
import { useEffect, useState, useCallback } from 'react';
import { Button } from 'primereact/button';
import { PrimeIcons } from 'primereact/api';

interface FleetReadinessProps {
  visible: boolean;
  onHide: () => void;
}

interface RateLimitError {
  error: string;
  message: string;
  remaining_cooldown: number;
}

export const FleetReadiness = ({ visible, onHide }: FleetReadinessProps) => {
  return (
    <TrackingProvider>
      <FleetReadinessContentWrapper visible={visible} onHide={onHide} />
    </TrackingProvider>
  );
};

const FleetReadinessContentWrapper = ({ visible, onHide }: FleetReadinessProps) => {
  const { loadTracking, trackingCharacters, updateReady } = useTracking();
  const [isClearing, setIsClearing] = useState<boolean>(false);
  const [rateLimitInfo, setRateLimitInfo] = useState<{
    isRateLimited: boolean;
    remainingCooldown: number;
    message: string;
  } | null>(null);

  useEffect(() => {
    loadTracking();
  }, [loadTracking]);

  // Count ready characters
  const readyCount = trackingCharacters.filter(char => char.ready).length;
  const canClearAll = !isClearing && readyCount > 0 && !rateLimitInfo?.isRateLimited;

  const formatCooldownTime = (milliseconds: number) => {
    const minutes = Math.floor(milliseconds / 60000);
    const seconds = Math.floor((milliseconds % 60000) / 1000);
    return `${minutes}:${seconds.toString().padStart(2, '0')}`;
  };

  const handleClearAll = useCallback(async () => {
    if (!canClearAll) return;

    setIsClearing(true);
    setRateLimitInfo(null);

    try {
      await updateReady([]);
    } catch (error: unknown) {
      // Handle server-side rate limiting
      const errorObj = error as RateLimitError;
      if (errorObj?.error === 'rate_limited') {
        setRateLimitInfo({
          isRateLimited: true,
          remainingCooldown: errorObj.remaining_cooldown || 0,
          message: errorObj.message || 'Clear all function is on cooldown',
        });
      } else {
        console.error('Failed to clear ready characters:', error);
      }
    } finally {
      setIsClearing(false);
    }
  }, [canClearAll, updateReady]);

  // Update cooldown timer
  useEffect(() => {
    if (!rateLimitInfo?.isRateLimited) return;

    const timer = setInterval(() => {
      setRateLimitInfo(prev => {
        if (!prev) return null;

        const newCooldown = Math.max(0, prev.remainingCooldown - 100);
        if (newCooldown === 0) {
          return null; // Clear rate limit info when cooldown expires
        }

        return {
          ...prev,
          remainingCooldown: newCooldown,
        };
      });
    }, 100);

    return () => clearInterval(timer);
  }, [rateLimitInfo?.isRateLimited]);

  const tooltipMessage = rateLimitInfo?.isRateLimited
    ? `Clear (available in ${formatCooldownTime(rateLimitInfo.remainingCooldown)})`
    : 'Clear';

  const dialogHeader = (
    <div className="flex justify-between items-center w-full">
      <span>{`Fleet Readiness (${readyCount})`}</span>
      {readyCount > 0 && (
        <Button
          icon={PrimeIcons.TIMES_CIRCLE}
          size="small"
          text
          disabled={!canClearAll}
          loading={isClearing}
          onClick={handleClearAll}
          tooltip={tooltipMessage}
          tooltipOptions={{ position: 'left' }}
          className="text-red-400 hover:text-red-300 hover:bg-red-500/20 transition-colors p-1"
        />
      )}
    </div>
  );

  return (
    <Dialog
      header={dialogHeader}
      visible={visible}
      onHide={onHide}
      className="w-[90vw] max-w-[700px] max-h-[90vh]"
      modal
      draggable={false}
      resizable={false}
      dismissableMask
      contentClassName="p-0 h-full flex flex-col"
    >
      <FleetReadinessContent />
    </Dialog>
  );
};
