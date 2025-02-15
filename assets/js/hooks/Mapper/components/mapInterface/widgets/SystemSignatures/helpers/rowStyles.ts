import clsx from 'clsx';
import { ExtendedSystemSignature } from './contentHelpers';
import { getRowBackgroundColor } from './getRowBackgroundColor';
import classes from './rowStyles.module.scss';

export function getSignatureRowClass(
  row: ExtendedSystemSignature,
  selectedSignatures: ExtendedSystemSignature[],
): string {
  const isSelected = selectedSignatures.some(s => s.eve_id === row.eve_id);
  const isPending = !!row.pendingDeletion;
  const greenClass = !isPending ? getRowBackgroundColor(row.inserted_at ? new Date(row.inserted_at) : undefined) : '';
  const hoverClass = !isPending ? 'hover:bg-purple-400/20 transition duration-200' : '';

  return clsx(
    classes.TableRowCompact,
    'p-selectable-row',
    {
      ['p-highlight']: false,
      ['bg-amber-500/50 hover:bg-amber-500/70 transition duration-200']: isSelected && !isPending,
    },
    { [classes.pendingDeletion]: isPending },
    greenClass,
    hoverClass,
  );
}
