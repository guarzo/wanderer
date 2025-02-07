import { useMemo } from 'react';
import { Widget } from '@/hooks/Mapper/components/mapInterface/components';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { sortCharacters } from '@/hooks/Mapper/components/mapInterface/helpers/sortCharacters';
import { useMapCheckPermissions, useMapGetOption } from '@/hooks/Mapper/mapRootProvider/hooks/api';
import { UserPermission } from '@/hooks/Mapper/types/permissions';
import { LocalCharactersList } from './components/LocalCharactersList';
import { useLocalCharactersItemTemplate } from './hooks/useLocalCharacters';
import { useLocalCharacterWidgetSettings } from './hooks/useLocalWidgetSettings';
import { LocalCharactersHeader } from './components/LocalCharactersHeader';

//
// A new responsive checkbox that adjusts its label and even removes itself
// if there isn’t enough space.
//
interface ResponsiveCheckboxProps {
  tooltipContent: string;
  size: string;
  labelFull: string;
  labelAbbreviated: string;
  value: boolean;
  onChange: () => void;
  classNameLabel?: string;
  containerClassName?: string;
  labelSide?: string;
}

const ResponsiveCheckbox: React.FC<ResponsiveCheckboxProps> = ({
  tooltipContent,
  size,
  labelFull,
  labelAbbreviated,
  value,
  onChange,
  classNameLabel,
  containerClassName,
  labelSide = 'left',
}) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);

  useEffect(() => {
    if (!containerRef.current) return;
    const observer = new ResizeObserver((entries) => {
      for (let entry of entries) {
        setWidth(entry.contentRect.width);
      }
    });
    observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, []);

  // Define breakpoints (adjust these values as needed):
  const FULL_LABEL_THRESHOLD = 150;       // full label (e.g. "Show offline")
  const ABBREVIATED_LABEL_THRESHOLD = 100;  // abbreviated label (e.g. "Offline")
  const MINIMUM_THRESHOLD = 50;             // only enough space for the checkbox icon

  let labelToShow: string;
  if (width === 0) {
    // Before we have a measurement, assume there's enough space.
    labelToShow = labelFull;
  } else if (width >= FULL_LABEL_THRESHOLD) {
    labelToShow = labelFull;
  } else if (width >= ABBREVIATED_LABEL_THRESHOLD) {
    labelToShow = labelAbbreviated;
  } else if (width >= MINIMUM_THRESHOLD) {
    labelToShow = ''; // show checkbox with no label
  } else {
    return null; // not enough space to show anything
  }

  const checkbox = (
    <div ref={containerRef} className={containerClassName}>
      <WdCheckbox
        size={size}
        labelSide={labelSide}
        label={labelToShow}
        value={value}
        classNameLabel={classNameLabel}
        onChange={onChange}
      />
    </div>
  );

  return tooltipContent ? (
    <WdTooltipWrapper content={tooltipContent}>{checkbox}</WdTooltipWrapper>
  ) : (
    checkbox
  );
};

//
// The main component with an updated header that uses ResponsiveCheckbox
//
export const LocalCharacters = () => {
  const {
    data: { characters, userCharacters, selectedSystems },
  } = useMapRootState();

  const [settings, setSettings] = useLocalCharacterWidgetSettings();
  const [systemId] = selectedSystems;
  const restrictOfflineShowing = useMapGetOption("restrict_offline_showing");
  const isAdminOrManager = useMapCheckPermissions([UserPermission.MANAGE_MAP]);
  const showOffline = useMemo(
    () => !restrictOfflineShowing || isAdminOrManager,
    [isAdminOrManager, restrictOfflineShowing]
  );

  const sorted = useMemo(() => {
    const filtered = characters
      .filter(x => x.location?.solar_system_id?.toString() === systemId)
      .map(x => ({
        ...x,
        isOwn: userCharacters.includes(x.eve_id),
        compact: settings.compact,
        showShipName: settings.showShipName,
      }))
      .sort(sortCharacters);

    if (!showOffline || !settings.showOffline) {
      return filtered.filter(c => c.online);
    }
    return filtered;
  }, [
    characters,
    systemId,
    userCharacters,
    settings.compact,
    settings.showOffline,
    settings.showShipName,
    showOffline,
  ]);

  const isNobodyHere = sorted.length === 0;
  const isNotSelectedSystem = selectedSystems.length !== 1;
  const showList = sorted.length > 0 && selectedSystems.length === 1;

  const itemTemplate = useLocalCharactersItemTemplate(settings.showShipName);

  return (
    <Widget
      label={
        <LocalCharactersHeader
          sortedCount={sorted.length}
          showList={showList}
          showOffline={showOffline}
          settings={settings}
          setSettings={setSettings}
        />
      }
    >
      {isNotSelectedSystem && (
        <div className="w-full h-full flex justify-center items-center select-none text-center text-stone-400/80 text-sm">
          System is not selected
        </div>
      )}
      {isNobodyHere && !isNotSelectedSystem && (
        <div className="w-full h-full flex justify-center items-center select-none text-stone-400/80 text-sm">
          Nobody here
        </div>
      )}
      {showList && (
        <LocalCharactersList
          items={sorted}
          itemSize={settings.compact ? 26 : 41}
          itemTemplate={itemTemplate}
          containerClassName="w-full h-full overflow-x-hidden overflow-y-auto custom-scrollbar select-none"
        />
      )}
    </Widget>
  );
};
