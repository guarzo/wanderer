import { memo } from 'react';
import { MapSolarSystemType } from '../../map.types';
import { Handle, Position, NodeProps, useReactFlow } from 'reactflow';
import clsx from 'clsx';
import classes from './SolarSystemNodeZoo.module.scss';
import { PrimeIcons } from 'primereact/api';
import { GiPortal } from 'react-icons/gi';
import { useSolarSystemNode, useLocalCounter } from '../../hooks/useSolarSystemLogic';
import { useZooNames, useZooLabels, useGetSignatures, useSignatureAge } from '../../hooks/useZooLogic';
import {
  MARKER_BOOKMARK_BG_STYLES,
  STATUS_CLASSES,
  EFFECT_BACKGROUND_STYLES,
} from '@/hooks/Mapper/components/map/constants';
import { WormholeClassComp } from '@/hooks/Mapper/components/map/components/WormholeClassComp';
import { KillsCounter } from './SolarSystemKillsCounter';
import { LocalCounter } from './SolarSystemLocalCounter';
import { LABEL_ICON_MAP } from '@/hooks/Mapper/components/map/constants';

export const SolarSystemNodeZoo = memo((props: NodeProps<MapSolarSystemType>) => {
  const nodeVars = useSolarSystemNode(props);
  const updatedSignatures = useGetSignatures(nodeVars.solarSystemId);
  nodeVars.systemSigs = updatedSignatures;

  const { getEdges } = useReactFlow();
  const edges = getEdges();
  const connectionCount = edges.filter(edge => edge.source === props.id || edge.target === props.id).length;

  const showHandlers = nodeVars.isConnecting || nodeVars.hoverNodeId === nodeVars.id;
  const dropHandler = nodeVars.isConnecting ? 'all' : 'none';

  const { unsplashedCount, hasEol, hasGas, hasCrit } = useZooLabels(connectionCount, {
    unsplashedLeft: nodeVars.unsplashedLeft,
    unsplashedRight: nodeVars.unsplashedRight,
    systemSigs: nodeVars.systemSigs,
    labelInfo: nodeVars.labelsInfo,
  });

  const { systemName, customLabel, customName } = useZooNames(
    {
      temporaryName: nodeVars.temporaryName,
      solarSystemName: nodeVars.solarSystemName,
      regionName: nodeVars.regionName,
      labelCustom: nodeVars.labelCustom,
      ownerTicker: nodeVars.ownerTicker,
      isWormhole: nodeVars.isWormhole,
    },
    props,
  );

  const { localCounterCharacters } = useLocalCounter(nodeVars);

  const { signatureAgeHours, bookmarkColor } = useSignatureAge(nodeVars.systemSigs);

  return (
    <>
      {nodeVars.visible && (
        <div className={classes.Bookmarks}>
          {customLabel !== '' && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.custom)}>
              {nodeVars.ownerURL && nodeVars.ownerTicker ? (
                <a
                  href={nodeVars.ownerURL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)]"
                >
                  {customLabel}
                </a>
              ) : (
                <span className="[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)] ">{customLabel}</span>
              )}
            </div>
          )}

          {nodeVars.killsCount && nodeVars.killsCount > 0 && nodeVars.solarSystemId && (
            <KillsCounter
              killsCount={nodeVars.killsCount}
              systemId={nodeVars.solarSystemId}
              size="lg"
              killsActivityType={nodeVars.killsActivityType}
              className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES[nodeVars.killsActivityType!])}
            >
              <div className={clsx(classes.BookmarkWithIcon)}>
                <span className={clsx(PrimeIcons.BOLT, classes.icon)} />
                <span className={clsx(classes.text)}>{nodeVars.killsCount}</span>
              </div>
            </KillsCounter>
          )}

          {unsplashedCount > 0 && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.unSplashed)} style={{ display: 'flex' }}>
              <GiPortal
                size={8} // Increased size for better visibility
                color="#38bdf8"
                style={{
                  marginRight: '2px',
                  filter: 'drop-shadow(1px 1px 1px rgba(0, 0, 0, 0.25))',
                }}
              />
              <span
                style={{
                  marginTop: '1px',
                  color: '#38bdf8',
                  fontSize: '8px', // Adjusted font size
                  lineHeight: '8px', // Ensure the line height is enough for the text
                }}
              >
                {unsplashedCount}
              </span>
            </div>
          )}

          {hasEol && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.eol)}>
              <span className={clsx('pi pi-stopwatch', classes.icon)} />
            </div>
          )}

          {hasGas && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.gas)}>
              <span className={clsx('pi pi-cloud', classes.icon)} style={{ color: 'black', fontSize: '8px' }} />
            </div>
          )}

          {hasCrit && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.crit)}>
              <span className={clsx('pi pi-info-circle', classes.icon)} />
            </div>
          )}

          {nodeVars.systemSigs.length > 0 && signatureAgeHours >= 0 && (
            <div className={clsx(classes.Bookmark)} style={{ backgroundColor: bookmarkColor }}>
              <span
                className={clsx(classes.text)}
                style={{
                  color: '#FFFFFF',
                  fontSize: '8px',
                  marginLeft: '1px',
                  marginRight: '1px',
                  display: 'flex',
                  justifyContent: 'center',
                  alignItems: 'center',
                  marginTop: '-1px',
                }}
              >
                {signatureAgeHours}h
              </span>
            </div>
          )}

          {nodeVars.labelsInfo.map(x => (
            <div key={x.id} className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES[x.id])}>
              {LABEL_ICON_MAP[x.id] ? (
                <i
                  className={clsx(`pi ${LABEL_ICON_MAP[x.id].icon} ${LABEL_ICON_MAP[x.id].colorClass}`, classes.icon)}
                />
              ) : (
                x.shortName
              )}
            </div>
          ))}
        </div>
      )}

      <div
        className={clsx(
          classes.RootCustomNode,
          nodeVars.regionClass && classes[nodeVars.regionClass],
          nodeVars.status != null ? classes[STATUS_CLASSES[nodeVars.status]] : null,
          {
            [classes.selected]: nodeVars.selected,
          },
        )}
        onMouseDownCapture={e => nodeVars.dbClick(e)}
      >
        {nodeVars.visible && (
          <>
            <div className={classes.HeadRow}>
              <div
                className={clsx(
                  classes.classTitle,
                  nodeVars.classTitleColor,
                  '[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)]',
                )}
              >
                {nodeVars.classTitle ?? '-'}
              </div>

              <div
                className={clsx(
                  classes.classSystemName,
                  'flex-grow overflow-hidden text-ellipsis whitespace-nowrap font-sans',
                )}
              >
                {systemName}
              </div>

              {nodeVars.isWormhole && (
                <div className={classes.wormholeContainer}>
                  <div className={classes.statics}>
                    {nodeVars.sortedStatics.map(whClass => (
                      <WormholeClassComp key={whClass} id={whClass} />
                    ))}
                  </div>
                  {nodeVars.effectName !== null && (
                    <div className={clsx(classes.effect, EFFECT_BACKGROUND_STYLES[nodeVars.effectName])} />
                  )}
                </div>
              )}
            </div>

            <div className={clsx(classes.BottomRow, 'flex items-center justify-between')}>
              <div className="flex items-center gap-2">
                {nodeVars.isShattered && (
                  <div>
                    <span
                      className={clsx(
                        'pi pi-spinner-dotted',
                        '[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)]',
                        'text-[8px]',
                        'text-sky-200',
                      )}
                    />
                  </div>
                )}
                {nodeVars.tag != null && nodeVars.tag !== '' && (
                  <div className={clsx(classes.tagTitle, 'font-medium')}>{`[${nodeVars.tag}]`}</div>
                )}
                <div className={clsx(classes.customName)} title={`${customName ?? ''}`}>
                  {customName}
                </div>
              </div>
              <div className="flex items-center justify-end">
                <div
                  className={clsx('flex items-center gap-1', {
                    [classes.hasLocalCounter]: nodeVars.charactersInSystem.length > 0,
                    [classes.countAbove9]: nodeVars.charactersInSystem.length > 9,
                  })}
                >
                  {nodeVars.locked && <i className={clsx(PrimeIcons.LOCK, classes.lockIcon)} />}
                  {nodeVars.hubs.includes(nodeVars.solarSystemId.toString()) && (
                    <i className={clsx(PrimeIcons.MAP_MARKER, classes.mapMarker)} />
                  )}
                </div>
                <LocalCounter
                  hasUserCharacters={nodeVars.hasUserCharacters}
                  localCounterCharacters={localCounterCharacters}
                  showIcon={false}
                />
              </div>
            </div>
          </>
        )}
      </div>
      <div className={classes.Handlers}>
        <Handle
          type="target"
          position={Position.Bottom}
          style={{
            width: '100%',
            height: '100%',
            background: 'none',
            cursor: 'cell',
            pointerEvents: dropHandler,
            opacity: 0,
            borderRadius: 0,
          }}
          id="whole-node-target"
        />
        <Handle
          type="source"
          className={clsx(classes.Handle, classes.HandleTop, {
            [classes.selected]: nodeVars.selected,
            [classes.Tick]: nodeVars.isThickConnections,
          })}
          style={{
            width: '100%',
            height: '55%',
            background: 'none',
            cursor: 'cell',
            opacity: 0,
            borderRadius: 0,
            visibility: showHandlers ? 'visible' : 'hidden',
          }}
          position={Position.Top}
          id="a"
        />
        <Handle
          type="source"
          className={clsx(classes.Handle, classes.HandleRight, {
            [classes.selected]: nodeVars.selected,
            [classes.Tick]: nodeVars.isThickConnections,
          })}
          style={{ visibility: showHandlers ? 'visible' : 'hidden', cursor: 'cell', zIndex: 10 }}
          position={Position.Right}
          id="b"
        />
        <Handle
          type="source"
          className={clsx(classes.Handle, classes.HandleBottom, {
            [classes.selected]: nodeVars.selected,
            [classes.Tick]: nodeVars.isThickConnections,
          })}
          style={{ visibility: 'hidden', cursor: 'cell' }}
          position={Position.Bottom}
          id="c"
        />
        <Handle
          type="source"
          className={clsx(classes.Handle, classes.HandleLeft, {
            [classes.selected]: nodeVars.selected,
            [classes.Tick]: nodeVars.isThickConnections,
          })}
          style={{ visibility: showHandlers ? 'visible' : 'hidden', cursor: 'cell', zIndex: 10 }}
          position={Position.Left}
          id="d"
        />
      </div>
    </>
  );
});

SolarSystemNodeZoo.displayName = 'SolarSystemNodeZoo';
export default SolarSystemNodeZoo;
