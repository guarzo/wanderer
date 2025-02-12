import { useCallback, useEffect, useState } from 'react';
import useRefState from 'react-usestateref';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { Commands, OutCommand } from '@/hooks/Mapper/types/mapHandlers';
import { SignatureKind, SystemSignature, SignatureGroup } from '@/hooks/Mapper/types';
import {
  ExtendedSystemSignature,
  FINAL_DURATION_MS,
  mergeWithPendingFlags,
  prepareUpdatePayload,
  scheduleLazyDeletionTimers,
} from '../helpers/contentHelpers';
import { getActualSigs } from '../helpers';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { parseSignatures, parseBookmarkFormatSignatures } from '../helpers/parseSignatures.ts';
import { TIME_ONE_DAY, TIME_ONE_WEEK } from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants';
import { LAZY_DELETE_SIGNATURES_SETTING, BOOKMARK_PASTE_SETTING } from '@/hooks/Mapper/components/mapInterface/widgets';

export interface UseSystemSignaturesDataProps {
  systemId: string;
  settings: { key: string; value: boolean }[];
  hideLinkedSignatures?: boolean;
  onCountChange: (count: number) => void;
  onPendingChange?: (pending: ExtendedSystemSignature[], undo: () => void) => void;
  onBookmarkPasteComplete?: () => void; // callback to uncheck bookmark paste after paste
}

/**
 * Updated filter: For any signature whose eve_id is shorter than 7 characters,
 * if there is any other signature whose ID is longer and starts with the same prefix,
 * then filter out the shorter version.
 */
function filterShortSignatures(sigs: ExtendedSystemSignature[]): ExtendedSystemSignature[] {
  console.debug('[filterShortSignatures] Starting with', sigs.length, 'signatures.');
  const filtered = sigs.filter(sig => {
    if (sig.eve_id.length < 7) {
      const prefix = sig.eve_id.toUpperCase();
      const found = sigs.some(
        other =>
          other.eve_id.length > sig.eve_id.length &&
          other.eve_id.substring(0, sig.eve_id.length).toUpperCase() === prefix,
      );
      if (found) {
        console.debug(`[filterShortSignatures] Filtering out short signature: ${sig.eve_id}`);
        return false;
      }
    }
    return true;
  });
  console.debug('[filterShortSignatures] Filtered down to', filtered.length, 'signatures.');
  return filtered;
}

/**
 * Merges incoming signatures with existing (non‑deleted) signatures.
 * For an incoming signature with a full (7+ character) ID, if no exact match is found,
 * then look for an existing signature whose ID equals the first few characters.
 * If such an existing signature is found and its kind isn’t the default (CosmicSignature),
 * then preserve its kind and name.
 */
function mergeIncomingSignatures(
  incoming: ExtendedSystemSignature[],
  currentForMerge: ExtendedSystemSignature[],
): ExtendedSystemSignature[] {
  console.debug('[mergeIncomingSignatures] Incoming signatures count:', incoming.length);
  return incoming.map(newSig => {
    let existingSig = currentForMerge.find(sig => sig.eve_id === newSig.eve_id);
    if (!existingSig && newSig.eve_id.length >= 7) {
      const prefix = newSig.eve_id.substring(0, 3);
      existingSig = currentForMerge.find(sig => sig.eve_id === prefix);
      if (existingSig) {
        console.debug(
          `[mergeIncomingSignatures] Found pending/old signature with short id "${existingSig.eve_id}" matching incoming "${newSig.eve_id}".`,
        );
      }
    }
    if (existingSig && existingSig.kind && existingSig.kind !== SignatureKind.CosmicSignature) {
      console.debug(
        `[mergeIncomingSignatures] Merging incoming "${newSig.eve_id}" with existing "${existingSig.eve_id}" preserving kind "${existingSig.kind}" and name "${existingSig.name}".`,
      );
      return { ...newSig, kind: existingSig.kind, name: existingSig.name };
    }
    return newSig;
  });
}

export function useSystemSignaturesData({
  systemId,
  settings,
  onCountChange,
  onPendingChange,
  onBookmarkPasteComplete,
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
    console.debug('[handleGetSignatures] Requesting signatures for system', systemId);
    const { signatures: serverSignatures } = await outCommand({
      type: OutCommand.getSignatures,
      data: { system_id: systemId },
    });
    let extendedServer = (serverSignatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
    const lazyDeleteValue = settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)?.value ?? false;
    if (lazyDeleteValue) {
      extendedServer = mergeWithPendingFlags(extendedServer, signaturesRef.current);
    }
    console.debug('[handleGetSignatures] Received', extendedServer.length, 'signatures from server.');
    setSignatures(filterShortSignatures(extendedServer));
  }, [systemId, outCommand, settings, signaturesRef, setSignatures]);

  const handleUpdateSignatures = useCallback(
    async (newSignatures: ExtendedSystemSignature[], updateOnly: boolean, skipUpdateUntouched?: boolean) => {
      console.debug('[handleUpdateSignatures] Updating signatures with', newSignatures.length, 'new signatures.');
      const { added, updated, removed } = getActualSigs(
        signaturesRef.current,
        newSignatures,
        updateOnly,
        skipUpdateUntouched,
      );
      console.debug(
        '[handleUpdateSignatures] Changes - Added:',
        added.length,
        ', Updated:',
        updated.length,
        ', Removed:',
        removed.length,
      );
      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, removed),
      });
      let castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      castedUpdated = filterShortSignatures(castedUpdated);
      console.debug('[handleUpdateSignatures] Updated server signatures count after filtering:', castedUpdated.length);
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
    console.debug('[handleDeleteSelected] Deleting signatures with IDs:', selectedIds);
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
    console.debug('[undoPending] Clearing pending timers and resetting pending flags.');
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
        console.error('[undoPending] Error undoing pending additions', err);
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

  const processAddedSignatures = useCallback(
    (added: ExtendedSystemSignature[]) => {
      console.debug('[processAddedSignatures] Processing', added.length, 'added signatures.');
      if (added.length === 0) return;
      setPendingUndoAdditions(prev => [...prev, ...added]);
      added.forEach((sig: SystemSignature) => {
        console.debug('[processAddedSignatures] Scheduling pending addition for', sig.eve_id);
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
          console.debug('[processAddedSignatures] Pending addition cleared for', sig.eve_id);
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

  const processRemovedSignatures = useCallback(
    async (
      removed: ExtendedSystemSignature[],
      added: ExtendedSystemSignature[],
      updated: ExtendedSystemSignature[],
    ) => {
      console.debug('[processRemovedSignatures] Processing', removed.length, 'removed signatures.');
      if (removed.length === 0) return;
      setPendingUndoDeletions(prev => [...prev, ...removed]);
      const resp = await outCommand({
        type: OutCommand.updateSignatures,
        data: prepareUpdatePayload(systemId, added, updated, []),
      });
      let castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
      castedUpdated = filterShortSignatures(castedUpdated);
      console.debug('[processRemovedSignatures] Updated signature count after filtering:', castedUpdated.length);
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
          console.debug('[processRemovedSignatures] Removed signature', sig.eve_id);
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

  const handlePaste = useCallback(
    async (clipboardString: string) => {
      console.debug('[handlePaste] Clipboard content:', clipboardString);
      const bookmarkPasteSetting = settings.find(s => s.key === BOOKMARK_PASTE_SETTING)?.value;
      let incomingSignatures: ExtendedSystemSignature[];
      if (bookmarkPasteSetting) {
        console.debug('[handlePaste] Using bookmark parser.');
        incomingSignatures = parseBookmarkFormatSignatures(
          clipboardString,
          settings.map(x => x.key),
        );
      } else {
        console.debug('[handlePaste] Using normal parser.');
        incomingSignatures = parseSignatures(
          clipboardString,
          settings.map(x => x.key),
        )
          .map(s => ({ ...s }))
          .filter(Boolean) as ExtendedSystemSignature[];
      }
      incomingSignatures = incomingSignatures.filter(sig => typeof sig === 'object' && sig !== null);
      console.debug('[handlePaste] Parsed incoming signatures count:', incomingSignatures.length);

      // Include pending additions (do not filter them out) so that merging works.
      const currentForMerge = signaturesRef.current.filter(sig => !sig.pendingDeletion);
      console.debug('[handlePaste] Current signatures count for merging:', currentForMerge.length);
      const mergedIncoming = mergeIncomingSignatures(incomingSignatures, currentForMerge);
      console.debug('[handlePaste] Merged incoming signatures count:', mergedIncoming.length);
      const mergedIncomingSignatures = mergeWithPendingFlags(mergedIncoming, currentForMerge);
      console.debug('[handlePaste] Final merged incoming signatures count:', mergedIncomingSignatures.length);
      const { added, updated, removed } = getActualSigs(currentForMerge, mergedIncomingSignatures, false, true);
      console.debug(
        '[handlePaste] getActualSigs results - Added:',
        added.length,
        ', Updated:',
        updated.length,
        ', Removed:',
        removed.length,
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
        let castedUpdated = (resp.signatures as SystemSignature[]).map(s => ({ ...s })) as ExtendedSystemSignature[];
        castedUpdated = filterShortSignatures(castedUpdated);
        console.debug('[handlePaste] Updated signatures count from server after paste:', castedUpdated.length);
        setSignatures(castedUpdated);
      }

      // Uncheck bookmark paste after a successful paste.
      if (bookmarkPasteSetting && onBookmarkPasteComplete) {
        console.debug('[handlePaste] Calling onBookmarkPasteComplete callback.');
        onBookmarkPasteComplete();
      }
    },
    [
      settings,
      outCommand,
      systemId,
      signaturesRef,
      setSignatures,
      processAddedSignatures,
      processRemovedSignatures,
      onBookmarkPasteComplete,
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
