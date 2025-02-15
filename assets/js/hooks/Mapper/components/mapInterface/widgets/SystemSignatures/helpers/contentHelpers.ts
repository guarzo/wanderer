import { SystemSignature } from '@/hooks/Mapper/types';
import { FINAL_DURATION_MS } from '../constants';

export interface ExtendedSystemSignature extends SystemSignature {
  pendingDeletion?: boolean;
  pendingAddition?: boolean;
  pendingUntil?: number;
}

export function prepareUpdatePayload(
  systemId: string,
  added: ExtendedSystemSignature[],
  updated: ExtendedSystemSignature[],
  removed: ExtendedSystemSignature[],
) {
  return {
    system_id: systemId,
    added: added.map(s => ({ ...s })),
    updated: updated.map(s => ({ ...s })),
    removed: removed.map(s => ({ ...s })),
  };
}

export function schedulePendingAdditionForSig(
  sig: ExtendedSystemSignature,
  finalDuration: number,
  setSignatures: React.Dispatch<React.SetStateAction<ExtendedSystemSignature[]>>,
  pendingAdditionMapRef: React.MutableRefObject<Record<string, { finalUntil: number; finalTimeoutId: number }>>,
  setPendingUndoAdditions: React.Dispatch<React.SetStateAction<ExtendedSystemSignature[]>>,
) {
  console.debug(`[schedulePendingAdditionForSig] Setting up timer for: ${sig.eve_id}`);

  setPendingUndoAdditions(prev => [...prev, sig]);

  const now = Date.now();
  const finalTimeoutId = window.setTimeout(() => {
    console.debug(`[schedulePendingAdditionForSig] Finalizing addition for: ${sig.eve_id}`);
    setSignatures(prev =>
      prev.map(x => (x.eve_id === sig.eve_id ? { ...x, pendingAddition: false, pendingUntil: undefined } : x)),
    );
    const clone = { ...pendingAdditionMapRef.current };
    delete clone[sig.eve_id];
    pendingAdditionMapRef.current = clone;

    setPendingUndoAdditions(prev => prev.filter(x => x.eve_id !== sig.eve_id));
  }, finalDuration);

  pendingAdditionMapRef.current = {
    ...pendingAdditionMapRef.current,
    [sig.eve_id]: {
      finalUntil: now + finalDuration,
      finalTimeoutId,
    },
  };

  setSignatures(prev =>
    prev.map(x => (x.eve_id === sig.eve_id ? { ...x, pendingAddition: true, pendingUntil: now + finalDuration } : x)),
  );
}

export function scheduleLazyDeletionTimers(
  toRemove: ExtendedSystemSignature[],
  setPendingMap: React.Dispatch<React.SetStateAction<Record<string, { finalUntil: number; finalTimeoutId: number }>>>,
  finalizeRemoval: (sig: ExtendedSystemSignature) => Promise<void>,
  finalDuration = FINAL_DURATION_MS,
) {
  console.debug(`[scheduleLazyDeletionTimers] Scheduling final removal for ${toRemove.length} items`);
  const now = Date.now();
  toRemove.forEach(sig => {
    const finalTimeoutId = window.setTimeout(async () => {
      console.debug(`[scheduleLazyDeletionTimers] Finalizing removal for: ${sig.eve_id}`);
      await finalizeRemoval(sig);
    }, finalDuration);

    setPendingMap(prev => ({
      ...prev,
      [sig.eve_id]: {
        finalUntil: now + finalDuration,
        finalTimeoutId,
      },
    }));
  });
}
