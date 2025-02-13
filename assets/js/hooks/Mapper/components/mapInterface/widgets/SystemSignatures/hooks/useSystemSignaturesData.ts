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
      console.debug('[handleGetSignatures] No systemId provided, clearing signatures.');
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
    console.debug(`[handleGetSignatures] Fetched signatures from server, count: ${extendedServer.length}`);
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
      console.debug(
        `[handleUpdateSignatures] Update requested. Added: ${added.length}, Updated: ${updated.length}, Removed: ${removed.length}`,
      );
      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, removed),
      });
      const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      console.debug(`[handleUpdateSignatures] Updated signatures from server, count: ${castedUpdated.length}`);
      setSignatures(castedUpdated);
      setSelectedSignatures([]);
    },
    [systemId, outCommand, signaturesRef, setSignatures],
  );

  const handleDeleteSelected = useCallback(async () => {
    if (selectedSignatures.length === 0) return;
    const selectedIds = selectedSignatures.map(x => x.eve_id);
    console.debug(`[handleDeleteSelected] Deleting selected signatures: ${selectedIds.join(', ')}`);
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
    console.debug('[undoPending] Initiating undo for pending actions.');
    Object.values(pendingDeletionMap).forEach(({ finalTimeoutId }) => {
      console.debug(`[undoPending] Clearing deletion timeout with id: ${finalTimeoutId}`);
      clearTimeout(finalTimeoutId);
    });
    Object.values(pendingAdditionMap).forEach(({ finalTimeoutId }) => {
      console.debug(`[undoPending] Clearing addition timeout with id: ${finalTimeoutId}`);
      clearTimeout(finalTimeoutId);
    });

    setSignatures(prev =>
      prev.map(sig => (sig.pendingDeletion ? { ...sig, pendingDeletion: false, pendingUntil: undefined } : sig)),
    );

    Promise.all(
      pendingUndoAdditions.map(async sig => {
        console.debug(`[undoPending] Reverting pending addition for signature: ${sig.eve_id}`);
        return outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, [], [], [sig]),
        });
      }),
    )
      .then(() => {
        console.debug('[undoPending] Successfully undone pending additions. Updating signatures state.');
        setSignatures(prev => prev.filter(sig => !pendingUndoAdditions.some(p => p.eve_id === sig.eve_id)));
      })
      .catch(err => {
        console.error('undoPending: Error undoing pending additions', err);
      });

    setPendingDeletionMap({});
    setPendingUndoDeletions([]);
    setPendingAdditionMap({});
    setPendingUndoAdditions([]);
    console.debug('[undoPending] Cleared all pending deletion and addition states.');
  }, [pendingDeletionMap, pendingAdditionMap, pendingUndoAdditions, outCommand, systemId, setSignatures]);

  useEffect(() => {
    const combinedPending = [...pendingUndoDeletions, ...pendingUndoAdditions];
    onPendingChange?.(combinedPending, undoPending);
  }, [pendingUndoDeletions, pendingUndoAdditions, onPendingChange, undoPending]);

  const processAddedSignatures = useCallback(
    (added: ExtendedSystemSignature[]) => {
      if (added.length === 0) return;
      console.debug(
        `[processAddedSignatures] Processing ${added.length} added signatures: ${added.map(s => s.eve_id).join(', ')}`,
      );
      setPendingUndoAdditions(prev => [...prev, ...added]);
      added.forEach((sig: SystemSignature) => {
        const now = Date.now();
        const finalTime = now + FINAL_DURATION_MS;
        console.debug(
          `[processAddedSignatures] Marking signature ${sig.eve_id} as pending addition until ${new Date(
            finalTime,
          ).toISOString()}`,
        );
        const finalTimeoutId = window.setTimeout(() => {
          console.debug(`[processAddedSignatures] Finalizing pending addition for signature ${sig.eve_id}`);
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

        setPendingAdditionMap(map => ({
          ...map,
          [sig.eve_id]: {
            finalUntil: finalTime,
            finalTimeoutId,
          },
        }));
        setSignatures(prev =>
          prev.map(s =>
            s.eve_id === sig.eve_id ? { ...s, pendingAddition: true, pendingUntil: finalTime } : s,
          ),
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
      console.debug(
        `[processRemovedSignatures] Processing removal for ${removed.length} signatures: ${removed
          .map(s => s.eve_id)
          .join(', ')}`,
      );
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
          console.debug(`[processRemovedSignatures] Finalizing pending deletion for signature ${sig.eve_id}`);
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

      console.debug(
        `[processRemovedSignatures] Updating signatures state after removal. Pending deletion signatures: ${[
          ...updatedWithRemoval,
          ...onlyRemoved,
        ]
          .map(s => s.eve_id)
          .join(', ')}`,
      );
      setSignatures([...updatedWithRemoval, ...onlyRemoved]);
    },
    [outCommand, systemId, setSignatures, setPendingDeletionMap, setPendingUndoDeletions],
  );

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
      console.debug('[handlePaste] Pasting signatures from clipboard.');
      const incomingSignatures = parseSignatures(
        clipboardString,
        settings.map(x => x.key),
      )
        .map(s => ({ ...s }))
        .filter(Boolean) as ExtendedSystemSignature[];

      const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion && !sig.pendingAddition);

      const mergedIncomingSignatures = mergeIncomingSignatures(incomingSignatures, currentNonPending);

      const { added, updated, removed } = getActualSigs(currentNonPending, mergedIncomingSignatures, false, true);
      console.debug(
        `[handlePaste] Parsed signatures. Incoming: ${incomingSignatures.length}, Merged: ${mergedIncomingSignatures.length}, Added: ${added.length}, Updated: ${updated.length}, Removed: ${removed.length}`,
      );

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
