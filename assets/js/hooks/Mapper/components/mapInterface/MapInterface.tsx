import 'react-grid-layout/css/styles.css';
import 'react-resizable/css/styles.css';
import { useMemo, useState, useEffect } from 'react';
import { SESSION_KEY } from '@/hooks/Mapper/constants.ts';
import { WindowManager } from '@/hooks/Mapper/components/ui-kit/WindowManager';
import { WindowProps } from '@/hooks/Mapper/components/ui-kit/WindowManager/types.ts';
import { CURRENT_WINDOWS_VERSION, DEFAULT_WIDGETS } from '@/hooks/Mapper/components/mapInterface/constants.tsx';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { WidgetsIds } from '@/hooks/Mapper/components/mapInterface/constants.tsx';

type WindowsLS = {
  windows: Omit<WindowProps, 'content'>[];
  version: number;
};

const saveWindowsToLS = (toSaveItems: WindowProps[]) => {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const out = toSaveItems.map(({ content: _content, ...rest }) => rest);
  localStorage.setItem(SESSION_KEY.windows, JSON.stringify({ version: CURRENT_WINDOWS_VERSION, windows: out }));
};

const restoreWindowsFromLS = (): WindowProps[] => {
  const raw = localStorage.getItem(SESSION_KEY.windows);
  if (!raw) {
    console.warn('No windows found in local storage!!');
    return DEFAULT_WIDGETS;
  }

  const { version, windows } = JSON.parse(raw) as WindowsLS;
  if (!version || CURRENT_WINDOWS_VERSION > version) {
    return DEFAULT_WIDGETS;
  }

  const out = windows
    .filter(stored => DEFAULT_WIDGETS.some(def => def.id === stored.id))
    .map(stored => {
      const content = DEFAULT_WIDGETS.find(def => def.id === stored.id)?.content;
      return { ...stored, content: content! };
    });

  return out;
};

const mergeWindows = (currentItems: WindowProps[]): WindowProps[] => {
  const missingWidgets = DEFAULT_WIDGETS.filter(defWidget => !currentItems.some(stored => stored.id === defWidget.id));
  return [...currentItems, ...missingWidgets];
};

export const MapInterface = () => {
  const [items, setItems] = useState<WindowProps[]>(restoreWindowsFromLS);

  const { windowsVisible } = useMapRootState();

  useEffect(() => {
    const mergedItems = mergeWindows(items);
    if (mergedItems.length !== items.length) {
      setItems(mergedItems);
    }
  }, [items, windowsVisible]);

  const itemsFiltered = useMemo(() => {
    return items.filter(x => windowsVisible.includes(x.id as WidgetsIds));
  }, [items, windowsVisible]);

  return (
    <WindowManager
      windows={itemsFiltered}
      dragSelector=".react-grid-dragHandleExample"
      onChange={updated => {
        saveWindowsToLS(updated);
        setItems(updated);
      }}
    />
  );
};
