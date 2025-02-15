import clsx from 'clsx';
import { ExtendedSystemSignature } from './contentHelpers';
import { getRowBackgroundColor } from './getRowBackgroundColor';
import classes from './rowStyles.module.scss';

export function getSignatureRowClass(
  row: ExtendedSystemSignature,
  selectedSignatures: ExtendedSystemSignature[],
  isCompact: boolean,
): string {
  const isSelected = selectedSignatures.some(s => s.eve_id === row.eve_id);
  const selectionClass = isSelected ? 'bg-amber-500/50 hover:bg-amber-500/70 transition duration-200' : '';

  const pendingClass = !isSelected && row.pendingDeletion ? classes.pendingDeletion : '';

  const backgroundClass =
    !isSelected && isCompact ? getRowBackgroundColor(row.inserted_at ? new Date(row.inserted_at) : undefined) : '';

  const hoverClass = 'hover:bg-purple-400/20 transition duration-200';

  return clsx(
    isCompact ? classes.TableRowCompact : '',
    'p-selectable-row',
    selectionClass,
    pendingClass,
    backgroundClass,
    hoverClass,
  );
}
