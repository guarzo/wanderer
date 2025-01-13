import { useCallback, useEffect, useRef, useState, ClipboardEvent } from 'react';
import { Widget } from '@/hooks/Mapper/components/mapInterface/components';
import {
  LayoutEventBlocker,
  SystemView,
  WdImgButton,
  TooltipPosition,
  InfoDrawer,
} from '@/hooks/Mapper/components/ui-kit';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import useMaxWidth from '@/hooks/Mapper/hooks/useMaxWidth';
import { PrimeIcons } from 'primereact/api';

import { SystemStructuresContent } from './SystemStructuresContent/SystemStructuresContent';
import { parseFormatOneLine, parseThreeLineSnippet, matchesThreeLineSnippet } from './helpers/parseHelpers';
import { StructureItem } from './helpers/types';
import { OutCommand } from '@/hooks/Mapper/types/mapHandlers';

/**
 * Compare newList vs oldList to find added, updated, removed.
 */
function getActualStructures(oldList: StructureItem[], newList: StructureItem[]) {
  const oldMap = new Map(oldList.map(s => [s.id, s]));
  const newMap = new Map(newList.map(s => [s.id, s]));

  const added: StructureItem[] = [];
  const updated: StructureItem[] = [];
  const removed: StructureItem[] = [];

  for (const newItem of newList) {
    const oldItem = oldMap.get(newItem.id);
    if (!oldItem) {
      added.push(newItem);
    } else if (JSON.stringify(oldItem) !== JSON.stringify(newItem)) {
      updated.push(newItem);
    }
  }
  for (const oldItem of oldList) {
    if (!newMap.has(oldItem.id)) {
      removed.push(oldItem);
    }
  }
  return { added, updated, removed };
}

export const SystemStructures = () => {
  const {
    data: { selectedSystems },
    outCommand,
  } = useMapRootState();

  const [systemId] = selectedSystems;
  const isNotSelectedSystem = selectedSystems.length !== 1;

  const [structures, setStructures] = useState<StructureItem[]>([]);

  const labelRef = useRef<HTMLDivElement>(null);
  const compact = useMaxWidth(labelRef, 260);

  // Fetch structures from the server
  const handleGetStructures = useCallback(async () => {
    if (!systemId) {
      setStructures([]);
      return;
    }
    try {
      const { structures: fetched = [] } = await outCommand({
        type: OutCommand.getStructures,
        data: { system_id: systemId },
      });

      // Map server fields (snake_case) to our JS fields (camelCase)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const mapped = fetched.map(({ owner_id, owner_ticker, type_id, end_time, system_id, ...rest }: any) => ({
        ...rest,
        ownerId: owner_id,
        ownerTicker: owner_ticker,
        typeId: type_id,
        endTime: end_time,
        systemId: system_id,
      }));

      console.log('Structures =>', mapped);
      setStructures(mapped);
    } catch (err) {
      console.error('Failed to get structures:', err);
    }
  }, [systemId, outCommand]);

  useEffect(() => {
    handleGetStructures();
  }, [handleGetStructures]);

  // Send updated lists to the server
  const handleUpdateStructures = useCallback(
    async (newList: StructureItem[]) => {
      console.log('handleUpdateStructures =>', newList);
      const { added, updated, removed } = getActualStructures(structures, newList);

      // eslint-disable-next-line @typescript-eslint/no-unused-vars
      const sanitizedAdded = added.map(({ id, ...rest }) => rest);

      try {
        const { structures: updatedStructures = [] } = await outCommand({
          type: OutCommand.updateStructures,
          data: {
            system_id: systemId,
            added: sanitizedAdded,
            updated,
            removed,
          },
        });

        const final = updatedStructures.map(
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ({ owner_id, owner_ticker, type_id, end_time, system_id, ...rest }: any) => ({
            ...rest,
            ownerId: owner_id,
            ownerTicker: owner_ticker,
            typeId: type_id,
            endTime: end_time,
            systemId: system_id,
          }),
        );

        console.log('updated structures =>', final);
        setStructures(final);
      } catch (error) {
        console.error('Failed to update structures:', error);
      }
    },
    [structures, systemId, outCommand],
  );

  // Paste logic for snippet text
  const processSnippetText = useCallback(
    (text: string) => {
      const lines = text
        .split(/\r?\n/)
        .map(l => l.trim())
        .filter(Boolean);

      const oldList = [...structures];
      const singleLineNewItems: StructureItem[] = [];

      let i = 0;
      while (i < lines.length) {
        if (i <= lines.length - 3) {
          const snippetLines = lines.slice(i, i + 3);
          if (snippetLines.length === 3 && matchesThreeLineSnippet(snippetLines)) {
            const snippetItem = parseThreeLineSnippet(snippetLines);
            i += 3;

            // Attempt to find existing
            const existingIndex = oldList.findIndex(s => s.name.trim() === snippetItem.name.trim());
            if (existingIndex !== -1) {
              const existing = { ...oldList[existingIndex] };
              const updated = {
                ...existing,
                status: snippetItem.status,
                endTime: snippetItem.endTime,
                notes: snippetItem.notes ?? existing.notes,
              };
              oldList[existingIndex] = updated;
              console.log('[processSnippetText] updated existing =>', updated);
            } else {
              // skip if no match
              console.log('[processSnippetText] no existing match for =>', snippetItem.name);
            }
            continue;
          }
        }
        const line = lines[i];
        i += 1;
        const newItem = parseFormatOneLine(line);
        if (newItem) {
          // enforce uniqueness by (typeId, name)
          const duplicate = oldList.some(s => s.typeId === newItem.typeId && s.name.trim() === newItem.name.trim());
          if (!duplicate) {
            singleLineNewItems.push(newItem);
          }
        }
      }

      const merged = [...oldList, ...singleLineNewItems];
      console.log('[processSnippetText] final =>', merged);
      handleUpdateStructures(merged);
    },
    [structures, handleUpdateStructures],
  );

  const handlePaste = useCallback(
    (e: ClipboardEvent<HTMLDivElement>) => {
      e.preventDefault();
      const text = e.clipboardData.getData('text');
      console.log('[SystemStructures] handlePaste =>', text);
      processSnippetText(text);
    },
    [processSnippetText],
  );

  const handlePasteTimer = useCallback(async () => {
    try {
      const text = await navigator.clipboard.readText();
      console.log('[SystemStructures] handlePasteTimer =>', text);
      processSnippetText(text);
    } catch (err) {
      console.error('Clipboard read error:', err);
    }
  }, [processSnippetText]);

  return (
    // We want the entire container to fill the area => "h-full flex flex-col"
    <div tabIndex={0} onPaste={handlePaste} className="h-full flex flex-col" style={{ outline: 'none' }}>
      <Widget
        label={
          <div className="flex justify-between items-center text-xs w-full h-full" ref={labelRef}>
            <div className="flex justify-between items-center gap-1">
              {!compact && (
                <div className="flex whitespace-nowrap text-ellipsis overflow-hidden text-stone-400">
                  Structures
                  {!isNotSelectedSystem && ' in'}
                </div>
              )}
              {!isNotSelectedSystem && (
                <SystemView systemId={systemId} className="select-none text-center" hideRegion />
              )}
            </div>

            <LayoutEventBlocker className="flex gap-2.5">
              <WdImgButton
                className={`${PrimeIcons.CLOCK} text-sky-400 hover:text-sky-200 transition duration-300`}
                onClick={handlePasteTimer}
              />

              <WdImgButton
                className={PrimeIcons.QUESTION_CIRCLE}
                tooltip={{
                  position: TooltipPosition.left,
                  // @ts-ignore
                  content: (
                    <div className="flex flex-col gap-1">
                      <InfoDrawer title={<b className="text-slate-50">How to add/update structures?</b>}>
                        In game, select one or more structures in D-Scan and press Ctrl+C, then click on this widget and
                        press Ctrl+V
                      </InfoDrawer>
                      <InfoDrawer title={<b className="text-slate-50">How to select?</b>}>
                        Shift-click or Ctrl-click in table to select multiple
                      </InfoDrawer>
                      <InfoDrawer title={<b className="text-slate-50">How to add a timer?</b>}>
                        In game, select a structure with an active timer, right click to copy
                      </InfoDrawer>
                    </div>
                  ) as React.ReactNode,
                }}
              />
            </LayoutEventBlocker>
          </div>
        }
      >
        {/* If no system is selected, show placeholder */}
        {isNotSelectedSystem ? (
          <div className="flex-1 flex justify-center items-center select-none text-center text-stone-400/80 text-sm">
            System is not selected
          </div>
        ) : (
          <SystemStructuresContent structures={structures} onUpdateStructures={handleUpdateStructures} />
        )}
      </Widget>
    </div>
  );
};
