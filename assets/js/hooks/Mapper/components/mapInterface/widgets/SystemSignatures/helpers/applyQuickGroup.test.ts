import { SignatureGroup, SignatureKind, SystemSignature } from '@/hooks/Mapper/types';
import { applyQuickGroup } from './applyQuickGroup';

const baseSig: SystemSignature = {
  eve_id: 'ABC-123',
  kind: SignatureKind.CosmicSignature,
  name: 'Some Site',
  group: SignatureGroup.CosmicSignature,
  type: '',
};

describe('applyQuickGroup', () => {
  it('should only set group for a plain unidentified signature', () => {
    const { signature, needsUnlink } = applyQuickGroup(baseSig, SignatureGroup.GasSite);

    expect(needsUnlink).toBe(false);
    expect(signature.group).toBe(SignatureGroup.GasSite);
    expect(signature.name).toBe('Some Site');
    expect(signature.type).toBe('');
  });

  it('should clear name and type when resetting to Cosmic Signature', () => {
    const sig = { ...baseSig, group: SignatureGroup.RelicSite, name: 'Sandbox', type: 'Relic' };
    const { signature, needsUnlink } = applyQuickGroup(sig, SignatureGroup.CosmicSignature);

    expect(needsUnlink).toBe(false);
    expect(signature.group).toBe(SignatureGroup.CosmicSignature);
    expect(signature.name).toBe('');
    expect(signature.type).toBe('');
  });

  it('should clear name when changing a non-wormhole signature to Wormhole', () => {
    const sig = { ...baseSig, group: SignatureGroup.CombatSite, name: 'Fort', description: 'note' };
    const { signature, needsUnlink } = applyQuickGroup(sig, SignatureGroup.Wormhole);

    expect(needsUnlink).toBe(false);
    expect(signature.group).toBe(SignatureGroup.Wormhole);
    expect(signature.name).toBe('');
    expect(signature.description).toBe('note');
  });

  it('should not clear name when the signature is already a Wormhole', () => {
    const sig = { ...baseSig, group: SignatureGroup.Wormhole, name: '', type: 'C3' };
    const { signature, needsUnlink } = applyQuickGroup(sig, SignatureGroup.Wormhole);

    expect(needsUnlink).toBe(false);
    expect(signature.name).toBe('');
    expect(signature.type).toBe('C3');
  });

  it('should require unlink when a linked wormhole changes to another group', () => {
    const sig = { ...baseSig, group: SignatureGroup.Wormhole, type: 'C3', linked_system: { solar_system_id: 123 } as any };
    const { signature, needsUnlink } = applyQuickGroup(sig, SignatureGroup.DataSite);

    expect(needsUnlink).toBe(true);
    expect(signature.group).toBe(SignatureGroup.DataSite);
    expect(signature.type).toBe('');
  });

  it('should clear type but not require unlink when an unlinked wormhole changes to another group', () => {
    const sig = { ...baseSig, group: SignatureGroup.Wormhole, type: 'C3' };
    const { signature, needsUnlink } = applyQuickGroup(sig, SignatureGroup.OreSite);

    expect(needsUnlink).toBe(false);
    expect(signature.group).toBe(SignatureGroup.OreSite);
    expect(signature.type).toBe('');
  });

  it('should not mutate the original signature', () => {
    const sig = { ...baseSig, name: 'Keep me' };
    applyQuickGroup(sig, SignatureGroup.CombatSite);

    expect(sig.name).toBe('Keep me');
    expect(sig.group).toBe(SignatureGroup.CosmicSignature);
  });
});
