import { InputText } from 'primereact/inputtext';
import { Dialog } from 'primereact/dialog';
import { getSystemById } from '@/hooks/Mapper/helpers';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Button } from 'primereact/button';
import { OutCommand } from '@/hooks/Mapper/types';
import { IconField } from 'primereact/iconfield';
import { LabelsManager } from '@/hooks/Mapper/utils/labelsManager.ts';
import { WdImageSize, WdImgButton, TooltipPosition } from '@/hooks/Mapper/components/ui-kit';

interface SystemCustomLabelDialogProps {
  systemId: string;
  visible: boolean;
  setVisible: (visible: boolean) => void;
}

export const SystemCustomLabelDialog = ({ systemId, visible, setVisible }: SystemCustomLabelDialogProps) => {
  const {
    data: { systems },
    outCommand,
  } = useMapRootState();

  const system = getSystemById(systems, systemId);

  const [label, setLabel] = useState('');

  useEffect(() => {
    if (!system) {
      return;
    }

    const leb = new LabelsManager(system.labels || '');

    setLabel(leb.customLabel);
  }, [system]);

  const ref = useRef({ label, outCommand, systemId, system });
  ref.current = { label, outCommand, systemId, system };

  const handleSave = useCallback(() => {
    const { label, outCommand, system } = ref.current;

    if (!system) {
      return;
    }

    const outLabel = new LabelsManager(system.labels ?? '');
    outLabel.updateCustomLabel(label);

    outCommand({
      type: OutCommand.updateSystemLabels,
      data: {
        system_id: system.id,
        value: outLabel.toString(),
      },
    });

    setVisible(false);
  }, [setVisible]);

  const inputRef = useRef<HTMLInputElement>();

  const handleReset = useCallback(() => {
    setLabel('');
  }, []);

  const onShow = useCallback(() => {
    inputRef.current?.focus();
  }, []);

  // @ts-ignore
  const handleInput = useCallback(e => {
    e.target.value = e.target.value.toUpperCase().replace(/[^A-Z0-9\-[\](){}]/g, '');
  }, []);

  // Render a loading state if system is not available
  if (!system) {
    return (
      <Dialog
        header="Custom Label"
        visible={visible}
        draggable={false}
        style={{ width: '450px' }}
        onHide={() => setVisible(false)}
      >
        <div className="p-4 text-center">
          <p>System not found or loading...</p>
        </div>
      </Dialog>
    );
  }

  return (
    <Dialog
      header="Custom Label"
      visible={visible}
      draggable={false}
      style={{ width: '450px' }}
      onShow={onShow}
      onHide={() => {
        if (!visible) {
          return;
        }
        setVisible(false);
      }}
    >
      <form onSubmit={handleSave}>
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-2">
            <div className="flex flex-col gap-1">
              <label htmlFor="username">Custom label</label>

              <IconField>
                {label !== '' && (
                  <WdImgButton
                    className="pi pi-trash text-red-400"
                    textSize={WdImageSize.large}
                    tooltip={{
                      content: 'Remove custom label',
                      className: 'pi p-input-icon',
                      position: TooltipPosition.top,
                    }}
                    onClick={handleReset}
                  />
                )}
                <InputText
                  id="username"
                  aria-describedby="username-help"
                  autoComplete="off"
                  value={label}
                  maxLength={5}
                  onChange={e => setLabel(e.target.value)}
                  // @ts-expect-error
                  ref={inputRef}
                  onInput={handleInput}
                />
              </IconField>
            </div>
          </div>

          <div className="flex gap-2 justify-end">
            <Button onClick={handleSave} outlined size="small" label="Save"></Button>
          </div>
        </div>
      </form>
    </Dialog>
  );
};
