import { SignatureGroup, SystemSignature } from '@/hooks/Mapper/types';

export interface QuickGroupResult {
  signature: SystemSignature;
  /** True when the signature was a linked wormhole and must be unlinked before updating its group. */
  needsUnlink: boolean;
}

// Mirrors the group-change rules of the SignatureSettings dialog for a bare group switch
// (linking, wormhole types and mass states stay dialog-only).
export const applyQuickGroup = (sig: SystemSignature, group: SignatureGroup): QuickGroupResult => {
  let out: SystemSignature = { ...sig, group };
  let needsUnlink = false;

  if (group === SignatureGroup.CosmicSignature) {
    out = { ...out, type: '', name: '' };
  }

  if (group === SignatureGroup.Wormhole && sig.group !== SignatureGroup.Wormhole) {
    out = { ...out, name: '' };
  }

  if (sig.group === SignatureGroup.Wormhole && group !== SignatureGroup.Wormhole) {
    needsUnlink = !!sig.linked_system;
    out = { ...out, type: '' };
  }

  return { signature: out, needsUnlink };
};
