import { Dialog } from 'primereact/dialog';
import {
  TrackingProvider,
  useTracking,
} from '@/hooks/Mapper/components/mapRootContent/components/TrackingDialog/TrackingProvider.tsx';
import { FleetReadinessContent } from './FleetReadinessContent';
import { useEffect } from 'react';

interface FleetReadinessProps {
  visible: boolean;
  onHide: () => void;
}

export const FleetReadiness = ({ visible, onHide }: FleetReadinessProps) => {
  return (
    <TrackingProvider>
      <FleetReadinessContentWrapper visible={visible} onHide={onHide} />
    </TrackingProvider>
  );
};

const FleetReadinessContentWrapper = ({ visible, onHide }: FleetReadinessProps) => {
  const { loadTracking, trackingCharacters } = useTracking();

  useEffect(() => {
    loadTracking();
  }, [loadTracking]);

  // Count ready characters
  const readyCount = trackingCharacters.filter(char => char.ready).length;

  return (
    <Dialog
      header={`Fleet Readiness (${readyCount})`}
      visible={visible}
      onHide={onHide}
      className="w-[800px] max-h-[90vh]"
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
