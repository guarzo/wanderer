import React, {
  ForwardedRef,
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react';
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

export interface TooltipProps {
  position?: TooltipPosition;
  offset?: number;
  content: (() => React.ReactNode) | React.ReactNode;
  targetSelector?: string;
  interactive?: boolean;
}

export interface OffsetPosition {
  top: number;
  left: number;
}

export interface WdTooltipHandlers {
  show: (e?: React.MouseEvent) => void;
  hide: () => void;
  getIsMouseInside: () => boolean;
}

const LEAVE_DELAY = 100; // ms grace period for interactive tooltips

export const WdTooltip = forwardRef(
  (
    {
      content,
      targetSelector,
      position: tPosition = TooltipPosition.default,
      className,
      offset = 5,
      interactive = false,
    }: TooltipProps & { className?: string },
    ref: ForwardedRef<WdTooltipHandlers>,
  ) => {
    const [visible, setVisible] = useState(false);
    const [pos, setPos] = useState<OffsetPosition | null>(null);
    const tooltipRef = useRef<HTMLDivElement>(null);
    const [isMouseInsideTooltip, setIsMouseInsideTooltip] = useState(false);

    // Store the last React mouse event (if user called show(e)).
    const [reactEvt, setReactEvt] = useState<React.MouseEvent>();

    // For the "leave gap" fix:
    const hideTimeoutRef = useRef<NodeJS.Timeout>();

    const calcTooltipPosition = useCallback(
      ({ x, y }: { x: number; y: number }) => {
        if (!tooltipRef.current) return { left: x, top: y };
        const tooltipWidth = tooltipRef.current.offsetWidth;
        const tooltipHeight = tooltipRef.current.offsetHeight;

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
      },
      [],
    );

    useImperativeHandle(ref, () => ({
      show: (e?: React.MouseEvent) => {
        if (hideTimeoutRef.current) {
          clearTimeout(hideTimeoutRef.current);
          hideTimeoutRef.current = undefined;
        }
        // Immediately set position so there's no "jump" from old location
        if (e && tooltipRef.current) {
          const { clientX, clientY } = e;
          setPos(calcTooltipPosition({ x: clientX, y: clientY }));
          setReactEvt(e);
        }
        setVisible(true);
      },
      hide: () => {
        if (hideTimeoutRef.current) {
          clearTimeout(hideTimeoutRef.current);
        }
        setVisible(false);
      },
      getIsMouseInside: () => isMouseInsideTooltip,
    }));

    // Whenever reactEvt changes, re‐compute position from that event
    // if we're using a manual .show(e).
    useEffect(() => {
      if (!tooltipRef.current || !reactEvt) return;
      const { clientX, clientY, target } = reactEvt;
      const tooltipEl = tooltipRef.current;
      const triggerEl = target as HTMLElement;
      const triggerBounds = triggerEl.getBoundingClientRect();

      let offsetX = clientX;
      let offsetY = clientY;

      if (tPosition === TooltipPosition.left) {
        const tooltipBounds = tooltipEl.getBoundingClientRect();
        offsetX = triggerBounds.left - tooltipBounds.width - offset;
        offsetY = triggerBounds.y + triggerBounds.height / 2 - tooltipBounds.height / 2;
        if (offsetX <= 0) {
          offsetX = triggerBounds.left + triggerBounds.width + offset;
        }
        setPos(calcTooltipPosition({ x: offsetX, y: offsetY }));
        return;
      }
      if (tPosition === TooltipPosition.right) {
        offsetX = triggerBounds.left + triggerBounds.width + offset;
        offsetY = triggerBounds.y + triggerBounds.height / 2 - tooltipEl.offsetHeight / 2;
        setPos(calcTooltipPosition({ x: offsetX, y: offsetY }));
        return;
      }
      if (tPosition === TooltipPosition.top) {
        offsetY = triggerBounds.top - tooltipEl.offsetHeight - offset;
        offsetX = triggerBounds.x + triggerBounds.width / 2 - tooltipEl.offsetWidth / 2;
        setPos(calcTooltipPosition({ x: offsetX, y: offsetY }));
        return;
      }
      if (tPosition === TooltipPosition.bottom) {
        offsetY = triggerBounds.bottom + offset;
        offsetX = triggerBounds.x + triggerBounds.width / 2 - tooltipEl.offsetWidth / 2;
        setPos(calcTooltipPosition({ x: offsetX, y: offsetY }));
        return;
      }

      setPos(calcTooltipPosition({ x: offsetX, y: offsetY }));
    }, [calcTooltipPosition, reactEvt, tPosition, offset]);

    // If targetSelector is given, use the mousemove approach to show/hide automatically
    useEffect(() => {
      if (!targetSelector) return;

      function handleMouseMove(nativeEvt: globalThis.MouseEvent) {
        const targetEl = nativeEvt.target as HTMLElement | null;
        if (!targetEl) {
          scheduleHide();
          return;
        }
        const triggerEl = targetEl.closest(targetSelector);
        const insideTooltip = interactive && tooltipRef.current?.contains(targetEl);

        // If not on the trigger or inside the tooltip:
        if (!triggerEl && !insideTooltip) {
          scheduleHide();
          return;
        }
        // Otherwise, show & track position
        if (hideTimeoutRef.current) {
          clearTimeout(hideTimeoutRef.current);
          hideTimeoutRef.current = undefined;
        }
        setVisible(true);

        if (triggerEl && tooltipRef.current) {
          const rect = triggerEl.getBoundingClientRect();
          const tooltipEl = tooltipRef.current;
          let x = nativeEvt.clientX;
          let y = nativeEvt.clientY;

          if (tPosition === TooltipPosition.left) {
            x = rect.left - tooltipEl.offsetWidth - offset;
            y = rect.y + rect.height / 2 - tooltipEl.offsetHeight / 2;
            if (x <= 0) {
              x = rect.left + rect.width + offset;
            }
          } else if (tPosition === TooltipPosition.right) {
            x = rect.left + rect.width + offset;
            y = rect.y + rect.height / 2 - tooltipEl.offsetHeight / 2;
          } else if (tPosition === TooltipPosition.top) {
            x = rect.x + rect.width / 2 - tooltipEl.offsetWidth / 2;
            y = rect.top - tooltipEl.offsetHeight - offset;
          } else if (tPosition === TooltipPosition.bottom) {
            x = rect.x + rect.width / 2 - tooltipEl.offsetWidth / 2;
            y = rect.bottom + offset;
          }
          setPos(calcTooltipPosition({ x, y }));
        }
      }

      // Use a tiny wrapper for the debounced logic
      const debounced = debounce(handleMouseMove, 15);
      const listener: EventListener = evt => {
        debounced(evt as globalThis.MouseEvent);
      };

      document.addEventListener('mousemove', listener);
      return () => {
        document.removeEventListener('mousemove', listener);
        debounced.cancel();
      };
    }, [targetSelector, interactive, tPosition, offset, calcTooltipPosition]);

    // "interactive" => If user leaves the trigger, we let them move onto the tooltip within LEAVE_DELAY ms
    // otherwise, we hide the tooltip
    function scheduleHide() {
      if (!interactive) {
        setVisible(false);
        return;
      }
      if (!hideTimeoutRef.current) {
        hideTimeoutRef.current = setTimeout(() => {
          setVisible(false);
        }, LEAVE_DELAY);
      }
    }

    // Clean up any pending hide timeouts on unmount
    useEffect(() => {
      return () => {
        if (hideTimeoutRef.current) clearTimeout(hideTimeoutRef.current);
      };
    }, []);

    return createPortal(
      visible && (
        <div
          ref={tooltipRef}
          className={clsx(
            classes.tooltip,
            // For interactive tooltips, pointer events are allowed
            interactive ? 'pointer-events-auto' : 'pointer-events-none',
            'absolute p-1 border rounded-sm border-green-300 border-opacity-10 bg-stone-900 bg-opacity-90',
            // If we haven't computed position yet, we can hide visually to avoid flicker
            pos === null ? 'invisible' : '',
            className
          )}
          style={{
            top: pos?.top ?? 0,
            left: pos?.left ?? 0,
            zIndex: 10000,
          }}
          onMouseEnter={() => {
            // If user is entering the tooltip container, cancel any scheduled hide
            if (interactive && hideTimeoutRef.current) {
              clearTimeout(hideTimeoutRef.current);
              hideTimeoutRef.current = undefined;
            }
            setIsMouseInsideTooltip(true);
          }}
          onMouseLeave={() => {
            setIsMouseInsideTooltip(false);
            if (interactive) {
              scheduleHide();
            }
          }}
        >
          {typeof content === 'function' ? content() : content}
        </div>
      ),
      document.body,
    );
  },
);

WdTooltip.displayName = 'WdTooltip';
