import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { InputText } from 'primereact/inputtext';
import { ConfirmPopup } from 'primereact/confirmpopup';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand, OutCommandHandler } from '@/hooks/Mapper/types/mapHandlers';
import { WdButton } from '@/hooks/Mapper/components/ui-kit/WdButton';
import {
  LocationApiSettings as ApiSettings,
  LocationApiTokenReply,
  PersonalLocationApiToken,
  UnreadableLocationApiToken,
  isUnreadable,
  locationApiError,
  withLocationApiTimeout,
} from './locationApi';

type TokenCommand =
  | OutCommand.getPrimeApiToken
  | OutCommand.generatePrimeApiToken
  | OutCommand.regeneratePrimeApiToken
  | OutCommand.revokePrimeApiToken;

type Confirmation = { type: 'regenerate' | 'revoke'; target: HTMLElement };

// Wingman sends this credential as `Authorization: Bearer <token>` when staging
// bookmark primes via POST /api/maps/{map}/prejump-primes. It cannot read the
// Location API, and the personal read token cannot stage primes.
const PrimeTokenSettings = ({ outCommand }: { outCommand: OutCommandHandler }) => {
  const inputId = useId();
  const [token, setToken] = useState<PersonalLocationApiToken | UnreadableLocationApiToken | null>(null);
  const [settings, setSettings] = useState<ApiSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [unreadable, setUnreadable] = useState(false);
  const requestId = useRef(0);
  const pending = useRef(false);

  const request = useCallback(
    async (type: TokenCommand, data: { id: string; generation: number } | null = null) => {
      if (pending.current) return;
      pending.current = true;
      const id = ++requestId.current;
      setLoading(true);
      setToken(null);
      setSettings(null);
      setError(null);
      setNotice(null);
      setUnreadable(false);
      setConfirmation(null);
      try {
        let response = await withLocationApiTimeout(outCommand<LocationApiTokenReply>({ type, data }));
        if (id !== requestId.current) return;
        if (!response?.success && response?.code === 'conflict') {
          response = await withLocationApiTimeout(
            outCommand<LocationApiTokenReply>({ type: OutCommand.getPrimeApiToken, data: null }),
          );
          if (id !== requestId.current) return;
          setNotice('Your token changed elsewhere. The current token has been reloaded.');
        }
        if (!response?.success) {
          setNotice(null);
          setError(locationApiError(response?.code));
          if (isUnreadable(response)) {
            setSettings({ available: response.available, enabled: response.enabled });
            setToken(response.token);
            setUnreadable(true);
          }
          return;
        }
        setSettings({ available: response.available, enabled: response.enabled });
        setToken(response.available ? response.token : null);
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
    request(OutCommand.getPrimeApiToken);
    const sequence = requestId;
    return () => {
      sequence.current++;
      pending.current = false;
    };
  }, [request]);

  const copy = async () => {
    if (!token?.value || pending.current) return;
    pending.current = true;
    const id = ++requestId.current;
    setLoading(true);
    setNotice(null);
    try {
      await withLocationApiTimeout(navigator.clipboard.writeText(token.value));
      if (id === requestId.current) setNotice('Copied');
    } catch {
      if (id === requestId.current) {
        setToken(null);
        setSettings(null);
        setUnreadable(false);
        setError('Unable to copy the token. Retry to reload it and try again.');
      }
    } finally {
      if (id === requestId.current) {
        pending.current = false;
        setLoading(false);
      }
    }
  };

  const confirm = () => {
    if (!token || !confirmation) return;
    request(
      confirmation.type === 'regenerate' ? OutCommand.regeneratePrimeApiToken : OutCommand.revokePrimeApiToken,
      { id: token.id, generation: token.generation },
    );
  };
  const enabled = settings?.available && (!error || unreadable);
  const disabled = loading || !!confirmation || !enabled;
  const readable = !!token?.value;

  return (
    <div className="flex flex-col gap-3" aria-busy={loading}>
      <span className="text-stone-500 text-[12px]">
        Your bookmark prime token lets Wingman stage pre-jump primes for tracked characters on this map. Keep it
        private; it cannot read the Location API.
      </span>
      <div className="flex flex-col gap-1">
        <label htmlFor={inputId} className="text-stone-300 text-[13px] font-semibold">
          Bookmark prime API token
        </label>
        <InputText
          id={inputId}
          value={token?.value ?? ''}
          readOnly
          autoComplete="off"
          spellCheck={false}
          placeholder={loading ? 'Loading…' : unreadable ? 'Token unavailable — regenerate it' : 'No bookmark prime token'}
          className="w-full text-sm"
        />
      </div>
      <div className="flex flex-wrap items-center gap-2">
        {token ? (
          <WdButton
            label="Regenerate"
            size="small"
            severity="warning"
            disabled={disabled}
            onClick={e => setConfirmation({ type: 'regenerate', target: e.currentTarget })}
          />
        ) : (
          <WdButton
            label="Generate"
            size="small"
            disabled={disabled}
            loading={loading}
            onClick={() => request(OutCommand.generatePrimeApiToken)}
          />
        )}
        <WdButton label="Copy" icon="pi pi-copy" size="small" disabled={disabled || !readable} onClick={copy} />
        {token && (
          <WdButton
            label="Revoke"
            size="small"
            severity="danger"
            disabled={disabled}
            onClick={e => setConfirmation({ type: 'revoke', target: e.currentTarget })}
          />
        )}
        {(error || (settings && !enabled)) && (
          <WdButton
            label="Retry"
            size="small"
            disabled={loading}
            onClick={() => request(OutCommand.getPrimeApiToken)}
          />
        )}
      </div>
      {error && (
        <span role="alert" className="text-red-500 text-[12px]">
          {error}
        </span>
      )}
      {!error && settings && !settings.available && (
        <span role="status" className="text-stone-500 text-[12px]">
          Map integrations are currently unavailable.
        </span>
      )}
      {notice && (
        <span role="status" className="text-stone-500 text-[12px]">
          {notice}
        </span>
      )}
      <ConfirmPopup
        target={confirmation?.target}
        visible={!!confirmation}
        onHide={() => setConfirmation(null)}
        message={
          confirmation?.type === 'regenerate'
            ? 'Regenerate your bookmark prime token? Applications using your current token will stop working.'
            : 'Revoke your bookmark prime token? Applications using it will stop working.'
        }
        icon="pi pi-exclamation-triangle"
        acceptLabel="Confirm"
        rejectLabel="Cancel"
        defaultFocus="reject"
        accept={confirm}
      />
    </div>
  );
};

export const PrimeApiSettings = () => {
  const {
    outCommand,
    data: { map_slug },
  } = useMapRootState();
  return <PrimeTokenSettings key={map_slug} outCommand={outCommand} />;
};
