import React, { memo } from 'react';
import { MapSolarSystemType } from '../../map.types';
import { Handle, Position, NodeProps, useReactFlow } from 'reactflow';
import clsx from 'clsx';
import classes from './SolarSystemNodeZoo.module.scss';
import { PrimeIcons } from 'primereact/api';
import { GiConcentrationOrb } from 'react-icons/gi';
import { useSolarSystemNode, useLocalCounter, useNodeKillsCount } from '../../hooks';
import {
  useZooNames,
  useZooLabels,
  useSignatureAge,
  useNodeSignatures,
  useNodeOwnerTicker,
} from '../../hooks/useZooLogic';
import {
  MARKER_BOOKMARK_BG_STYLES,
  STATUS_CLASSES,
  EFFECT_BACKGROUND_STYLES,
  LABEL_ICON_MAP,
} from '@/hooks/Mapper/components/map/constants';
import { WormholeClassComp } from '@/hooks/Mapper/components/map/components/WormholeClassComp';
import { KillsCounter } from '../KillsCounter/KillsCounter';
import { LocalCounter } from '../LocalCounter/LocalCounter';
import { TooltipSize } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper/utils';

export const SolarSystemNodeZoo = memo((props: NodeProps<MapSolarSystemType>) => {
  const nodeVars = useSolarSystemNode(props);

  const updatedSignatures = useNodeSignatures(nodeVars.solarSystemId);

  const { killsCount: localKillsCount, killsActivityType: localKillsActivityType } = useNodeKillsCount(
    nodeVars.solarSystemId,
  );
  const { getEdges } = useReactFlow();
  const edges = getEdges();
  const connectionCount = edges.filter(edge => edge.source === props.id || edge.target === props.id).length;

  const showHandlers = nodeVars.isConnecting || nodeVars.hoverNodeId === nodeVars.id;
  const dropHandler = nodeVars.isConnecting ? 'all' : 'none';

  const { unsplashedCount } = useZooLabels(connectionCount, updatedSignatures);

  const { data } = props;
  const { owner_id, owner_type, owner_ticker } = data;

  const { ownerTicker, ownerURL } = useNodeOwnerTicker(owner_id, owner_type, owner_ticker);

  const { systemName, customLabel, customName } = useZooNames(
    {
      temporaryName: nodeVars.temporaryName,
      solarSystemName: nodeVars.solarSystemName,
      regionName: nodeVars.regionName,
      labelCustom: nodeVars.labelCustom,
      ownerTicker: ownerTicker,
      isWormhole: nodeVars.isWormhole,
    },
    props,
  );

  const { signatureAgeHours, bookmarkColor } = useSignatureAge(updatedSignatures);

  const { localCounterCharacters } = useLocalCounter(nodeVars);

  return (
    <>
      {nodeVars.visible && (
        <div className={classes.Bookmarks}>
          {customLabel !== '' && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.custom)}>
              {ownerURL && ownerTicker ? (
                <a
                  href={ownerURL}
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

          {localKillsCount && localKillsCount > 0 && nodeVars.solarSystemId && localKillsActivityType && (
            <KillsCounter
              killsCount={localKillsCount}
              systemId={nodeVars.solarSystemId}
              size={TooltipSize.lg}
              killsActivityType={localKillsActivityType}
              className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES[localKillsActivityType])}
            >
              <div className={clsx(classes.BookmarkWithIcon)}>
                <span className={clsx(PrimeIcons.BOLT, classes.icon)} />
                <span className={clsx(classes.text)}>{localKillsCount}</span>
              </div>
            </KillsCounter>
          )}

          {unsplashedCount > 0 && (
            <div
              className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.unSplashed)}
              style={{ display: 'flex', transform: 'rotate(-90dg)' }}
            >
              <GiConcentrationOrb
                size={8}
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
                  fontSize: '8px',
                  lineHeight: '8px',
                }}
              >
                {unsplashedCount}
              </span>
            </div>
          )}

          {updatedSignatures.length > 0 && signatureAgeHours >= 0 && (
            <div className={clsx(classes.Bookmark)} style={{ backgroundColor: bookmarkColor }}>
              <span
                className={clsx(classes.text)}
                style={{
                  color: '#FFFFFF',
                }}
              >
                {signatureAgeHours}h
              </span>
            </div>
          )}

          {nodeVars.labelsInfo.map(x => {
            const iconData = LABEL_ICON_MAP[x.id];
            return (
              <div
                key={x.id}
                className={clsx(classes.Bookmark)}
                style={{
                  backgroundColor: iconData?.backgroundColor || '#444',
                }}
              >
                {iconData ? (
                  React.isValidElement(iconData.icon) ? (
                    <span className={clsx(classes.icon, iconData.colorClass)}>{iconData.icon}</span>
                  ) : (
                    <i className={clsx(`pi ${iconData.icon} ${iconData.colorClass}`, classes.icon)} />
                  )
                ) : (
                  <span className="text-white">{x.shortName}</span>
                )}
              </div>
            );
          })}
        </div>
      )}
      <div
        className={clsx(
          classes.RootCustomNode,
          nodeVars.regionClass && classes[nodeVars.regionClass],
          nodeVars.status != null ? classes[STATUS_CLASSES[nodeVars.status]] : null,
          {
            [classes.selected]: nodeVars.selected,
            [classes.rally]: nodeVars.isRally,
            [classes.rallyRoute]: nodeVars.isRallyRoute,
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

      <div className={classes.Handlers} onMouseDownCapture={nodeVars.dbClick}>
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
          onDoubleClick={e => {
            e.stopPropagation();
            nodeVars.dbClick(e);
          }}
        />
        <Handle
          type="source"
          className={clsx(classes.Handle, classes.HandleRight, {
            [classes.selected]: nodeVars.selected,
            [classes.Tick]: nodeVars.isThickConnections,
          })}
          style={{
            visibility: showHandlers ? 'visible' : 'hidden',
            cursor: 'cell',
            zIndex: 10,
          }}
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
          style={{
            visibility: showHandlers ? 'visible' : 'hidden',
            cursor: 'cell',
            zIndex: 10,
          }}
          position={Position.Left}
          id="d"
        />
      </div>
    </>
  );
});

SolarSystemNodeZoo.displayName = 'SolarSystemNodeZoo';
export default SolarSystemNodeZoo;
