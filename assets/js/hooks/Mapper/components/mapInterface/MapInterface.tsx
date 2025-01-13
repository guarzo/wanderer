import 'react-grid-layout/css/styles.css';
import 'react-resizable/css/styles.css';
import { useMemo, useState, useCallback, forwardRef, useImperativeHandle } from 'react';
import { SESSION_KEY } from '@/hooks/Mapper/constants.ts';
import { WindowManager } from '@/hooks/Mapper/components/ui-kit/WindowManager';
import { WindowProps } from '@/hooks/Mapper/components/ui-kit/WindowManager/types.ts';
import { CURRENT_WINDOWS_VERSION, DEFAULT_WIDGETS } from '@/hooks/Mapper/components/mapInterface/constants.tsx';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { WidgetsIds } from '@/hooks/Mapper/components/mapInterface/constants.tsx';

type WindowsLS = {
  windows: WindowProps[];
  version: number;
};

export interface MapInterfaceHandle {
  maybeAddWidgetToItems(widgetId: WidgetsIds): void;
}

const saveWindowsToLS = (toSaveItems: WindowProps[]) => {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const out = toSaveItems.map(({ content, ...rest }) => rest);
  localStorage.setItem(SESSION_KEY.windows, JSON.stringify({ version: CURRENT_WINDOWS_VERSION, windows: out }));
};

const restoreWindowsFromLS = (): WindowProps[] => {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const raw = localStorage.getItem(SESSION_KEY.windows);
  if (!raw) {
    console.warn('No windows found in local storage!!');
    return DEFAULT_WIDGETS;
  }

  const { version, windows } = JSON.parse(raw) as WindowsLS;
  if (!version || CURRENT_WINDOWS_VERSION > version) {
    return DEFAULT_WIDGETS;
  }

  // eslint-disable-next-line no-debugger
  const out = (windows as Omit<WindowProps, 'content'>[])
    .filter(x => DEFAULT_WIDGETS.find(def => def.id === x.id))
    .map(x => {
      const content = DEFAULT_WIDGETS.find(def => def.id === x.id)?.content;
      return { ...x, content: content! };
    });

  return out;
};

export const MapInterface = forwardRef<MapInterfaceHandle>(function MapInterface(_, ref) {
  const [items, setItems] = useState<WindowProps[]>(restoreWindowsFromLS);
  const { windowsVisible } = useMapRootState();

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const maybeAddWidgetToItems = useCallback(
    (widgetId: WidgetsIds) => {
      setItems((prev: WindowProps[]) => {
        if (prev.some(w => w.id === widgetId)) {
          return prev;
        }

        const found = DEFAULT_WIDGETS.find(def => def.id === widgetId);
        if (!found) {
          return prev;
        }

        const updatedList = [...prev, found];
        saveWindowsToLS(updatedList);
        return updatedList;
      });
    },
    [setItems],
  );

  const itemsFiltered = useMemo(() => {
    return items.filter(x => windowsVisible.some(j => x.id === j));
  }, [items, windowsVisible]);

  useImperativeHandle(ref, () => ({
    maybeAddWidgetToItems,
  }));

  return (
    <WindowManager
      windows={itemsFiltered}
      dragSelector=".react-grid-dragHandleExample"
      onChange={x => {
        saveWindowsToLS(x);
        setItems(x);
      }}
    />
  );
});
