import { memo } from 'react';
import { MapSolarSystemType } from '../../map.types';
import { Handle, Position, NodeProps } from 'reactflow';
import clsx from 'clsx';
import classes from './SolarSystemNodeZoo.module.scss';
import { PrimeIcons } from 'primereact/api';
import { useSolarSystemNode } from '../../hooks/useSolarSystemNode';
import { useZooNames } from '../../hooks/useZooNames';
import {
  MARKER_BOOKMARK_BG_STYLES,
  STATUS_CLASSES,
  EFFECT_BACKGROUND_STYLES,
} from '@/hooks/Mapper/components/map/constants';
import { WormholeClassComp } from '@/hooks/Mapper/components/map/components/WormholeClassComp';
import { UnsplashedSignature } from '@/hooks/Mapper/components/map/components/UnsplashedSignature';

// eslint-disable-next-line react/display-name
export const SolarSystemNodeZoo = memo((props: NodeProps<MapSolarSystemType>) => {
  const nodeVars = useSolarSystemNode(props);

  const showHandlers = nodeVars.isConnecting || nodeVars.hoverNodeId === nodeVars.id;
  const dropHandler = nodeVars.isConnecting ? 'all' : 'none';

  const { systemName, customLabel, customName } = useZooNames(nodeVars);

  return (
    <>
      {nodeVars.visible && (
        <div className={classes.Bookmarks}>
          {customLabel !== '' && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.custom)}>
              <span className="[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)] ">{customLabel}</span>
            </div>
          )}

          {nodeVars.isShattered && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.shattered)}>
              <span className={clsx('pi pi-chart-pie', classes.icon)} />
            </div>
          )}

          {nodeVars.killsCount && (
            <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES[nodeVars.killsActivityType!])}>
              <div className={clsx(classes.BookmarkWithIcon)}>
                <span className={clsx(PrimeIcons.BOLT, classes.icon)} />
                <span className={clsx(classes.text)}>{nodeVars.killsCount}</span>
              </div>
            </div>
          )}

          {nodeVars.labelsInfo.map(x => (
            <div key={x.id} className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES[x.id])}>
              {x.shortName}
            </div>
          ))}
        </div>
      )}

      <div
        className={clsx(
          classes.RootCustomNode,
          nodeVars.regionClass && classes[nodeVars.regionClass],
          classes[STATUS_CLASSES[nodeVars.status]],
          { [classes.selected]: nodeVars.selected },
        )}
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
                <div className={classes.statics}>
                  {nodeVars.sortedStatics.map(whClass => (
                    <WormholeClassComp key={whClass} id={whClass} />
                  ))}
                </div>
              )}

              {nodeVars.effectName !== null && nodeVars.isWormhole && (
                <div className={clsx(classes.effect, EFFECT_BACKGROUND_STYLES[nodeVars.effectName])} />
              )}
            </div>

            <div className={clsx(classes.BottomRow, 'flex items-center justify-between')}>
              <div className="flex items-center gap-2">
                {nodeVars.tag != null && nodeVars.tag !== '' && (
                  <div className={clsx(classes.tagTitle, 'font-medium')}>{`[${nodeVars.tag}]`}</div>
                )}
                <div className={clsx(classes.customName)} title={`${customName ?? ''} ${nodeVars.labelCustom ?? ''}`}>
                  {customName} {nodeVars.labelCustom}
                </div>
              </div>

              <div className="flex items-center justify-end">
                <div className="flex gap-1 items-center">
                  {nodeVars.locked && (
                    <i className={PrimeIcons.LOCK} style={{ fontSize: '0.45rem', fontWeight: 'bold' }} />
                  )}

                  {nodeVars.hubs.includes(nodeVars.solarSystemId.toString()) && (
                    <i className={PrimeIcons.MAP_MARKER} style={{ fontSize: '0.45rem', fontWeight: 'bold' }} />
                  )}

                  {nodeVars.charactersInSystem.length > 0 && (
                    <div
                      className={clsx(classes.localCounter, {
                        [classes.hasUserCharacters]: nodeVars.hasUserCharacters,
                      })}
                    >
                      <span className="font-sans">{nodeVars.charactersInSystem.length}</span>
                    </div>
                  )}
                </div>
              </div>
            </div>
          </>
        )}
      </div>

      {nodeVars.visible && (
        <>
          {nodeVars.unsplashedLeft.length > 0 && (
            <div className={classes.Unsplashed}>
              {nodeVars.unsplashedLeft.map(sig => (
                <UnsplashedSignature key={sig.sig_id} signature={sig} />
              ))}
            </div>
          )}

          {nodeVars.unsplashedRight.length > 0 && (
            <div className={clsx(classes.Unsplashed, classes['Unsplashed--right'])}>
              {nodeVars.unsplashedRight.map(sig => (
                <UnsplashedSignature key={sig.sig_id} signature={sig} />
              ))}
            </div>
          )}
        </>
      )}
      <div onMouseDownCapture={nodeVars.dbClick} className={classes.Handlers}>
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
