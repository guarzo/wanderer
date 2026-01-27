import clsx from 'clsx';
import { PrimeIcons } from 'primereact/api';
import { isDocked } from '@/hooks/Mapper/helpers/isDocked.ts';
import classes from './WdCharStateWrapper.module.scss';
import { WithChildren } from '@/hooks/Mapper/types/common.ts';
import { LocationRaw } from '@/hooks/Mapper/types';

type WdCharStateWrapperProps = {
  eve_id: string;
  isExpired?: boolean;
  isMain?: boolean;
  isFollowing?: boolean;
  isReady?: boolean;
  isTrackingPaused?: boolean;
  location: LocationRaw | null;
  isOnline: boolean;
} & WithChildren;

export const WdCharStateWrapper = ({
  location,
  isOnline,
  isMain,
  isFollowing,
  isExpired,
  isReady,
  isTrackingPaused,
  children,
}: WdCharStateWrapperProps) => {
  return (
    <div
      className={clsx(
        'overflow-hidden relative',
        'flex w-[35px] h-[35px] rounded-[4px] border-[1px] border-solid bg-transparent cursor-pointer',
        'transition-colors duration-250 hover:bg-stone-300/90',
        {
          ['border-stone-800/90']: !isExpired && !isOnline && !isReady,
          ['border-lime-600/70']: !isExpired && isOnline && !isReady,
          ['border-orange-500/90']: isReady && isOnline,
          ['border-orange-700/70']: isReady && !isOnline,
          ['border-red-600/70']: isExpired,
        },
      )}
    >
      {isTrackingPaused && (
        <span
          className={clsx(
            'absolute top-0 left-0 w-[35px] h-[35px] flex items-center justify-center',
            'text-yellow-500 text-[9px] z-10 bg-gray-800/40',
            'pi',
            PrimeIcons.PAUSE,
          )}
        />
      )}
      {isMain && (
        <span
          className={clsx(
            'absolute top-[2px] left-[22px] w-[9px] h-[9px]',
            'text-yellow-500 text-[9px] rounded-[1px] z-10',
            'pi',
            PrimeIcons.STAR_FILL,
          )}
        />
      )}
      {isFollowing && (
        <span
          className={clsx(
            'absolute top-[23px] left-[22px] w-[10px] h-[10px]',
            'text-sky-300 text-[10px] rounded-[1px] z-10',
            'pi pi-angle-double-right',
          )}
        />
      )}
      {isReady && (
        <span
          className={clsx(
            'absolute top-[2px] left-[2px] w-[8px] h-[8px] flex items-center justify-center',
            'text-orange-500 text-[8px] rounded-[1px] z-10',
            'pi',
            PrimeIcons.BOLT,
          )}
        />
      )}
      {isDocked(location) && <div className={classes.Docked} />}
      {isExpired && (
        <span
          className={clsx(
            'absolute top-[4px] left-[4px] w-[10px] h-[10px]',
            'text-red-400 text-[10px] rounded-[1px] z-10',
            'pi pi-exclamation-triangle',
          )}
        />
      )}

      {children}
    </div>
  );
};
