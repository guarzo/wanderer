import { act } from 'react';
import { createRoot, Root } from 'react-dom/client';
import { PrimeReactProvider } from 'primereact/api';
import { LocationApiAdminSettings } from './LocationApiAdminSettings';

const command = jest.fn();
let mapSlug = 'map-one';
jest.mock('@/hooks/Mapper/mapRootProvider', () => ({
  useMapRootState: () => ({ outCommand: command, data: { map_slug: mapSlug } }),
}));

const reply = (enabled = false, available = true) => ({ success: true, available, enabled });
let container: HTMLDivElement;
let root: Root;
const styleContainer = document.createElement('div');
const render = async () => {
  await act(async () => {
    root.render(
      <PrimeReactProvider value={{ ripple: false, cssTransition: false, styleContainer }}>
        <LocationApiAdminSettings />
      </PrimeReactProvider>,
    );
  });
};
const toggle = () => container.querySelector('input') as HTMLInputElement;
const retry = async () => {
  await act(async () => (container.querySelector('button') as HTMLButtonElement).click());
};

beforeEach(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  mapSlug = 'map-one';
  command.mockReset().mockResolvedValue(reply());
  container = document.createElement('div');
  document.body.appendChild(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  jest.useRealTimers();
});

it('loads map opt-in separately from user settings and labels the switch', async () => {
  await render();
  expect(command.mock.calls).toEqual([[{ type: 'get_location_api_settings', data: null }]]);
  expect(toggle().checked).toBe(false);
  expect(toggle().disabled).toBe(false);
  expect(container.querySelector(`label[for="${toggle().id}"]`)).not.toBeNull();
});

it('enables with only a boolean payload and waits for the server before showing success', async () => {
  await render();
  let resolve!: (value: ReturnType<typeof reply>) => void;
  command.mockReturnValueOnce(
    new Promise(res => {
      resolve = res;
    }),
  );
  await act(async () => toggle().click());
  expect(toggle().disabled).toBe(true);
  expect(toggle().checked).toBe(false);
  await act(async () => toggle().click());
  expect(command.mock.calls).toEqual([
    [{ type: 'get_location_api_settings', data: null }],
    [{ type: 'set_location_api_enabled', data: { enabled: true } }],
  ]);
  await act(async () => resolve(reply(true)));
  expect(toggle().checked).toBe(true);
  expect(toggle().disabled).toBe(false);
});

it('temporarily disables without destructive confirmation or a group-wide revocation event', async () => {
  command.mockResolvedValueOnce(reply(true)).mockResolvedValueOnce(reply(false));
  await render();
  await act(async () => toggle().click());
  expect(command.mock.calls).toEqual([
    [{ type: 'get_location_api_settings', data: null }],
    [{ type: 'set_location_api_enabled', data: { enabled: false } }],
  ]);
  expect(toggle().checked).toBe(false);
  expect(document.querySelector('[role="alertdialog"]')).toBeNull();
  expect(container.textContent).toContain('temporarily');
});

it('cannot enable while globally unavailable but can still turn off the stored opt-in', async () => {
  command.mockResolvedValueOnce(reply(false, false));
  await render();
  expect(toggle().disabled).toBe(true);
  command.mockResolvedValueOnce(reply(true, false));
  await retry();
  expect(toggle().checked).toBe(true);
  expect(toggle().disabled).toBe(false);
  command.mockResolvedValueOnce(reply(false, false));
  await act(async () => toggle().click());
  expect(command).toHaveBeenLastCalledWith({ type: 'set_location_api_enabled', data: { enabled: false } });
  expect(toggle().checked).toBe(false);
});

it.each(['forbidden', 'service_unavailable'])(
  'disables actions after a %s error and retries authoritative settings',
  async code => {
    await render();
    command.mockResolvedValueOnce({ success: false, error: 'Safe message', code });
    await act(async () => toggle().click());
    expect(toggle().disabled).toBe(true);
    expect(container.querySelector('[role="alert"]')).not.toBeNull();
    command.mockResolvedValueOnce(reply(true));
    await retry();
    expect(command).toHaveBeenLastCalledWith({ type: 'get_location_api_settings', data: null });
    expect(toggle().checked).toBe(true);
  },
);

it('handles rejected requests without exposing details', async () => {
  command.mockRejectedValueOnce(new Error('private-error'));
  await render();
  expect(toggle().disabled).toBe(true);
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  expect(container.textContent).not.toContain('private-error');
});

it('ignores an old-map update after map change', async () => {
  await render();
  let resolve!: (value: ReturnType<typeof reply>) => void;
  command.mockReturnValueOnce(
    new Promise(res => {
      resolve = res;
    }),
  );
  await act(async () => toggle().click());
  mapSlug = 'map-two';
  command.mockResolvedValueOnce(reply(false));
  await render();
  await act(async () => resolve(reply(true)));
  expect(toggle().checked).toBe(false);
});

it('recovers from a lost reply without applying its late result', async () => {
  jest.useFakeTimers();
  let resolve!: (value: ReturnType<typeof reply>) => void;
  command.mockReturnValueOnce(
    new Promise(res => {
      resolve = res;
    }),
  );
  await render();
  await act(async () => jest.advanceTimersByTime(15_000));
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  command.mockResolvedValueOnce(reply(false));
  await retry();
  await act(async () => resolve(reply(true)));
  expect(toggle().checked).toBe(false);
});
