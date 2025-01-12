import React, { useRef, useCallback, ClipboardEvent } from 'react';
import { StructureItem } from './types';
import { matchesThreeLineSnippet, parseThreeLineSnippet } from './parseHelpers';

interface StructuresListProps {
  handleUpdateStructures: (items: StructureItem[]) => void;
}

const StructuresList: React.FC<StructuresListProps> = ({ handleUpdateStructures }) => {
  const structuresRef = useRef<StructureItem[]>([]);

  const handlePaste = useCallback(
    (e: ClipboardEvent<HTMLDivElement>) => {
      e.preventDefault();

      const text = e.clipboardData.getData('text');
      if (!text) return;

      const lines = text
        .split(/\r?\n/)
        .map(l => l.trim())
        .filter(Boolean);

      if (!lines.length) return;

      const newItems: StructureItem[] = [];
      let i = 0;

      while (i < lines.length) {
        if (i + 2 < lines.length) {
          const snippet = lines.slice(i, i + 3);
          if (matchesThreeLineSnippet(snippet)) {
            newItems.push(parseThreeLineSnippet(snippet));
            i += 3;
            continue;
          }
        }

        i += 1;
      }

      const updatedStructures = [...structuresRef.current, ...newItems];
      structuresRef.current = updatedStructures;

      handleUpdateStructures(updatedStructures);
    },
    [handleUpdateStructures],
  );

  return (
    <div contentEditable onPaste={handlePaste} style={{ border: '1px solid gray', padding: '1rem', minHeight: '5rem' }}>
      Paste here
    </div>
  );
};

export default StructuresList;
