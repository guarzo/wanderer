import { useCallback, useEffect, useState } from 'react';
import useRefState from 'react-usestateref';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { SystemSignature, SignatureGroup } from '@/hooks/Mapper/types';
import {
  ExtendedSystemSignature,
  FINAL_DURATION_MS,
  mergeWithPendingFlags,
  prepareUpdatePayload,
  scheduleLazyDeletionTimers,
} from '../helpers/contentHelpers';
import { getActualSigs } from '../helpers';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { parseSignatures } from '@/hooks/Mapper/helpers';
import { LAZY_DELETE_SIGNATURES_SETTING } from '@/hooks/Mapper/components/mapInterface/widgets';
import { TIME_ONE_DAY, TIME_ONE_WEEK } from '../constants';

export interface UseSystemSignaturesDataProps {
  systemId: string;
  settings: { key: string; value: boolean }[];
  hideLinkedSignatures?: boolean;
  onCountChange: (count: number) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
}

/**
 * Helper to merge incoming signatures with the locally pending ones.
 */
function mergeIncomingSignatures(
  incoming: ExtendedSystemSignature[],
  currentNonPending: ExtendedSystemSignature[],
): ExtendedSystemSignature[] {
  return incoming.map(newSig => {
    const existingSig = currentNonPending.find(sig => sig.eve_id === newSig.eve_id);
    if (existingSig) {
      return {
        ...newSig,
        kind: existingSig.kind,
        updated_at: new Date().toISOString(),
      };
    }
    return newSig;
  });
}

/**
 * Helper to clear all pending timers from a given pending map.
 */
function clearPendingTimers(pendingMap: Record<string, { finalTimeoutId: number }>) {
  Object.values(pendingMap).forEach(({ finalTimeoutId }) => clearTimeout(finalTimeoutId));
}

/**
 * Helper to schedule the finalization of a pending addition for a signature.
 */
function schedulePendingAdditionForSig(
  sig: ExtendedSystemSignature,
  finalDuration: number,
  setSignatures: React.Dispatch<React.SetStateAction<ExtendedSystemSignature[]>>,
  setPendingAdditionMap: React.Dispatch<
    React.SetStateAction<Record<string, { finalUntil: number; finalTimeoutId: number }>>
  >,
  setPendingUndoAdditions: React.Dispatch<React.SetStateAction<ExtendedSystemSignature[]>>,
) {
  const now = Date.now();
  const finalTimeoutId = window.setTimeout(() => {
    console.debug('[schedulePendingAdditionForSig] Finalizing addition for signature:', sig.eve_id);
    setSignatures(prev =>
      prev.map(s => (s.eve_id === sig.eve_id ? { ...s, pendingAddition: false, pendingUntil: undefined } : s)),
    );
    setPendingAdditionMap(map => {
      const newMap = { ...map };
      delete newMap[sig.eve_id];
      return newMap;
    });
    setPendingUndoAdditions(prev => prev.filter(x => x.eve_id !== sig.eve_id));
  }, finalDuration);

  setPendingAdditionMap(map => ({
    ...map,
    [sig.eve_id]: {
      finalUntil: now + finalDuration,
      finalTimeoutId,
    },
  }));

  setSignatures(prev =>
    prev.map(s => (s.eve_id === sig.eve_id ? { ...s, pendingAddition: true, pendingUntil: now + finalDuration } : s)),
  );
}

export function useSystemSignaturesData({
  systemId,
  settings,
  onCountChange,
  onPendingChange,
}: UseSystemSignaturesDataProps) {
  const { outCommand } = useMapRootState();

  const [signatures, setSignatures, signaturesRef] = useRefState<ExtendedSystemSignature[]>([]);
  const [selectedSignatures, setSelectedSignatures] = useState<ExtendedSystemSignature[]>([]);

  const [pendingDeletionMap, setPendingDeletionMap] = useState<
    Record<string, { finalUntil: number; finalTimeoutId: number }>
  >({});
  const [pendingUndoDeletions, setPendingUndoDeletions] = useState<ExtendedSystemSignature[]>([]);
  const [pendingAdditionMap, setPendingAdditionMap] = useState<
    Record<string, { finalUntil: number; finalTimeoutId: number }>
  >({});
  const [pendingUndoAdditions, setPendingUndoAdditions] = useState<ExtendedSystemSignature[]>([]);

  const handleGetSignatures = useCallback(async () => {
    console.debug('[handleGetSignatures] Fetching signatures for system:', systemId);
    if (!systemId) {
      setSignatures([]);
      return;
    }
    const { signatures: serverSignatures } = await outCommand({
      type: OutCommand.getSignatures,
      data: { system_id: systemId },
    });
    let extendedServer = (serverSignatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];

    const lazyDeleteValue = settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false;
    if (lazyDeleteValue) {
      extendedServer = mergeWithPendingFlags(extendedServer, signaturesRef.current);
    }
    console.debug('[handleGetSignatures] Received signatures:', extendedServer);
    setSignatures(extendedServer);
  }, [systemId, outCommand, settings, signaturesRef, setSignatures]);

  const handleUpdateSignatures = useCallback(
    async (newSignatures: ExtendedSystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      console.debug('[handleUpdateSignatures] Updating signatures...');
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );
      console.debug('[handleUpdateSignatures] Diff results:', { added, updated, removed });
      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, removed),
      });
      const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      console.debug('[handleUpdateSignatures] Update response, new signatures:', castedUpdated);
      setSignatures(castedUpdated);
      setSelectedSignatures([]);
    },
    [systemId, outCommand, signaturesRef, setSignatures],
  );

  const handleDeleteSelected = useCallback(async () => {
    if (selectedSignatures.length === 0) return;
    console.debug('[handleDeleteSelected] Deleting selected signatures:', selectedSignatures);
    const selectedIds = selectedSignatures.map(x => x.eve_id);
    await handleUpdateSignatures(
      signatures.filter(x => !selectedIds.includes(x.eve_id)),
      false,
      true,
    );
  }, [selectedSignatures, signatures, handleUpdateSignatures]);

  const handleSelectAll = useCallback(() => {
    console.debug('[handleSelectAll] Selecting all signatures.');
    setSelectedSignatures(signatures);
  }, [signatures]);

  const undoPending = useCallback(() => {
    console.debug('[undoPending] Undoing all pending changes.');
    clearPendingTimers(pendingDeletionMap);
    clearPendingTimers(pendingAdditionMap);

    setSignatures(prev =>
      prev.map(sig => (sig.pendingDeletion ? { ...sig, pendingDeletion: false, pendingUntil: undefined } : sig)),
    );

    Promise.all(
      pendingUndoAdditions.map(async sig => {
        console.debug('[undoPending] Reverting pending addition for signature:', sig.eve_id);
        return outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, [], [], [sig]),
        });
      }),
    )
      .then(() => {
        setSignatures(prev => prev.filter(sig => !pendingUndoAdditions.some(p => p.eve_id === sig.eve_id)));
      })
      .catch(err => {
        console.error('undoPending: Error undoing pending additions', err);
      });

    setPendingDeletionMap({});
    setPendingUndoDeletions([]);
    setPendingAdditionMap({});
    setPendingUndoAdditions([]);
  }, [pendingDeletionMap, pendingAdditionMap, pendingUndoAdditions, outCommand, systemId, setSignatures]);

  useEffect(() => {
    const combinedPending = [...pendingUndoDeletions, ...pendingUndoAdditions];
    console.debug('[useEffect onPendingChange] Combined pending changes:', combinedPending);
    onPendingChange?.(combinedPending, undoPending);
  }, [pendingUndoDeletions, pendingUndoAdditions, onPendingChange, undoPending]);

  const processAddedSignatures = useCallback(
    (added: ExtendedSystemSignature[]) => {
      if (added.length === 0) return;
      console.debug('[processAddedSignatures] Processing added signatures:', added);
      setPendingUndoAdditions(prev => [...prev, ...added]);
      added.forEach((sig: SystemSignature) => {
        schedulePendingAdditionForSig(
          sig,
          FINAL_DURATION_MS,
          setSignatures,
          setPendingAdditionMap,
          setPendingUndoAdditions,
        );
      });
    },
    [setSignatures, setPendingAdditionMap, setPendingUndoAdditions],
  );

  const processRemovedSignatures = useCallback(
    async (
      removed: ExtendedSystemSignature[],
      added: ExtendedSystemSignature[],
      updated: ExtendedSystemSignature[],
    ) => {
      if (removed.length === 0) return;
      console.debug('[processRemovedSignatures] Processing removed signatures:', removed);
      setPendingUndoDeletions(prev => [...prev, ...removed]);

      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, []),
      });
      const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];

      scheduleLazyDeletionTimers(
        removed,
        setPendingDeletionMap,
        async (sig: SystemSignature) => {
          console.debug('[processRemovedSignatures] Permanently deleting signature:', sig.eve_id);
          await outCommand({
            type: OutCommand.updateSignatures,
            data: prepareUpdatePayload(systemId, [], [], [sig]),
          });
          setPendingUndoDeletions(pu => pu.filter(x => x.eve_id !== sig.eve_id));
          setSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
        },
        setSignatures,
        FINAL_DURATION_MS,
      );

      const now = Date.now();
      const updatedWithRemoval = castedUpdated.map(sig =>
        removed.some(r => r.eve_id === sig.eve_id)
          ? { ...sig, pendingDeletion: true, pendingUntil: now + FINAL_DURATION_MS }
          : sig,
      );
      const onlyRemoved = removed
        .map(r => ({ ...r, pendingDeletion: true, pendingUntil: now + FINAL_DURATION_MS }))
        .filter(r => !updatedWithRemoval.some(m => m.eve_id === r.eve_id));

      const newSignatures = [...updatedWithRemoval, ...onlyRemoved];
      console.debug('[processRemovedSignatures] New signatures after removal processing:', newSignatures);
      setSignatures(newSignatures);
    },
    [outCommand, systemId, setSignatures, setPendingDeletionMap, setPendingUndoDeletions],
  );

  // Periodic deletion of signatures that are too old.
  useEffect(() => {
    if (!systemId) return;
    const currentTime = Date.now();
    const toDelete = signaturesRef.current.filter(sig => {
      if (!sig.inserted_at) return false;
      const insertedTime = new Date(sig.inserted_at).getTime();
      const threshold = sig.group === SignatureGroup.Wormhole ? TIME_ONE_DAY : TIME_ONE_WEEK;
      return currentTime - insertedTime > threshold;
    });
    if (toDelete.length > 0) {
      console.debug('[PeriodicDelete] Deleting', toDelete.length, 'old signatures.');
      const remaining = signaturesRef.current.filter(sig => !toDelete.includes(sig));
      handleUpdateSignatures(remaining, false, true);
    }
  }, [systemId, handleUpdateSignatures, signaturesRef]);

  const handlePaste = useCallback(
    async (clipboardString: string) => {
      console.debug('[handlePaste] Received clipboard content:', clipboardString);
      const incomingSignatures = parseSignatures(
        clipboardString,
        settings.map(x => x.key),
      )
        .map(s => ({ ...s }))
        .filter(Boolean) as ExtendedSystemSignature[];

      console.debug('[handlePaste] Parsed incoming signatures:', incomingSignatures);

      const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion && !sig.pendingAddition);
      console.debug('[handlePaste] Current non-pending signatures:', currentNonPending);

      const mergedIncomingSignatures = mergeIncomingSignatures(incomingSignatures, currentNonPending);
      console.debug('[handlePaste] Merged incoming signatures:', mergedIncomingSignatures);

      // Use updateOnly = true when lazy delete is not selected
      const lazyDeleteValue = settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false;
      const { added, updated, removed } = getActualSigs(
        currentNonPending,
        mergedIncomingSignatures,
        !lazyDeleteValue,
        true,
      );
      console.debug('[handlePaste] Diff results:', { added, updated, removed });

      if (added.length > 0) {
        processAddedSignatures(added);
      }

      if (removed.length > 0) {
        await processRemovedSignatures(removed, added, updated);
      } else {
        const resp = await outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, added, updated, []),
        });
        const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
        setSignatures(castedUpdated);
      }
    },
    [settings, outCommand, systemId, signaturesRef, setSignatures, processAddedSignatures, processRemovedSignatures],
  );

  useEffect(() => {
    if (!systemId) {
      setSignatures([]);
      return;
    }
    handleGetSignatures();
  }, [systemId, handleGetSignatures, setSignatures]);

  useMapEventListener(event => {
    if (event.name === Commands.signaturesUpdated && event.data?.toString() === systemId.toString()) {
      console.debug('[useMapEventListener] Signatures updated event received for system:', systemId);
      handleGetSignatures();
      return true;
    }
  });

  useEffect(() => {
    console.debug('[useEffect onCountChange] Signature count:', signatures.length);
    onCountChange(signatures.length);
  }, [signatures, onCountChange]);

  return {
    signatures,
    selectedSignatures,
    setSelectedSignatures,
    handleDeleteSelected,
    handleSelectAll,
    handlePaste,
    undoPending,
  };
}
