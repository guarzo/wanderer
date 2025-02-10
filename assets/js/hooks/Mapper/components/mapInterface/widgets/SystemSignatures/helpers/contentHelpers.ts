import clsx from 'clsx';
import classes from './contentHelpers.module.scss';
import { SystemSignature } from '@/hooks/Mapper/types';

export interface ExtendedSystemSignature extends SystemSignature {
  pendingDeletion?: boolean;
  pendingUntil?: number;
}

export interface PendingChange extends ExtendedSystemSignature {
  action: 'add' | 'delete';
}

export const FLASH_DURATION_MS = 5000;
export const FINAL_DURATION_MS = 30000;

export function toSystemSignature(sig: ExtendedSystemSignature): SystemSignature {
  return sig as SystemSignature;
}

export function prepareUpdatePayload(
  systemId: string,
  added: ExtendedSystemSignature[],
  updated: ExtendedSystemSignature[],
  removed: ExtendedSystemSignature[],
) {
  return {
    system_id: systemId,
    added: added.map(toSystemSignature),
    updated: updated.map(toSystemSignature),
    removed: removed.map(toSystemSignature),
  };
}

export function scheduleLazyDeletionTimers(
  toRemove: ExtendedSystemSignature[],
  setPendingMap: React.Dispatch<
    React.SetStateAction<
      Record<
        string,
        {
          flashUntil: number;
          finalUntil: number;
          flashTimeoutId: number;
          finalTimeoutId: number;
        }
      >
    >
  >,
  removeSignaturePermanently: (sig: ExtendedSystemSignature) => Promise<void>,
  setSignatures: React.Dispatch<React.SetStateAction<ExtendedSystemSignature[]>>,
  flashMs = FLASH_DURATION_MS,
  finalMs = FINAL_DURATION_MS,
) {
  const now = Date.now();
  toRemove.forEach(sig => {
    const flashTimeoutId = window.setTimeout(() => {
      setSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
    }, flashMs);

    const finalTimeoutId = window.setTimeout(async () => {
      await removeSignaturePermanently(sig);
      setPendingMap(prev => {
        const updated = { ...prev };
        delete updated[sig.eve_id];
        return updated;
      });
    }, finalMs);

    setPendingMap(prev => ({
      ...prev,
      [sig.eve_id]: {
        flashUntil: now + flashMs,
        finalUntil: now + finalMs,
        flashTimeoutId,
        finalTimeoutId,
      },
    }));
  });
}

export function mergeWithPendingFlags(
  server: ExtendedSystemSignature[],
  local: ExtendedSystemSignature[],
): ExtendedSystemSignature[] {
  const now = Date.now();
  const localMap = new Map<string, ExtendedSystemSignature>();

  local.forEach(sig => {
    localMap.set(sig.eve_id, {
      ...sig,
      pendingDeletion: !!sig.pendingDeletion,
    });
  });

  const merged = server.map(sig => {
    const serverSig = { ...sig, pendingDeletion: !!sig.pendingDeletion };
    const localSig = localMap.get(serverSig.eve_id);
    if (!localSig) return serverSig;

    const isStillPending = localSig.pendingDeletion && localSig.pendingUntil && localSig.pendingUntil > now;

    return {
      ...serverSig,
      pendingDeletion: isStillPending,
      pendingUntil: isStillPending ? localSig.pendingUntil : undefined,
    };
  });

  const extraPending = Array.from(localMap.values()).filter(
    x => x.pendingDeletion && !merged.some(m => m.eve_id === x.eve_id),
  );

  return [...merged, ...extraPending].map(sig => ({
    ...sig,
    pendingDeletion: !!sig.pendingDeletion,
  }));
}

export function getRowClassName(
  row: ExtendedSystemSignature,
  pendingDeletionMap: Record<
    string,
    {
      flashUntil: number;
      finalUntil: number;
      flashTimeoutId: number;
      finalTimeoutId: number;
    }
  >,
  selectedIds: string[],
  getRowColorByTimeLeft: (date?: Date) => string | null | undefined,
): string {
  const isFlashingDeletion =
    pendingDeletionMap[row.eve_id]?.flashUntil && pendingDeletionMap[row.eve_id].flashUntil > Date.now();

  if (isFlashingDeletion || row.pendingDeletion) {
    return clsx(classes.TableRowCompact, classes.flashPending);
  }

  if (selectedIds.includes(row.eve_id)) {
    return clsx(classes.TableRowCompact, 'bg-amber-500/50 hover:bg-amber-500/70 transition duration-200');
  }

  const dateClass = getRowColorByTimeLeft(row.inserted_at ? new Date(row.inserted_at) : undefined) ?? '';

  return clsx(classes.TableRowCompact, dateClass || 'hover:bg-purple-400/20 transition duration-200');
}
