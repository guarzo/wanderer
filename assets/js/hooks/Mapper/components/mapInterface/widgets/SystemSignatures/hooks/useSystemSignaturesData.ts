import { useCallback, useEffect, useState } from 'react';
import useRefState from 'react-usestateref';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand, Commands } from '@/hooks/Mapper/types/mapHandlers';
import { SignatureKind, SystemSignature, SignatureGroup } from '@/hooks/Mapper/types';
import {
  ExtendedSystemSignature,
  prepareUpdatePayload,
  mergeWithPendingFlags,
  scheduleLazyDeletionTimers,
  FINAL_DURATION_MS,
} from '../helpers/contentHelpers';
import { parseSignatures, getActualSigs } from '../helpers/zooSignatures';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { TIME_ONE_DAY, TIME_ONE_WEEK } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';

export interface UseSystemSignaturesDataProps {
  systemId: string;
  settings: { key: string; value: boolean }[];
  hideLinkedSignatures?: boolean;
  onCountChange: (count: number) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
  onLazyDeleteChange?: (value: boolean) => void;
}

export function useSystemSignaturesData({
  systemId,
  settings,
  onCountChange,
  onPendingChange,
  onLazyDeleteChange,
}: UseSystemSignaturesDataProps) {
  const { outCommand } = useMapRootState();

  // State for signatures and a ref for the latest value.
  const [signatures, setSignatures, signaturesRef] = useRefState<ExtendedSystemSignature[]>([]);
  const [selectedSignatures, setSelectedSignatures] = useState<ExtendedSystemSignature[]>([]);

  // Compute lazy-delete settings.
  const lazyDeleteValue = settings.find(s => s.key === 'LAZY_DELETE_SIGNATURES_SETTING')?.value ?? false;
  const keepLazyDeleteValue = settings.find(s => s.key === 'KEEP_LAZY_DELETE_ENABLED_SETTING')?.value ?? false;

  // Pending maps and arrays.
  const [pendingDeletionMap, setPendingDeletionMap] = useState<
    Record<string, { finalUntil: number; finalTimeoutId: number }>
  >({});
  const [pendingUndoDeletions, setPendingUndoDeletions] = useState<ExtendedSystemSignature[]>([]);
  const [pendingAdditionMap, setPendingAdditionMap] = useState<
    Record<string, { finalUntil: number; finalTimeoutId: number }>
  >({});
  const [pendingUndoAdditions, setPendingUndoAdditions] = useState<ExtendedSystemSignature[]>([]);

  // Fetch signatures.
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
    console.debug('handleGetSignatures: Fetched signatures:', extendedServer);
    if (lazyDeleteValue) {
      extendedServer = mergeWithPendingFlags(extendedServer, signaturesRef.current);
      console.debug('handleGetSignatures: After merging pending flags:', extendedServer);
    }
    setSignatures(extendedServer);
  }, [systemId, outCommand, lazyDeleteValue, signaturesRef, setSignatures]);

  // Update signatures.
  const handleUpdateSignatures = useCallback(
    async (newSignatures: ExtendedSystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      console.debug('handleUpdateSignatures: New signatures:', newSignatures);
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );
      console.debug('handleUpdateSignatures: getActualSigs output:', { added, updated, removed });
      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, removed),
      });
      const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      console.debug('handleUpdateSignatures: Server returned:', castedUpdated);
      setSignatures(castedUpdated);
      setSelectedSignatures([]);
    },
    [systemId, outCommand, signaturesRef, setSignatures],
  );

  // Delete selected rows.
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

  // Undo pending changes.
  const undoPending = useCallback(() => {
    console.debug('undoPending: Cancelling timers');
    Object.values(pendingDeletionMap).forEach(({ finalTimeoutId }) => clearTimeout(finalTimeoutId));
    Object.values(pendingAdditionMap).forEach(({ finalTimeoutId }) => clearTimeout(finalTimeoutId));

    setSignatures(prev =>
      prev.map(sig => (sig.pendingDeletion ? { ...sig, pendingDeletion: false, pendingUntil: undefined } : sig)),
    );

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
      .catch(err => console.error('undoPending: Error undoing additions', err));

    setPendingDeletionMap({});
    setPendingUndoDeletions([]);
    setPendingAdditionMap({});
    setPendingUndoAdditions([]);
    console.debug('undoPending: Completed');
  }, [pendingDeletionMap, pendingAdditionMap, pendingUndoAdditions, outCommand, systemId, setSignatures]);

  useEffect(() => {
    const combinedPending = [...pendingUndoDeletions, ...pendingUndoAdditions];
    onPendingChange?.(combinedPending, undoPending);
  }, [pendingUndoDeletions, pendingUndoAdditions, onPendingChange, undoPending]);

  // EXPIRATION: Run once on mount.
  useEffect(() => {
    if (signaturesRef.current.length === 0) return;
    const now = Date.now();
    const expired = signaturesRef.current.filter(sig => {
      if (!sig.inserted_at) return false;
      const insertedTime = new Date(sig.inserted_at).getTime();
      const threshold = sig.group === SignatureGroup.Wormhole ? TIME_ONE_DAY : TIME_ONE_WEEK;
      return now - insertedTime > threshold;
    });
    if (expired.length > 0) {
      console.debug('Expiration logic: Found expired signatures:', expired);
      const remaining = signaturesRef.current.filter(sig => !expired.includes(sig));
      handleUpdateSignatures(remaining, false, true);
    }
  }, []);

  // handlePaste.
  const handlePaste = useCallback(
    async (clipboardString: string) => {
      console.debug('handlePaste: Received text:', clipboardString);
      if (lazyDeleteValue) {
        console.debug('handlePaste: Running lazy-delete branch');
        const newSignatures = parseSignatures(
          clipboardString,
          settings.map(x => x.key),
          undefined,
        ).map(s => ({ ...s })) as ExtendedSystemSignature[];
        console.debug('handlePaste: Parsed new signatures:', newSignatures);
        if (newSignatures.length === 0) return;
        const filteredNew = newSignatures.filter(sig => {
          if (sig.kind === SignatureKind.CosmicSignature && sig.eve_id.length === 3) {
            const prefix = sig.eve_id.substring(0, 3).toUpperCase();
            const condition = !signaturesRef.current.some(
              existingSig =>
                existingSig.kind === SignatureKind.CosmicSignature &&
                existingSig.eve_id.substring(0, 3).toUpperCase() === prefix &&
                existingSig.eve_id.length === 7,
            );
            console.debug(`handlePaste: Filtering ${sig.eve_id}: condition ${condition}`);
            return condition;
          }
          return true;
        });
        console.debug('handlePaste: Filtered new signatures:', filteredNew);
        const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion && !sig.pendingAddition);
        console.debug('handlePaste: Current non-pending signatures:', currentNonPending);
        // Set updateOnly = false so that any old signature not matched is removed.
        const { added, updated, removed } = getActualSigs(currentNonPending, filteredNew, false, true);
        console.debug('handlePaste: getActualSigs output:', { added, updated, removed });

        // Process new additions.
        if (added.length > 0) {
          setPendingUndoAdditions(prev => [...prev, ...added]);
          added.forEach((sig: SystemSignature) => {
            console.debug(`handlePaste: Setting pending addition timer for ${sig.eve_id}`);
            const finalTimeoutId = window.setTimeout(() => {
              setSignatures(prev =>
                prev.map(s =>
                  s.eve_id === sig.eve_id ? { ...s, pendingAddition: false, pendingUntil: undefined } : s,
                ),
              );
              setPendingAdditionMap(map => {
                const newMap = { ...map };
                delete newMap[sig.eve_id];
                return newMap;
              });
              setPendingUndoAdditions(prev => prev.filter(x => x.eve_id !== sig.eve_id));
              console.debug(`handlePaste: Finalized pending addition for ${sig.eve_id}`);
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
        }

        // Process removals (lazy deletion).
        if (removed.length > 0) {
          setPendingUndoDeletions(prev => [...prev, ...removed]);
          console.debug('handlePaste: Processing removals:', removed);
          const resp = await outCommand({
            type: OutCommand.updateSignatures,
            data: prepareUpdatePayload(systemId, added, updated, []),
          });
          const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({
            ...s,
          })) as ExtendedSystemSignature[];
          console.debug('handlePaste: Server response (for removals):', castedUpdated);
          scheduleLazyDeletionTimers(
            removed,
            setPendingDeletionMap,
            async (sig: SystemSignature) => {
              console.debug(`handlePaste: Lazy deletion timer fired for ${sig.eve_id}`);
              await outCommand({
                type: OutCommand.updateSignatures,
                data: prepareUpdatePayload(systemId, [], [], [sig]),
              });
              setPendingUndoDeletions(pu => pu.filter(x => x.eve_id !== sig.eve_id));
              // Remove from local state.
              setSignatures(prev => prev.filter(s => s.eve_id !== sig.eve_id));
            },
            FINAL_DURATION_MS,
          );
          const now3 = Date.now();
          const updatedWithRemoval = castedUpdated.map(sig =>
            removed.some((r: SystemSignature) => r.eve_id === sig.eve_id)
              ? { ...sig, pendingDeletion: true, pendingUntil: now3 + FINAL_DURATION_MS }
              : sig,
          );
          const onlyRemoved = removed
            .map((r: SystemSignature) => ({ ...r, pendingDeletion: true, pendingUntil: now3 + FINAL_DURATION_MS }))
            .filter((r: SystemSignature) => !updatedWithRemoval.some(m => m.eve_id === r.eve_id));
          console.debug('handlePaste: Updated signatures with removal flags:', updatedWithRemoval);
          setSignatures([...updatedWithRemoval, ...onlyRemoved]);
        } else {
          const resp = await outCommand({
            type: OutCommand.updateSignatures,
            data: prepareUpdatePayload(systemId, added, updated, []),
          });
          const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({
            ...s,
          })) as ExtendedSystemSignature[];
          console.debug('handlePaste: Server response (no removals):', castedUpdated);
          setSignatures(castedUpdated);
        }
        if (!keepLazyDeleteValue) {
          onLazyDeleteChange?.(false);
        }
      } else {
        console.debug('handlePaste: Running non-lazy branch');
        const existing = signaturesRef.current;
        const newSignatures = parseSignatures(
          clipboardString,
          settings.map(x => x.key),
          existing,
        ).map(s => ({ ...s })) as ExtendedSystemSignature[];
        console.debug('handlePaste: Parsed new signatures (non-lazy):', newSignatures);
        const filteredNew = newSignatures.filter(sig => {
          if (sig.kind === SignatureKind.CosmicSignature && sig.eve_id.length === 3) {
            const prefix = sig.eve_id.substring(0, 3).toUpperCase();
            return !signaturesRef.current.some(
              existingSig =>
                existingSig.kind === SignatureKind.CosmicSignature &&
                existingSig.eve_id.substring(0, 3).toUpperCase() === prefix &&
                existingSig.eve_id.length === 7,
            );
          }
          return true;
        });
        console.debug('handlePaste: Filtered new signatures (non-lazy):', filteredNew);
        handleUpdateSignatures(filteredNew, true);
      }
    },
    [
      settings,
      outCommand,
      systemId,
      signaturesRef,
      setSignatures,
      lazyDeleteValue,
      keepLazyDeleteValue,
      onLazyDeleteChange,
      handleUpdateSignatures,
    ],
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
