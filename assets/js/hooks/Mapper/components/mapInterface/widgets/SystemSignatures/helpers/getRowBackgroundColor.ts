import {
  TIME_ONE_MINUTE,
  TIME_TEN_MINUTES,
} from '@/hooks/Mapper/components/mapInterface/widgets/SystemSignatures/constants.ts';

export const getRowBackgroundColor = (date: Date | undefined, now: number = Date.now()): string => {
  if (!date) {
    return '';
  }

  const diff = now - date.getTime();

  if (diff < TIME_ONE_MINUTE) {
    return '[&_.ssc-header]:text-amber-300 [&_.ssc-header]:hover:text-amber-200 [&_.ssc-header]:font-bold';
  }

  if (diff < TIME_TEN_MINUTES) {
    return '[&_.ssc-header]:text-amber-500 [&_.ssc-header]:hover:text-amber-500 [&_.ssc-header]:font-bold';
  }

  return '';
};
