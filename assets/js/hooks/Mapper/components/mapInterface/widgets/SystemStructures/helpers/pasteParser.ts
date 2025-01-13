import { StructureItem } from './structureTypes';
import { parseThreeLineSnippet, parseFormatOneLine, matchesThreeLineSnippet } from './parserHelper';

export function processSnippetText(text: string, existingStructures: StructureItem[]): StructureItem[] {
  if (!text) return existingStructures.slice();

  const lines = text
    .split(/\r?\n/)
    .map(l => l.trim())
    .filter(Boolean);

  const updatedList = [...existingStructures];
  const singleLineNewItems: StructureItem[] = [];

  let i = 0;
  while (i < lines.length) {
    if (i <= lines.length - 3) {
      const snippetLines = lines.slice(i, i + 3);
      if (matchesThreeLineSnippet(snippetLines)) {
        const snippetItem = parseThreeLineSnippet(snippetLines);

        const existingIndex = updatedList.findIndex(s => s.name.trim() === snippetItem.name.trim());
        if (existingIndex !== -1) {
          const existing = { ...updatedList[existingIndex] };
          updatedList[existingIndex] = {
            ...existing,
            status: snippetItem.status,
            endTime: snippetItem.endTime,
            notes: snippetItem.notes ?? existing.notes,
          };
        }
        i += 3;
        continue;
      }
    }

    const line = lines[i];
    i += 1;
    const newItem = parseFormatOneLine(line);
    if (newItem) {
      const duplicate = updatedList.some(s => s.typeId === newItem.typeId && s.name.trim() === newItem.name.trim());
      if (!duplicate) {
        singleLineNewItems.push(newItem);
      }
    }
  }

  return [...updatedList, ...singleLineNewItems];
}
