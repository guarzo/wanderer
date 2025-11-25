import { Dialog } from 'primereact/dialog';
import { useState, useCallback } from 'react';
import { CharacterActivityContent } from '@/hooks/Mapper/components/mapRootContent/components/CharacterActivity/CharacterActivityContent.tsx';

interface CharacterActivityProps {
  visible: boolean;
  onHide: () => void;
}

const periodOptions = [
  { value: 30, label: '30 Days' },
  { value: 365, label: '1 Year' },
  { value: null, label: 'All Time' },
];

export const CharacterActivity = ({ visible, onHide }: CharacterActivityProps) => {
  const [selectedPeriod, setSelectedPeriod] = useState<number | null>(30);

  const handlePeriodChange = useCallback((days: number | null) => {
    setSelectedPeriod(days);
  }, []);

  return (
    <Dialog
      header="Character Activity"
      visible={visible}
      className="w-[550px] max-h-[90vh]"
      onHide={onHide}
      dismissableMask
      contentClassName="p-0 h-full flex flex-col"
    >
      {/* Period Filter */}
      <div className="px-4 pt-3 pb-2 border-b border-stone-600">
        <span className="text-sm text-stone-400 mb-2 block">Period:</span>
        <div className="flex flex-wrap gap-3">
          {periodOptions.map(option => (
            <label key={String(option.value)} className="cursor-pointer flex items-center gap-1">
              <input
                type="radio"
                name="activityPeriod"
                value={option.value ?? ''}
                checked={selectedPeriod === option.value}
                onChange={() => handlePeriodChange(option.value)}
              />
              <span className="text-sm">{option.label}</span>
            </label>
          ))}
        </div>
      </div>

      <CharacterActivityContent selectedPeriod={selectedPeriod} />
    </Dialog>
  );
};
