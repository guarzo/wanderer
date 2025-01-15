import { useState, useRef } from 'react';
import { createPortal } from 'react-dom';
import { usePopper } from 'react-popper';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';
import clsx from 'clsx';
import he from 'he';

interface LocalCounterProps {
  charactersInSystem: Array<CharacterTypeRaw>;
  hasUserCharacters: boolean;
  // tooltipLeft: number;       <-- no longer needed
  // tooltipTop: number;        <-- no longer needed
  sortedCharacters: Array<CharacterTypeRaw>;
  classes: { [key: string]: string };
}

export function LocalCounter({ charactersInSystem, hasUserCharacters, sortedCharacters, classes }: LocalCounterProps) {
  const [showTooltip, setShowTooltip] = useState(false);

  // This ref is our "reference element" for Popper:
  const localCounterRef = useRef<HTMLDivElement | null>(null);

  // React Popper uses two elements: the referenceElement & the popper element.
  const [popperElement, setPopperElement] = useState<HTMLDivElement | null>(null);

  // (Optional) If you need an arrow, track it here:
  const [arrowElement, setArrowElement] = useState<HTMLDivElement | null>(null);

  // Call the hook.
  // By default, it will place the tooltip at the "bottom" of the reference element.
  // Adjust placement, modifiers, etc. if you want a different position or offset.
  const { styles, attributes } = usePopper(localCounterRef.current, popperElement, {
    placement: 'right',
    modifiers: [
      { name: 'offset', options: { offset: [0, 0] } },
      { name: 'arrow', options: { element: arrowElement } },
    ],
  });

  const pilotTooltipJSX = (
    <div className={classes.NodeTooltipInner}>
      <div className={classes.nodePilotListTooltip}>
        <div className={classes.tooltipHeader}>Pilots</div>
        <div className={classes.TooltipBody}>
          {sortedCharacters.map(char => (
            <div key={char.eve_id} className={classes.tooltipRow}>
              <span className={classes.tooltipCharacterName}>{char.name}</span>
              {char.ship && (
                <>
                  <span className={classes.tooltipShipName}>{he.decode(char.ship.ship_name)}</span>
                  <span className={classes.tooltipShipType}>{char.ship.ship_type_info.name}</span>
                </>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );

  return (
    <>
      {charactersInSystem.length > 0 && (
        <div className={classes.LocalCounterLayer} style={{ zIndex: 9999 }}>
          <div
            ref={localCounterRef}
            onMouseEnter={() => setShowTooltip(true)}
            onMouseLeave={() => setShowTooltip(false)}
            className={clsx(classes.localCounter, {
              [classes.hasUserCharacters]: hasUserCharacters,
            })}
          >
            <span>{charactersInSystem.length}</span>
          </div>
        </div>
      )}

      {showTooltip &&
        createPortal(
          <div
            ref={setPopperElement}
            className={classes.NodeToolTip}
            style={styles.popper} // Let Popper compute x/y
            {...attributes.popper} // Spread additional popper positioning attributes
          >
            {pilotTooltipJSX}

            {/* If you want an arrow, place it here */}
            <div ref={setArrowElement} style={styles.arrow} className={classes.TooltipArrow} {...attributes.arrow} />
          </div>,
          document.body,
        )}
    </>
  );
}
