import { SystemSignature } from '@/hooks/Mapper/types';
import { getRowBackgroundColor } from './getRowBackgroundColor';

export interface ExtendedSystemSignature extends SystemSignature {
  pendingDeletion?: boolean;
  pendingUntil?: number;
  pendingAddition?: boolean;
  pendingAdditionFinal?: boolean;
}

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
          finalUntil: number;
          finalTimeoutId: number;
        }
      >
    >
  >,
  removeSignaturePermanently: (sig: ExtendedSystemSignature) => Promise<void>,
  setSignatures: React.Dispatch<React.SetStateAction<ExtendedSystemSignature[]>>,
  finalMs = FINAL_DURATION_MS,
) {
  const now = Date.now();
  toRemove.forEach(sig => {
    const finalTimeoutId = window.setTimeout(async () => {
      await removeSignaturePermanently(sig);
      setSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
    }, finalMs);

    setPendingMap(prev => ({
      ...prev,
      [sig.eve_id]: {
        finalUntil: now + finalMs,
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
    if (sig.pendingDeletion) {
      localMap.set(sig.eve_id, sig);
    }
  });

  const merged = server.map(sig => {
    const localSig = localMap.get(sig.eve_id);
    if (!localSig) return sig;

    const stillPending = localSig.pendingUntil && localSig.pendingUntil > now;
    if (stillPending) {
      return { ...sig, pendingDeletion: true, pendingUntil: localSig.pendingUntil };
    }
    return sig;
  });

  const extraPending = Array.from(localMap.values()).filter(p => !merged.some(m => m.eve_id === p.eve_id));

  return [...merged, ...extraPending];
}

export function getRowClassName(row: ExtendedSystemSignature, selectedSignatures: ExtendedSystemSignature[]): string {
  const baseClasses = 'h-2 text-[12px] leading-2';

  if (selectedSignatures.some(s => s.eve_id === row.eve_id)) {
    return `${baseClasses} bg-amber-500/50 hover:bg-amber-500/70 transition duration-200`;
  }

  if (row.pendingDeletion) {
    return `${baseClasses} bg-red-500/50 hover:bg-red-500/60 transition duration-200`;
  }

  const bgClass = getRowBackgroundColor(row.inserted_at ? new Date(row.inserted_at) : undefined);
  return `${baseClasses} ${bgClass || 'hover:bg-purple-400/20 transition duration-200'}`;
}
