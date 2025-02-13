import { useCallback, useEffect, useState } from 'react';
import useRefState from 'react-usestateref';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { SignatureGroup, SystemSignature } from '@/hooks/Mapper/types';
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
import { TIME_ONE_DAY, TIME_ONE_WEEK } from '../constants.ts';

export interface UseSystemSignaturesDataProps {
  systemId: string;
  settings: { key: string; value: boolean }[];
  hideLinkedSignatures?: boolean;
  onCountChange: (count: number) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
}

/**
 * When pasting signatures, we merge incoming duplicates with those already in memory.
 * To ensure that a duplicate paste refreshes the signature’s updated_at, we override
 * that property with the current timestamp.
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
        // Reset updated_at to current time so that duplicates are refreshed
        updated_at: new Date().toISOString(),
      };
    }
    return newSig;
  });
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
    setSignatures(extendedServer);
  }, [systemId, outCommand, settings, signaturesRef, setSignatures]);

  const handleUpdateSignatures = useCallback(
    async (newSignatures: ExtendedSystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );
      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, removed),
      });
      const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      setSignatures(castedUpdated);
      setSelectedSignatures([]);
    },
    [systemId, outCommand, signaturesRef, setSignatures],
  );

  const handleDeleteSelected = useCallback(async () => {
    if (selectedSignatures.length === 0) return;
    const selectedIds = selectedSignatures.map(x => x.eve_id);
    await handleUpdateSignatures(
      signatures.filter(x => !selectedIds.includes(x.eve_id)),
      false,
      true,
    );
  }, [selectedSignatures, signatures, handleUpdateSignatures]);

  const handleSelectAll = useCallback(() => {
    setSelectedSignatures(signatures);
  }, [signatures]);

  const undoPending = useCallback(() => {
    // Clear any pending timers.
    Object.values(pendingDeletionMap).forEach(({ finalTimeoutId }) => clearTimeout(finalTimeoutId));
    Object.values(pendingAdditionMap).forEach(({ finalTimeoutId }) => clearTimeout(finalTimeoutId));

    // Reset pending deletion flags.
    setSignatures(prev =>
      prev.map(sig => (sig.pendingDeletion ? { ...sig, pendingDeletion: false, pendingUntil: undefined } : sig)),
    );

    // Process pending additions undo.
    Promise.all(
      pendingUndoAdditions.map(async sig => {
        await outCommand({
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
    onPendingChange?.(combinedPending, undoPending);
  }, [pendingUndoDeletions, pendingUndoAdditions, onPendingChange, undoPending]);

  /**
   * Processes the added signatures by setting pending flags and scheduling
   * their removal after the final duration.
   */
  const processAddedSignatures = useCallback(
    (added: ExtendedSystemSignature[]) => {
      if (added.length === 0) return;
      setPendingUndoAdditions(prev => [...prev, ...added]);
      added.forEach((sig: SystemSignature) => {
        const finalTimeoutId = window.setTimeout(() => {
          setSignatures(prev =>
            prev.map(s => (s.eve_id === sig.eve_id ? { ...s, pendingAddition: false, pendingUntil: undefined } : s)),
          );
          setPendingAdditionMap(map => {
            const newMap = { ...map };
            delete newMap[sig.eve_id];
            return newMap;
          });
          setPendingUndoAdditions(prev => prev.filter(x => x.eve_id !== sig.eve_id));
        }, FINAL_DURATION_MS);
        const now = Date.now();
        setPendingAdditionMap(map => ({
          ...map,
          [sig.eve_id]: {
            finalUntil: now + FINAL_DURATION_MS,
            finalTimeoutId,
          },
        }));
        setSignatures(prev =>
          prev.map(s =>
            s.eve_id === sig.eve_id ? { ...s, pendingAddition: true, pendingUntil: now + FINAL_DURATION_MS } : s,
          ),
        );
      });
    },
    [setSignatures, setPendingAdditionMap, setPendingUndoAdditions],
  );

  /**
   * Processes the removed signatures by updating the server and scheduling
   * lazy deletion timers.
   */
  const processRemovedSignatures = useCallback(
    async (
      removed: ExtendedSystemSignature[],
      added: ExtendedSystemSignature[],
      updated: ExtendedSystemSignature[],
    ) => {
      if (removed.length === 0) return;
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
      setSignatures([...updatedWithRemoval, ...onlyRemoved]);
    },
    [outCommand, systemId, setSignatures, setPendingDeletionMap, setPendingUndoDeletions],
  );

  useEffect(() => {
    const currentTime = Date.now();
    const signaturesToDelete = signaturesRef.current.filter(sig => {
      if (!sig.inserted_at) return false;
      const insertedTime = new Date(sig.inserted_at).getTime();
      const threshold = sig.group === SignatureGroup.Wormhole ? TIME_ONE_DAY : TIME_ONE_WEEK;
      return currentTime - insertedTime > threshold;
    });
    if (signaturesToDelete.length > 0) {
      console.debug('[PeriodicDelete] Deleting', signaturesToDelete.length, 'old signatures.');
      const remainingSignatures = signaturesRef.current.filter(sig => !signaturesToDelete.includes(sig));
      handleUpdateSignatures(remainingSignatures, false, true);
    }
  }, [handleUpdateSignatures, signatures, signaturesRef]);

  /**
   * Handle paste action by parsing the clipboard string, merging incoming
   * signatures with existing ones, and then processing added or removed signatures.
   */
  const handlePaste = useCallback(
    async (clipboardString: string) => {
      // Parse incoming signatures from the clipboard.
      const incomingSignatures = parseSignatures(
        clipboardString,
        settings.map(x => x.key),
      )
        .map(s => ({ ...s }))
        .filter(Boolean) as ExtendedSystemSignature[];

      // Filter out signatures that are not pending deletion or addition.
      const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion && !sig.pendingAddition);

      // Merge incoming signatures with existing ones.
      // (Now duplicates will have their updated_at reset to the current time)
      const mergedIncomingSignatures = mergeIncomingSignatures(incomingSignatures, currentNonPending);

      // Determine the differences between the current and incoming signatures.
      const { added, updated, removed } = getActualSigs(currentNonPending, mergedIncomingSignatures, false, true);

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
      handleGetSignatures();
      return true;
    }
  });

  useEffect(() => {
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
