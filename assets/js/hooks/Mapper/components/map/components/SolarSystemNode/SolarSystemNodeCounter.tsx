import { useState, useRef } from 'react';
import { createPortal } from 'react-dom';
import { CharacterTypeRaw } from '@/hooks/Mapper/types';
import clsx from 'clsx';

// If you're using TypeScript, define some minimal prop types:
interface LocalCounterProps {
  charactersInSystem: Array<CharacterTypeRaw>;
  hasUserCharacters: boolean;
  tooltipLeft: number;
  tooltipTop: number;
  sortedCharacters: Array<CharacterTypeRaw>; // or your own type
  classes: { [key: string]: string };
}

export function LocalCounter({
  charactersInSystem,
  hasUserCharacters,
  tooltipLeft,
  tooltipTop,
  sortedCharacters,
  classes,
}: LocalCounterProps) {
  const [showTooltip, setShowTooltip] = useState(false);
  const localCounterRef = useRef<HTMLDivElement | null>(null);

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
                  <span className={classes.tooltipShipName}>{char.ship.ship_name}</span>
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
            <span className="font-sans">{charactersInSystem.length}</span>
          </div>
        </div>
      )}

      {showTooltip &&
        createPortal(
          <div
            className={classes.NodeToolTip}
            style={{
              position: 'absolute',
              left: tooltipLeft,
              top: tooltipTop,
              pointerEvents: 'none',
            }}
          >
            {pilotTooltipJSX}
          </div>,
          document.body,
        )}
    </>
  );
}
