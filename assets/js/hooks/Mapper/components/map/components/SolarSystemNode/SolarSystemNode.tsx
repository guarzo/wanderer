import { memo, useMemo } from 'react';
import { Handle, Position, WrapNodeProps } from 'reactflow';
import { MapSolarSystemType } from '../../map.types';
import classes from './SolarSystemNode.module.scss';
import clsx from 'clsx';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useMapGetOption } from '@/hooks/Mapper/mapRootProvider/hooks/api';

import {
  EFFECT_BACKGROUND_STYLES,
  LABELS_INFO,
  LABELS_ORDER,
  MARKER_BOOKMARK_BG_STYLES,
  STATUS_CLASSES,
} from '@/hooks/Mapper/components/map/constants.ts';
import { isWormholeSpace } from '@/hooks/Mapper/components/map/helpers/isWormholeSpace.ts';
import { WormholeClassComp } from '@/hooks/Mapper/components/map/components/WormholeClassComp';
import { UnsplashedSignature } from '@/hooks/Mapper/components/map/components/UnsplashedSignature';
import { useMapState } from '@/hooks/Mapper/components/map/MapProvider.tsx';
import { getSystemClassStyles, prepareUnsplashedChunks } from '@/hooks/Mapper/components/map/helpers';
import { sortWHClasses } from '@/hooks/Mapper/helpers';
import { PrimeIcons } from 'primereact/api';
import { LabelsManager } from '@/hooks/Mapper/utils/labelsManager.ts';
import { OutCommand } from '@/hooks/Mapper/types';
import { useDoubleClick } from '@/hooks/Mapper/hooks/useDoubleClick.ts';
import { REGIONS_MAP, Spaces } from '@/hooks/Mapper/constants';

const SpaceToClass: Record<string, string> = {
  [Spaces.Caldari]: classes.Caldaria,
  [Spaces.Matar]: classes.Mataria,
  [Spaces.Amarr]: classes.Amarria,
  [Spaces.Gallente]: classes.Gallente,
};

const sortedLabels = (labels: string[]) => {
  if (!labels) return [];
  return LABELS_ORDER.filter((x) => labels.includes(x)).map((x) => LABELS_INFO[x]);
};

export const getActivityType = (count: number) => {
  if (count <= 5) return 'activityNormal';
  if (count <= 30) return 'activityWarn';
  return 'activityDanger';
};

export const SolarSystemNode = memo(({ data, selected }: WrapNodeProps<MapSolarSystemType>) => {
  // Convert the option string ("true"/"false") into a real boolean:
  const useLabelFocusedNodes =
    useMapGetOption('show_label_focused_nodes') === 'true';

  const { interfaceSettings } = useMapRootState();
  const { isShowUnsplashedSignatures } = interfaceSettings;

  const {
    system_class,
    security,
    class_title,
    solar_system_id,
    statics,
    effect_name,
    region_name,
    region_id,
    is_shattered,
    solar_system_name,
  } = data.system_static_info;

  const signatures = data.system_signatures;
  const { locked, name, tag, status, labels, id } = data || {};

  // Use name if it’s truthy (non-empty), otherwise fallback to solar_system_name:
  const customName = name || solar_system_name;

  const {
    data: {
      characters,
      presentCharacters,
      wormholesData,
      hubs,
      kills,
      userCharacters,
      isConnecting,
      hoverNodeId,
      visibleNodes,
      showKSpaceBG,
      isThickConnections,
    },
    outCommand,
  } = useMapState();

  const visible = useMemo(() => visibleNodes.has(id), [id, visibleNodes]);

  const charactersInSystem = useMemo(() => {
    return characters
      .filter((c) => c.location?.solar_system_id === solar_system_id)
      .filter((c) => c.online);
  }, [characters, presentCharacters, solar_system_id]);

  const isWormhole = isWormholeSpace(system_class);
  const classTitleColor = useMemo(
    () => getSystemClassStyles({ systemClass: system_class, security }),
    [security, system_class]
  );
  const sortedStaticsWH = useMemo(() => sortWHClasses(wormholesData, statics), [
    wormholesData,
    statics,
  ]);

  const lebM = useMemo(() => new LabelsManager(labels ?? ''), [labels]);
  const labelsInfo = useMemo(() => sortedLabels(lebM.list), [lebM]);
  const labelCustom = useMemo(() => lebM.customLabel, [lebM]);

  const killsCount = useMemo(() => {
    const systemKills = kills[solar_system_id];
    return systemKills || null;
  }, [kills, solar_system_id]);

  // Double-click opens the system settings
  const dbClick = useDoubleClick(() => {
    outCommand({
      type: OutCommand.openSettings,
      data: { system_id: solar_system_id.toString() },
    });
  });

  const showHandlers = isConnecting || hoverNodeId === id;
  const space = showKSpaceBG ? REGIONS_MAP[region_id] : '';
  const regionClass = showKSpaceBG ? SpaceToClass[space] : null;

  // Prepare unsplashed signatures if needed
  const [unsplashedLeft, unsplashedRight] = useMemo(() => {
    if (!isShowUnsplashedSignatures) return [[], []];
    return prepareUnsplashedChunks(
      signatures
        .filter((s) => s.group === 'Wormhole' && !s.linked_system)
        .map((s) => ({
          eve_id: s.eve_id,
          type: s.type,
          custom_info: s.custom_info,
        }))
    );
  }, [isShowUnsplashedSignatures, signatures]);

  /**
   * This is the crucial piece that allows us to toggle between
   * the original (labelCustom) mode vs. the "tag - solar_system_name" mode.
   */
  const labelToShow = useMemo(() => {
    if (useLabelFocusedNodes) {
      // If toggling is on, show "tag - systemName" or just systemName
      return tag ? `${tag} - ${solar_system_name}` : solar_system_name;
    }
    console.log("label is using toggled off logic")

    // Otherwise, we show the original custom label from the old logic
    return labelCustom !== '' ? labelCustom : null;
  }, [useLabelFocusedNodes, labelCustom, tag, solar_system_name]);

  /**
   * Render the "bookmark" strip at the top-left.
   * We display labelToShow (if present), is_shattered, killsCount, plus any other short labels.
   */
  const renderBookmarks = () => {
    if (!visible) return null;

    return (
      <div className={classes.Bookmarks}>
        {labelToShow && (
          <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.custom)}>
            <span className="[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)]">
              {labelToShow}
            </span>
          </div>
        )}

        {is_shattered && (
          <div className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES.shattered)}>
            <span className={clsx('pi pi-chart-pie', classes.icon)} />
          </div>
        )}

        {killsCount && (
          <div
            className={clsx(
              classes.Bookmark,
              MARKER_BOOKMARK_BG_STYLES[getActivityType(killsCount)]
            )}
          >
            <div className={clsx(classes.BookmarkWithIcon)}>
              <span className={clsx(PrimeIcons.BOLT, classes.icon)} />
              <span className={clsx(classes.text)}>{killsCount}</span>
            </div>
          </div>
        )}

        {labelsInfo.map((x) => (
          <div
            key={x.id}
            className={clsx(classes.Bookmark, MARKER_BOOKMARK_BG_STYLES[x.id])}
          >
            {x.shortName}
          </div>
        ))}
      </div>
    );
  };

  /**
   * Render the top row from the original logic:
   * - system class title
   * - a custom name (if different from solar_system_name)
   * - wormhole statics and effect
   */
  const renderHeadRow = () => {
    if (!visible) return null;

    return (
      <div
        className="flex items-center w-full text-xs md:text-sm font-semibold leading-tight overflow-hidden"
      >
        <div className="flex items-center mr-auto">
          <div
            className={clsx(
              classes.classTitle,
              classTitleColor,
              '[text-shadow:_0_1px_0_rgb(0_0_0_/_20%)] shrink-0 mr-2 font-sans font-bold'
            )}
            style={{ minWidth: 'fit-content' }}
          >
            {class_title ?? '-'}
          </div>

          {customName && (
            <div
              className={clsx(
                classes.classSystemName,
                '[text-shadow:_0_1px_0_rgb(0_0_0_/_40%)] flex-grow overflow-hidden text-ellipsis whitespace-nowrap font-sans font-bold'
              )}
            >
              {customName}
            </div>
          )}
        </div>

        <div className="ml-auto flex items-center gap-0.5">
          {isWormhole && (
            <div className={classes.statics}>
              {sortedStaticsWH.map((x) => (
                <WormholeClassComp key={x} id={x} />
              ))}
            </div>
          )}

          {effect_name !== null && isWormhole && (
            <div
              className={clsx(classes.effect, EFFECT_BACKGROUND_STYLES[effect_name])}
            />
          )}
        </div>
      </div>
    );
  };
  
  /**
   * Render the bottom row from the original logic:
   * If not wormhole, show either region_name or labelCustom + region_name
   * If wormhole, show the labelCustom (if any) alone
   */
  const renderBottomRow = () => {
    if (!visible) return null;

    return (
      <div
        className={clsx(
          classes.BottomRow,
          'flex items-center justify-between text-xs md:text-sm font-normal leading-tight overflow-hidden min-w-0'
        )}
      >
        {/* Original logic for region / custom label display */}
        {!isWormhole ? (
          labelCustom ? (
            /* Show labelCustom fully, then region_name truncated */
            <div className="flex items-center min-w-0 whitespace-nowrap text-gray-400 text-xs md:text-xs font-bold mix-blend-screen">
              <span className="shrink-0 mr-1">{labelCustom}</span>
              <span className="overflow-hidden text-ellipsis min-w-0 max-w-full truncate">
                {' - '}
                {region_name}
              </span>
            </div>
          ) : (
            /* No labelCustom -> just show region_name as before, possibly truncating */
            <div
              className="
              text-gray-400 text-xs md:text-xs font-bold
              whitespace-nowrap overflow-hidden text-ellipsis
              min-w-0 max-w-full truncate mix-blend-screen
            "
            >
              {region_name}
            </div>
          )
        ) : labelCustom ? (
          /* If isWormhole == true, we only show labelCustom */
          <div
            className="
              text-gray-400 text-xs md:text-sm font-bold
              whitespace-nowrap overflow-hidden text-ellipsis
              min-w-0 max-w-full truncate mix-blend-screen
            "
          >
            {labelCustom}
          </div>
        ) : (
          <div />
        )}

        {renderRightIcons()}
      </div>
    );
  };

  /**
   * The little icons on the right side (lock, hub, local counter)
   */
  const renderRightIcons = () => (
    <div className="flex items-center justify-end">
      <div className="flex gap-1 items-center">
        {locked && (
          <i className={PrimeIcons.LOCK} style={{ fontSize: '0.50rem', fontWeight: 'bold' }} />
        )}
        {hubs.includes(solar_system_id.toString()) && (
          <i className={PrimeIcons.MAP_MARKER} style={{ fontSize: '0.50rem', fontWeight: 'bold' }} />
        )}
        {charactersInSystem.length > 0 && (
          <div
            className={classes.localCounter}
          >
            <span className="font-sans">{charactersInSystem.length}</span>
          </div>
        )}
      </div>
    </div>
  );

  /**
   * Render the "unsplashed" wormhole signatures if enabled
   */
  const renderUnsplashed = () => {
    if (!visible || !isShowUnsplashedSignatures) return null;

    return (
      <>
        <div className={classes.Unsplashed}>
          {unsplashedLeft.map((x) => (
            <UnsplashedSignature key={x.sig_id} signature={x} />
          ))}
        </div>
        <div className={clsx([classes.Unsplashed, classes['Unsplashed--right']])}>
          {unsplashedRight.map((x) => (
            <UnsplashedSignature key={x.sig_id} signature={x} />
          ))}
        </div>
      </>
    );
  };

  /**
   * Render the draggable handles
   */
  const renderHandlers = () => (
    <div onMouseDownCapture={dbClick} className={classes.Handlers}>
      <Handle
        type="source"
        className={clsx(classes.Handle, classes.HandleTop, {
          [classes.selected]: selected,
          [classes.Tick]: isThickConnections,
        })}
        style={{ visibility: showHandlers ? 'visible' : 'hidden' }}
        position={Position.Top}
        id="a"
      />
      <Handle
        type="source"
        className={clsx(classes.Handle, classes.HandleRight, {
          [classes.selected]: selected,
          [classes.Tick]: isThickConnections,
        })}
        style={{ visibility: showHandlers ? 'visible' : 'hidden' }}
        position={Position.Right}
        id="b"
      />
      <Handle
        type="source"
        className={clsx(classes.Handle, classes.HandleBottom, {
          [classes.selected]: selected,
          [classes.Tick]: isThickConnections,
        })}
        style={{ visibility: showHandlers ? 'visible' : 'hidden' }}
        position={Position.Bottom}
        id="c"
      />
      <Handle
        type="source"
        className={clsx(classes.Handle, classes.HandleLeft, {
          [classes.selected]: selected,
          [classes.Tick]: isThickConnections,
        })}
        style={{ visibility: showHandlers ? 'visible' : 'hidden' }}
        position={Position.Left}
        id="d"
      />
    </div>
  );

  return (
    <>
      {renderBookmarks()}
      <div
        className={clsx(
          classes.RootCustomNode,
          regionClass,
          classes[STATUS_CLASSES[status]],
          'my-0 py-0 leading-tight',
          { [classes.selected]: selected }
        )}
      >
        {renderHeadRow()}
        {renderBottomRow()}
      </div>
      {renderUnsplashed()}
      {renderHandlers()}
    </>
  );
});
