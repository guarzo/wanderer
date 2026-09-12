import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { InputSwitch } from 'primereact/inputswitch';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand, OutCommandHandler } from '@/hooks/Mapper/types/mapHandlers';
import { WdButton } from '@/hooks/Mapper/components/ui-kit/WdButton';
import { LocationApiSettings, LocationApiSettingsReply, locationApiError, withLocationApiTimeout } from './locationApi';

const AdminOptIn = ({ outCommand }: { outCommand: OutCommandHandler }) => {
  const inputId = useId();
  const [settings, setSettings] = useState<LocationApiSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const requestId = useRef(0);
  const pending = useRef(false);

  const request = useCallback(
    async (enabled?: boolean) => {
      if (pending.current) return;
      pending.current = true;
      const id = ++requestId.current;
      setLoading(true);
      setError(null);
      try {
        const response = await withLocationApiTimeout(
          outCommand<LocationApiSettingsReply>(
            enabled === undefined
              ? { type: OutCommand.getLocationApiSettings, data: null }
              : { type: OutCommand.setLocationApiEnabled, data: { enabled } },
          ),
        );
        if (id !== requestId.current) return;
        if (!response?.success) {
          setError(locationApiError(response?.code));
          return;
        }
        setSettings({ available: response.available, enabled: response.enabled });
      } catch {
        if (id === requestId.current) setError(locationApiError());
      } finally {
        if (id === requestId.current) {
          pending.current = false;
          setLoading(false);
        }
      }
    },
    [outCommand],
  );

  useEffect(() => {
    setSettings(null);
    request();
    const sequence = requestId;
    return () => {
      sequence.current++;
      pending.current = false;
    };
  }, [request]);

  return (
    <div className="flex flex-col gap-3" aria-busy={loading}>
      <div className="flex items-center justify-between gap-2">
        <label htmlFor={inputId} className="text-stone-300 text-[13px] font-semibold">
          Enable personal Location API tokens
        </label>
        <InputSwitch
          inputId={inputId}
          checked={settings?.enabled ?? false}
          disabled={loading || !!error || !settings || (!settings.available && !settings.enabled)}
          onChange={e => request(e.value)}
        />
      </div>
      <span className="text-stone-500 text-[12px]">
        Allow eligible map viewers to manage their own read-only location token in the Location API tab. Switching off
        temporarily disables token creation and use. Still-authorized users can resume when re-enabled.
      </span>
      {loading && (
        <span role="status" className="text-stone-500 text-[12px]">
          Loading…
        </span>
      )}
      {error && (
        <span role="alert" className="text-red-500 text-[12px]">
          {error}
        </span>
      )}
      {!error && settings && !settings.available && (
        <span role="status" className="text-stone-500 text-[12px]">
          The Location API is currently unavailable.
        </span>
      )}
      {(error || (settings && !settings.available)) && (
        <div>
          <WdButton label="Retry" size="small" disabled={loading} onClick={() => request()} />
        </div>
      )}
    </div>
  );
};

export const LocationApiAdminSettings = () => {
  const {
    outCommand,
    data: { map_slug },
  } = useMapRootState();
  return <AdminOptIn key={map_slug} outCommand={outCommand} />;
};
