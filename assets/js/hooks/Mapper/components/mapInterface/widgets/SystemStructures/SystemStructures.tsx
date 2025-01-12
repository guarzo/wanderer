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

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const mapped = fetched.map(({ owner_id, owner_ticker, type_id, ...rest }: any) => ({
        ...rest,
        ownerId: owner_id,
        ownerTicker: owner_ticker,
        typeId: type_id,
      }));
      console.log(`get Structures ---------- ${JSON.stringify(mapped)} end get Structures ----------------------`);

      setStructures(mapped);
    } catch (err) {
      console.error('Failed to get structures:', err);
    }
  }, [systemId, outCommand]);

  useEffect(() => {
    handleGetStructures();
  }, [handleGetStructures]);

  const handleUpdateStructures = useCallback(
    async (newList: StructureItem[]) => {
      console.log('handleUpdateStructures called with =>', newList);
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

        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const final = updatedStructures.map(({ owner_id, owner_ticker, type_id, ...rest }: any) => ({
          ...rest,
          ownerId: owner_id,
          ownerTicker: owner_ticker,
          typeId: type_id,
        }));

        console.log(
          `updating structures with -------------- ${JSON.stringify(final)} ----------------------- end update`,
        );

        setStructures(final);
      } catch (error) {
        console.error('Failed to update structures:', error);
      }
    },
    [structures, systemId, outCommand],
  );

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

            // 2.1) Find an existing structure by name (and maybe typeId if relevant)
            const existingIndex = oldList.findIndex(s => s.name.trim() === snippetItem.name.trim());
            if (existingIndex !== -1) {
              // We have an existing structure => update
              const existing = { ...oldList[existingIndex] };
              const updated = {
                ...existing,
                // Merge snippet fields you want to override
                status: snippetItem.status,
                endTime: snippetItem.endTime,
                notes: snippetItem.notes ?? existing.notes,
                // Keep existing typeId, etc.
              };
              oldList[existingIndex] = updated;

              console.log('[processSnippetText] updated existing =>', updated);
            } else {
              // 2.2) Skip if no matching structure found
              console.log('[processSnippetText] skipping 3-line snippet => no existing match for', snippetItem.name);
            }
            continue;
          }
        }

        const line = lines[i];
        i += 1;
        const newItem = parseFormatOneLine(line);
        if (newItem) {
          // Enforce uniqueness by (typeId, name):
          const duplicate = oldList.some(s => s.typeId === newItem.typeId && s.name.trim() === newItem.name.trim());
          if (duplicate) {
            console.log('[processSnippetText] Skipping duplicate =>', newItem);
          } else {
            singleLineNewItems.push(newItem);
          }
        }
      }

      const merged = [...oldList, ...singleLineNewItems];
      console.log('[processSnippetText] final merged =>', merged);
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
    <div tabIndex={0} onPaste={handlePaste} style={{ outline: 'none' }}>
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
                        In game you need select one or more strucutres <br /> in list in{' '}
                        <b className="text-sky-500">Directional Scanner</b>. <br /> Use next hotkeys:
                        <br />
                        <b className="text-sky-500">Shift + LMB</b> or <b className="text-sky-500">Ctrl + LMB</b>
                        <br /> or <b className="text-sky-500">Ctrl + A</b> for select all
                        <br />
                        and then use <b className="text-sky-500">Ctrl + C</b>, after you need to go <br />
                        here select Solar system then select the structure widget{' '}
                        <b className="text-sky-500">Ctrl + V</b>
                      </InfoDrawer>
                      <InfoDrawer title={<b className="text-slate-50">How to select?</b>}>
                        For select any structure you need click to click on it, <br /> with hotkeys{' '}
                        <b className="text-sky-500">Shift + LMB</b> or <b className="text-sky-500">Ctrl + LMB</b>
                      </InfoDrawer>
                      <InfoDrawer title={<b className="text-slate-50">How to add a timer?</b>}>
                        Click on a structure that has a timer within the game <br />
                        right click the selected item window in game and select copy, then click the blue add timer
                        button to the left
                      </InfoDrawer>
                      <InfoDrawer title={<b className="text-slate-50">How to delete?</b>}>
                        To delete any signature first of all you need select it
                        <br /> and then use <b className="text-sky-500">Delete</b>
                      </InfoDrawer>
                    </div>
                  ) as React.ReactNode,
                }}
              />
            </LayoutEventBlocker>
          </div>
        }
      >
        {isNotSelectedSystem ? (
          <div className="w-full h-full flex justify-center items-center select-none text-center text-stone-400/80 text-sm">
            System is not selected
          </div>
        ) : (
          <SystemStructuresContent structures={structures} onUpdateStructures={handleUpdateStructures} />
        )}
      </Widget>
    </div>
  );
};
