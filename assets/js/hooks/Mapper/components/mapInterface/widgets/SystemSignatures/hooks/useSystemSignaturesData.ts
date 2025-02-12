import { useCallback, useEffect, useState } from 'react';
import useRefState from 'react-usestateref';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand, Commands } from '@/hooks/Mapper/types/mapHandlers';
import { SignatureGroup, SystemSignature } from '@/hooks/Mapper/types';
import {
  ExtendedSystemSignature,
  prepareUpdatePayload,
  mergeWithPendingFlags,
  scheduleLazyDeletionTimers,
  FINAL_DURATION_MS,
} from '../helpers/contentHelpers';
import { getActualSigs } from '../helpers';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { parseSignatures } from '@/hooks/Mapper/helpers';
import {
  TIME_ONE_DAY,
  TIME_ONE_WEEK,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants.ts';

export interface UseSystemSignaturesDataProps {
  systemId: string;
  settings: { key: string; value: boolean }[];
  hideLinkedSignatures?: boolean;
  onCountChange: (count: number) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
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
    const lazyDeleteValue = settings.find(s => s.key === 'LAZY_DELETE_SIGNATURES_SETTING')?.value ?? false;
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

  const isSignatureExpired = (signature: SystemSignature, currentTime: number): boolean => {
    if (!signature.inserted_at) return false;
    const insertedTime = new Date(signature.inserted_at).getTime();
    const groupThreshold = signature.group === SignatureGroup.Wormhole ? TIME_ONE_DAY : TIME_ONE_WEEK;
    return currentTime - insertedTime > groupThreshold;
  };

  const getSelectedIds = (selectedSignatures: SystemSignature[]): string[] =>
    selectedSignatures.map(signature => signature.eve_id);

  useEffect(() => {
    const currentTime = Date.now();
    signaturesRef.current.filter(signature => isSignatureExpired(signature, currentTime));
  }, [signaturesRef]);

  const handleDeleteSelected = useCallback(async () => {
    if (selectedSignatures.length === 0) return;
    const selectedIds = getSelectedIds(selectedSignatures);
    await handleUpdateSignatures(
      signatures.filter(signature => !selectedIds.includes(signature.eve_id)),
      false,
      true,
    );
  }, [selectedSignatures, signatures, handleUpdateSignatures]);
  const handleSelectAll = useCallback(() => {
    setSelectedSignatures(signatures);
  }, [signatures]);

  const undoPending = useCallback(() => {
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

  const handlePaste = useCallback(
    async (clipboardString: string) => {
      const parsed = parseSignatures(
        clipboardString,
        settings.map(x => x.key),
      ).map(s => ({ ...s })) as ExtendedSystemSignature[];
      if (parsed.length === 0) return;
      const filteredNew = parsed;
      const currentNonPending = signaturesRef.current.filter(sig => !sig.pendingDeletion && !sig.pendingAddition);
      const { added, updated, removed } = getActualSigs(currentNonPending, filteredNew, false, true);

      if (added.length > 0) {
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
      }

      if (removed.length > 0) {
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
        const now3 = Date.now();
        const updatedWithRemoval = castedUpdated.map(sig =>
          removed.some(r => r.eve_id === sig.eve_id)
            ? { ...sig, pendingDeletion: true, pendingUntil: now3 + FINAL_DURATION_MS }
            : sig,
        );
        const onlyRemoved = removed
          .map(r => ({ ...r, pendingDeletion: true, pendingUntil: now3 + FINAL_DURATION_MS }))
          .filter(r => !updatedWithRemoval.some(m => m.eve_id === r.eve_id));
        setSignatures([...updatedWithRemoval, ...onlyRemoved]);
      } else {
        const resp = await outCommand({
          type: OutCommand.updateSignatures,
          data: prepareUpdatePayload(systemId, added, updated, []),
        });
        const castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
        setSignatures(castedUpdated);
      }
    },
    [settings, outCommand, systemId, signaturesRef, setSignatures],
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
