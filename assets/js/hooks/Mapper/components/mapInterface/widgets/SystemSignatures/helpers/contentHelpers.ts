// contentHelpers.ts

import clsx from 'clsx';
import classes from './contentHelpers.module.scss';
import { SystemSignature } from '@/hooks/Mapper/types';

export interface ExtendedSystemSignature extends SystemSignature {
  pendingDeletion?: boolean;
  pendingUntil?: number;
}

export const FLASH_DURATION_MS = 5000;
export const FINAL_DURATION_MS = 30000;

export function toSystemSignature(sig: ExtendedSystemSignature): SystemSignature {
  // Simple cast: ensures we strip "pendingDeletion" fields
  return sig as SystemSignature;
}

/**
 * Build the payload for an "updateSignatures" command: add/update/remove.
 */
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

/**
 * Schedules two timers for each signature:
 *  - after flashMs: remove from local UI
 *  - after finalMs: remove from the server
 */
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
      // Remove from UI after flashMs
      setSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
    }, flashMs);

    const finalTimeoutId = window.setTimeout(async () => {
      // Actually remove from server after finalMs
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

/**
 * Merges "pendingDeletion" flags from local into the newly fetched server list,
 * so that signatures still pending a possible undo remain "highlighted" or "flash".
 */
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

    // If local was still pending and not expired, restore that status
    const stillPending = localSig.pendingUntil && localSig.pendingUntil > now;
    if (stillPending) {
      return { ...sig, pendingDeletion: true, pendingUntil: localSig.pendingUntil };
    }
    return sig;
  });

  // If there were some local pending that didn't appear in the server list, keep them
  const extraPending = Array.from(localMap.values()).filter(p => !merged.some(m => m.eve_id === p.eve_id));

  return [...merged, ...extraPending];
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
  selectedSignatures: ExtendedSystemSignature[],
  getRowColorByTimeLeft: (date?: Date) => string | null | undefined,
): string {
  const isFlashingDeletion =
    pendingDeletionMap[row.eve_id]?.flashUntil && pendingDeletionMap[row.eve_id].flashUntil > Date.now();

  if (isFlashingDeletion || row.pendingDeletion) {
    return clsx(classes.TableRowCompact, classes.flashPending);
  }

  if (selectedSignatures.some(s => s.eve_id === row.eve_id)) {
    return clsx(classes.TableRowCompact, 'bg-amber-500/50 hover:bg-amber-500/70 transition duration-200');
  }

  const dateClass = getRowColorByTimeLeft(row.inserted_at ? new Date(row.inserted_at) : undefined) ?? '';
  return clsx(classes.TableRowCompact, dateClass || 'hover:bg-purple-400/20 transition duration-200');
}
