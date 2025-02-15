import { useEffect, useState } from 'react';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { Commands } from '@/hooks/Mapper/types';

export function useNodeKillsCount(systemId: number | string, initialKillsCount: number | null): number | null {
  const [killsCount, setKillsCount] = useState<number | null>(initialKillsCount);

  useEffect(() => {
    setKillsCount(initialKillsCount);
  }, [initialKillsCount]);

  useMapEventListener(event => {
    if (event.name === Commands.killsUpdated && event.data?.toString() === systemId.toString()) {
      //@ts-ignore
      if (event.payload && typeof event.payload.kills === 'number') {
        // @ts-ignore
        setKillsCount(event.payload.kills);
      }
      return true;
    }
    return false;
  });

  return killsCount;
}
