/* eslint-disable react/prop-types */
import React, { ForwardedRef, forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import clsx from 'clsx';
import debounce from 'lodash.debounce';

import classes from './WdTooltip.module.scss';

export enum TooltipPosition {
  default = 'default',
  left = 'left',
  right = 'right',
  top = 'top',
  bottom = 'bottom',
}

export interface OffsetPosition {
  top: number;
  left: number;
}

export interface WdTooltipHandlers {
  show: (e?: MouseEvent) => void;
  hide: (e?: MouseEvent) => void;
  getTooltipElement?: () => HTMLDivElement | null;
}

export interface WdTooltipProps {
  className?: string;
  targetSelector?: string;
  interactive?: boolean;
  content: React.ReactNode | (() => React.ReactNode);
  position?: TooltipPosition;
  offset?: number;
}

export const WdTooltip = forwardRef(function WdTooltip(
  {
    className,
    targetSelector,
    interactive = false,
    content,
    position: tPosition = TooltipPosition.default,
    offset = 5,
  }: WdTooltipProps,
  ref: ForwardedRef<WdTooltipHandlers>,
) {
  const [visible, setVisible] = useState(false);
  const [pos, setPos] = useState<OffsetPosition | null>(null);

  const [mouseEvent, setMouseEvent] = useState<MouseEvent | null>(null);

  const tooltipRef = useRef<HTMLDivElement>(null);

  const calcPosition = useCallback((x: number, y: number, tooltipEl: HTMLDivElement) => {
    const tooltipWidth = tooltipEl.offsetWidth;
    const tooltipHeight = tooltipEl.offsetHeight;

    let newLeft = x;
    let newTop = y;

    if (newLeft < 0) newLeft = 10;
    if (newTop < 0) newTop = 10;
    if (newLeft + tooltipWidth + 10 > window.innerWidth) {
      newLeft = window.innerWidth - tooltipWidth - 10;
    }
    if (newTop + tooltipHeight + 10 > window.innerHeight) {
      newTop = window.innerHeight - tooltipHeight - 10;
    }

    return { left: newLeft, top: newTop };
  }, []);

  const handleMouseMove = useCallback(
    (e: MouseEvent) => {
      if (!targetSelector) return;

      const el = e.target as HTMLElement | null;
      if (!el) {
        setVisible(false);
        return;
      }

      const isTrigger = !!el.closest(targetSelector);
      const isTooltip = tooltipRef.current?.contains(el);
      if (!isTrigger && !isTooltip) {
        setVisible(false);
        return;
      }
      if (isTrigger) {
        setMouseEvent(e);
      }

      setVisible(true);
    },
    [targetSelector],
  );

  const debouncedMouseMove = debounce(handleMouseMove, 10);

  useEffect(() => {
    if (!targetSelector) return;

    document.addEventListener('mousemove', debouncedMouseMove);
    return () => {
      document.removeEventListener('mousemove', debouncedMouseMove);
    };
  }, [targetSelector, debouncedMouseMove]);

  useEffect(() => {
    if (!mouseEvent || !tooltipRef.current) return;

    const targetEl = mouseEvent.target as HTMLElement;
    const tooltipEl = tooltipRef.current;
    const rect = targetEl.getBoundingClientRect();

    let newPos: OffsetPosition;
    let x = mouseEvent.clientX;
    let y = mouseEvent.clientY;

    if (tPosition === TooltipPosition.top) {
      const tooltipHeight = tooltipEl.offsetHeight;
      const tooltipWidth = tooltipEl.offsetWidth;
      x = rect.x + rect.width / 2 - tooltipWidth / 2;
      y = rect.y - tooltipHeight - offset; // offset from top
    } else if (tPosition === TooltipPosition.left) {
      const tooltipWidth = tooltipEl.offsetWidth;
      const tooltipHeight = tooltipEl.offsetHeight;
      x = rect.left - tooltipWidth - offset;
      y = rect.y + rect.height / 2 - tooltipHeight / 2;
    } else if (tPosition === TooltipPosition.right) {
      const tooltipHeight = tooltipEl.offsetHeight;
      x = rect.right + offset;
      y = rect.y + rect.height / 2 - tooltipHeight / 2;
    } else if (tPosition === TooltipPosition.bottom) {
      const tooltipWidth = tooltipEl.offsetWidth;
      x = rect.x + rect.width / 2 - tooltipWidth / 2;
      y = rect.bottom + offset;
    } else {
      x += 10;
      y += 10;
    }

    newPos = calcPosition(x, y, tooltipEl);
    setPos(newPos);
  }, [mouseEvent, tPosition, offset, calcPosition]);

  useImperativeHandle(ref, () => ({
    show: () => setVisible(true),
    hide: () => setVisible(false),
    getTooltipElement: () => tooltipRef.current,
  }));

  return createPortal(
    visible && (
      <div
        ref={tooltipRef}
        className={clsx(
          classes.tooltip,
          !interactive && 'pointer-events-none',
          interactive && 'pointer-events-auto',
          'absolute px-2 py-2 border rounded border-green-300 border-opacity-10 bg-stone-900 bg-opacity-90',
          className,
        )}
        style={{
          top: pos?.top ?? 0,
          left: pos?.left ?? 0,
          zIndex: 10000,
        }}
      >
        {typeof content === 'function' ? content() : content}
      </div>
    ),
    document.body,
  );
});
