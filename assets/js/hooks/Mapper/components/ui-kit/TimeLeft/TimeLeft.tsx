import { FC, useState, useEffect, useRef } from 'react';

const calibratedDate = new Date('Mon, 01 Jan 2024 00:00:00 GMT');

interface TimeLeftProps {
  cDate?: Date;
}

export const TimeLeft: FC<TimeLeftProps> = ({ cDate = new Date() }) => {
  const [date, setDate] = useState<Date>(cDate);
  const [timeDiff, setTimeDiff] = useState<string>('');
  const timerId = useRef<number | undefined>(undefined);

  useEffect(() => {
    update();
    startTimer();

    return () => {
      if (timerId.current !== undefined) {
        clearTimeout(timerId.current);
      }
    };
  }, [date]);

  const startTimer = () => {
    timerId.current = window.setTimeout(() => {
      update();
      startTimer();
    }, 1000);
  };

  const update = () => {
    const currentDate = new Date();
    // No timezone correction: `cDate` is built from a timestamp that names its
    // own zone, so it is already a real instant. This used to add
    // `getTimezoneOffset()` to compensate for signature timestamps arriving as
    // zone-less UTC that `new Date` read as local time; the server now sends
    // ISO-8601 and correcting again would reintroduce the same error, inverted.
    const diff = currentDate.getTime() - date.getTime();
    setTimeDiff(calculateTimeDiff(diff));
  };

  const calculateTimeDiff = (_milliseconds: number) => {
    const relativeDate = new Date(calibratedDate.getTime() + _milliseconds);
    const seconds = relativeDate.getUTCSeconds().toString().padStart(2, '0');
    const minutes = relativeDate.getUTCMinutes().toString().padStart(2, '0');
    const hours = relativeDate.getUTCHours().toString().padStart(2, '0');
    const days = (relativeDate.getUTCDate() - 1).toString();

    return `${days} ${hours}:${minutes}:${seconds}`;
  };

  useEffect(() => {
    setDate(cDate);
    update();
  }, [cDate]);

  return <span className="whitespace-nowrap">{timeDiff}</span>;
};
