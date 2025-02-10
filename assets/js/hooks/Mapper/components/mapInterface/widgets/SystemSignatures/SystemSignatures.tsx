import { Widget } from '@/hooks/Mapper/components/mapInterface/components';
import {
  InfoDrawer,
  LayoutEventBlocker,
  SystemView,
  TooltipPosition,
  WdCheckbox,
  WdImgButton,
} from '@/hooks/Mapper/components/ui-kit';
import { ExtendedSystemSignature, SystemSignaturesContent } from './SystemSignaturesContent';
import {
  COSMIC_ANOMALY,
  COSMIC_SIGNATURE,
  DEPLOYABLE,
  DRONE,
  Setting,
  SHIP,
  STARBASE,
  STRUCTURE,
  SystemSignatureSettingsDialog,
} from './SystemSignatureSettingsDialog';
import { SignatureGroup } from '@/hooks/Mapper/types';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { PrimeIcons } from 'primereact/api';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { CheckboxChangeEvent } from 'primereact/checkbox';
import useMaxWidth from '@/hooks/Mapper/hooks/useMaxWidth';
import { WdTooltipWrapper } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper';

const SIGNATURE_SETTINGS_KEY = 'wanderer_system_signature_settings_v5_2';
export const SHOW_DESCRIPTION_COLUMN_SETTING = 'show_description_column_setting';
export const SHOW_UPDATED_COLUMN_SETTING = 'SHOW_UPDATED_COLUMN_SETTING';
export const LAZY_DELETE_SIGNATURES_SETTING = 'LAZY_DELETE_SIGNATURES_SETTING';
export const KEEP_LAZY_DELETE_SETTING = 'KEEP_LAZY_DELETE_ENABLED_SETTING';

const settings: Setting[] = [
  { key: SHOW_UPDATED_COLUMN_SETTING, name: 'Show Updated Column', value: false, isFilter: false },
  { key: SHOW_DESCRIPTION_COLUMN_SETTING, name: 'Show Description Column', value: false, isFilter: false },
  { key: LAZY_DELETE_SIGNATURES_SETTING, name: 'Lazy Delete Signatures', value: false, isFilter: false },
  { key: KEEP_LAZY_DELETE_SETTING, name: 'Keep "Lazy Delete" Enabled', value: false, isFilter: false },
  { key: COSMIC_ANOMALY, name: 'Show Anomalies', value: true, isFilter: true },
  { key: COSMIC_SIGNATURE, name: 'Show Cosmic Signatures', value: true, isFilter: true },
  { key: DEPLOYABLE, name: 'Show Deployables', value: true, isFilter: true },
  { key: STRUCTURE, name: 'Show Structures', value: true, isFilter: true },
  { key: STARBASE, name: 'Show Starbase', value: true, isFilter: true },
  { key: SHIP, name: 'Show Ships', value: true, isFilter: true },
  { key: DRONE, name: 'Show Drones And Charges', value: true, isFilter: true },
  { key: SignatureGroup.Wormhole, name: 'Show Wormholes', value: true, isFilter: true },
  { key: SignatureGroup.RelicSite, name: 'Show Relic Sites', value: true, isFilter: true },
  { key: SignatureGroup.DataSite, name: 'Show Data Sites', value: true, isFilter: true },
  { key: SignatureGroup.OreSite, name: 'Show Ore Sites', value: true, isFilter: true },
  { key: SignatureGroup.GasSite, name: 'Show Gas Sites', value: true, isFilter: true },
  { key: SignatureGroup.CombatSite, name: 'Show Combat Sites', value: true, isFilter: true },
];

const defaultSettings = () => {
  return [...settings];
};

export const SystemSignatures = () => {
  const {
    data: { selectedSystems },
  } = useMapRootState();

  const [visible, setVisible] = useState(false);
  const [settings, setSettings] = useState<Setting[]>(defaultSettings);
  const [sigCount, setSigCount] = useState<number>(0);
  const [systemId] = selectedSystems;
  const isNotSelectedSystem = selectedSystems.length !== 1;
  const lazyDeleteValue = useMemo(
    () => settings.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)!.value,
    [settings],
  );

  const [pendingSigs, setPendingSigs] = useState<ExtendedSystemSignature[]>([]);
  const [undoPending, setUndoPending] = useState<() => void>(() => () => {});

  const handleSettingsChange = useCallback((newSettings: Setting[]) => {
    setSettings(newSettings);
    localStorage.setItem(SIGNATURE_SETTINGS_KEY, JSON.stringify(newSettings));
    setVisible(false);
  }, []);

  const handleLazyDeleteChange = useCallback((value: boolean) => {
    setSettings(prev => {
      const lazy = prev.find(s => s.key === LAZY_DELETE_SIGNATURES_SETTING)!;
      lazy.value = value;
      localStorage.setItem(SIGNATURE_SETTINGS_KEY, JSON.stringify(prev));
      return [...prev];
    });
  }, []);

  const handleSigCountChange = useCallback((count: number) => {
    setSigCount(count);
  }, []);

  useEffect(() => {
    const restored = localStorage.getItem(SIGNATURE_SETTINGS_KEY);
    if (restored) {
      setSettings(JSON.parse(restored));
    }
  }, []);

  const ref = useRef<HTMLDivElement>(null);
  const compact = useMaxWidth(ref, 260);

  return (
    <Widget
      label={
        <div className="flex justify-between items-center text-xs w-full h-full" ref={ref}>
          <div className="flex justify-between items-center gap-1">
            <div className="flex whitespace-nowrap text-ellipsis overflow-hidden text-stone-400">
              {`[${sigCount}] Signatures ${isNotSelectedSystem ? '' : 'in'}`}
            </div>
            {!isNotSelectedSystem && <SystemView systemId={systemId} className="select-none text-center" hideRegion />}
          </div>
          <LayoutEventBlocker className="flex gap-2.5">
            <WdTooltipWrapper content="Enable Lazy delete">
              <WdCheckbox
                size="xs"
                labelSide="left"
                label={compact ? '' : 'Lazy delete'}
                value={lazyDeleteValue}
                classNameLabel="text-stone-400 hover:text-stone-200 transition duration-300 whitespace-nowrap text-ellipsis overflow-hidden"
                onChange={(event: CheckboxChangeEvent) => handleLazyDeleteChange(!!event.checked)}
              />
            </WdTooltipWrapper>
            {pendingSigs.length > 0 && (
              <WdImgButton
                className={`${PrimeIcons.UNDO} hover:text-red-700`}
                tooltip={{ content: `Undo pending deletions (${pendingSigs.length})` }}
                onClick={() => {
                  undoPending();
                  setPendingSigs([]);
                }}
              />
            )}
            <WdImgButton
              className={PrimeIcons.QUESTION_CIRCLE}
              tooltip={{
                position: TooltipPosition.left,
                content: (
                  <div className="flex flex-col gap-1">
                    <InfoDrawer title={<b className="text-slate-50">How to add/update signature?</b>}>
                      In game you need to select one or more signatures in the Probe scanner list. Use hotkeys like{' '}
                      <b className="text-sky-500">Shift + LMB</b>, <b className="text-sky-500">Ctrl + LMB</b> or{' '}
                      <b className="text-sky-500">Ctrl + A</b> for select all, then copy (
                      <b className="text-sky-500">Ctrl + C</b>) and paste (<b className="text-sky-500">Ctrl + V</b>)
                      here.
                    </InfoDrawer>
                    <InfoDrawer title={<b className="text-slate-50">How to select?</b>}>
                      Click on a signature (or use hotkeys like <b className="text-sky-500">Shift + LMB</b> or{' '}
                      <b className="text-sky-500">Ctrl + LMB</b>).
                    </InfoDrawer>
                    <InfoDrawer title={<b className="text-slate-50">How to delete?</b>}>
                      Select the signature(s) and press <b className="text-sky-500">Del</b>.
                    </InfoDrawer>
                  </div>
                ) as React.ReactNode,
              }}
            />
            <WdImgButton className={PrimeIcons.SLIDERS_H} onClick={() => setVisible(true)} />
          </LayoutEventBlocker>
        </div>
      }
    >
      {isNotSelectedSystem ? (
        <div className="w-full h-full flex justify-center items-center select-none text-center text-stone-400/80 text-sm">
          System is not selected
        </div>
      ) : (
        <SystemSignaturesContent
          systemId={systemId}
          settings={settings}
          onLazyDeleteChange={handleLazyDeleteChange}
          onPendingDeletionChange={(pending, undo) => {
            setPendingSigs(pending);
            setUndoPending(() => undo);
          }}
          onCountChange={handleSigCountChange}
        />
      )}
      {visible && (
        <SystemSignatureSettingsDialog
          settings={settings}
          onCancel={() => setVisible(false)}
          onSave={handleSettingsChange}
        />
      )}
    </Widget>
  );
};
