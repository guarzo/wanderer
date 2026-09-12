import { act } from 'react';
import { createRoot, Root } from 'react-dom/client';
import { PrimeReactProvider } from 'primereact/api';
import { LocationApiSettings } from './LocationApiSettings';

const command = jest.fn();
let mapSlug = 'map-one';
jest.mock('@/hooks/Mapper/mapRootProvider', () => ({
  useMapRootState: () => ({ outCommand: command, data: { map_slug: mapSlug } }),
}));

const token = { id: 'own-token', generation: 1, value: 'personal-secret' };
const reply = (value: typeof token | null = token) => ({
  success: true,
  available: true,
  enabled: true,
  token: value,
});
const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

let container: HTMLDivElement;
let root: Root;
// JSDOM cannot parse PrimeReact's @layer CSS. Keep actual controls, but styles detached.
const styleContainer = document.createElement('div');
const render = async () => {
  await act(async () => {
    root.render(
      <PrimeReactProvider value={{ ripple: false, cssTransition: false, styleContainer }}>
        <LocationApiSettings />
      </PrimeReactProvider>,
    );
  });
};
const input = () => container.querySelector('input') as HTMLInputElement;
const button = (label: string) => {
  const found = Array.from(document.querySelectorAll('button')).find(b => b.textContent?.trim() === label);
  if (!found) throw new Error(`Missing button: ${label}`);
  return found;
};
const click = async (label: string) => {
  await act(async () => button(label).click());
};

beforeEach(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  mapSlug = 'map-one';
  command.mockReset().mockResolvedValue(reply());
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: jest.fn().mockResolvedValue(undefined) },
  });
  container = document.createElement('div');
  document.body.appendChild(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  jest.useRealTimers();
  jest.restoreAllMocks();
});

it('retrieves only the current user token without generating or submitting identity', async () => {
  await render();
  expect(command.mock.calls).toEqual([[{ type: 'get_location_api_token', data: null }]]);
  expect(input().value).toBe('personal-secret');
  expect(input().readOnly).toBe(true);
  expect(container.querySelector(`label[for="${input().id}"]`)).not.toBeNull();
  await click('Copy');
  expect(navigator.clipboard.writeText).toHaveBeenCalledWith('personal-secret');
  expect(container.textContent).toContain('Copied');
  expect(localStorage.length).toBe(0);
});

it('generates without a name and blocks duplicate clicks while waiting', async () => {
  command.mockResolvedValueOnce(reply(null));
  await render();
  const pending = deferred<ReturnType<typeof reply>>();
  command.mockReturnValueOnce(pending.promise);
  await click('Generate');
  expect(button('Generate').disabled).toBe(true);
  await click('Generate');
  expect(command.mock.calls).toEqual([
    [{ type: 'get_location_api_token', data: null }],
    [{ type: 'generate_location_api_token', data: null }],
  ]);
  await act(async () => pending.resolve(reply()));
  expect(input().value).toBe('personal-secret');
});

it.each([
  ['Regenerate', 'regenerate_location_api_token', { ...token, generation: 2, value: 'replacement-secret' }],
  ['Revoke', 'revoke_location_api_token', null],
] as const)('requires confirmation for %s and submits only its id and generation', async (label, type, next) => {
  await render();
  await click(label);
  expect(command).toHaveBeenCalledTimes(1);
  await click('Cancel');
  expect(input().value).toBe('personal-secret');
  expect(command).toHaveBeenCalledTimes(1);
  command.mockResolvedValueOnce(reply(next));
  await click(label);
  await click('Confirm');
  expect(command).toHaveBeenLastCalledWith({ type, data: { id: 'own-token', generation: 1 } });
  expect(input().value).toBe(next?.value ?? '');
});

it.each([
  { success: true, available: false, enabled: true, token: null },
  { success: true, available: true, enabled: false, token: null },
])('disables generation when unavailable or not opted in: %j', async response => {
  command.mockResolvedValueOnce(response);
  await render();
  expect(input().value).toBe('');
  expect(button('Generate').disabled).toBe(true);
  expect(button('Copy').disabled).toBe(true);
  expect(button('Retry').disabled).toBe(false);
});

it.each(['forbidden', 'disabled', 'service_unavailable'])(
  'clears plaintext on a %s error and supports retry',
  async code => {
    await render();
    command.mockResolvedValueOnce({ success: false, code, error: 'Safe server message' });
    await click('Regenerate');
    await click('Confirm');
    expect(input().value).toBe('');
    expect(button('Copy').disabled).toBe(true);
    expect(button('Generate').disabled).toBe(true);
    expect(container.querySelector('[role="alert"]')).not.toBeNull();
    command.mockResolvedValueOnce(reply());
    await click('Retry');
    expect(command).toHaveBeenLastCalledWith({ type: 'get_location_api_token', data: null });
    expect(input().value).toBe('personal-secret');
  },
);

it('clears the stale secret on conflict and refetches the current token before further actions', async () => {
  await render();
  const pending = deferred<ReturnType<typeof reply>>();
  command
    .mockResolvedValueOnce({ success: false, code: 'conflict', error: 'Token changed' })
    .mockReturnValueOnce(pending.promise);
  await click('Revoke');
  await click('Confirm');
  expect(input().value).toBe('');
  expect(button('Copy').disabled).toBe(true);
  expect(command).toHaveBeenLastCalledWith({ type: 'get_location_api_token', data: null });
  await act(async () => pending.resolve(reply({ ...token, generation: 2, value: 'current-secret' })));
  expect(input().value).toBe('current-secret');
});

it('clears the token on clipboard rejection without displaying or logging error details', async () => {
  await render();
  jest.mocked(navigator.clipboard.writeText).mockRejectedValueOnce(new Error('sensitive-error-value'));
  const log = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  await click('Copy');
  expect(input().value).toBe('');
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  expect(document.body.textContent).not.toContain('sensitive-error-value');
  expect(log).not.toHaveBeenCalled();
  log.mockRestore();
});

it('ignores an old map reply after switching maps', async () => {
  const old = deferred<ReturnType<typeof reply>>();
  command.mockReturnValueOnce(old.promise);
  await render();
  mapSlug = 'map-two';
  command.mockResolvedValueOnce(reply(null));
  await render();
  await act(async () => old.resolve(reply()));
  expect(input().value).toBe('');
  expect(button('Generate').disabled).toBe(false);
});

it('clears a displayed secret immediately on map change', async () => {
  await render();
  mapSlug = 'map-two';
  const pending = deferred<ReturnType<typeof reply>>();
  command.mockReturnValueOnce(pending.promise);
  await render();
  expect(input().value).toBe('');
  expect(button('Copy').disabled).toBe(true);
  await act(async () => pending.resolve(reply(null)));
});

it('ignores a reply after closing and does not reuse it when reopened', async () => {
  const old = deferred<ReturnType<typeof reply>>();
  command.mockReturnValueOnce(old.promise);
  await render();
  await act(async () => root.render(null));
  await act(async () => old.resolve(reply()));
  expect(document.body.textContent).not.toContain('personal-secret');
  command.mockResolvedValueOnce(reply(null));
  await render();
  expect(input().value).toBe('');
});

it('clears a secret after a rejected mutation and keeps error details private', async () => {
  await render();
  command.mockRejectedValueOnce(new Error('sensitive-error-value'));
  await click('Revoke');
  await click('Confirm');
  expect(input().value).toBe('');
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  expect(document.body.textContent).not.toContain('sensitive-error-value');
});

it('times out an unanswered request, allows retry, and ignores its late reply', async () => {
  jest.useFakeTimers();
  const old = deferred<ReturnType<typeof reply>>();
  command.mockReturnValueOnce(old.promise);
  await render();
  await act(async () => jest.advanceTimersByTime(15_000));
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  command.mockResolvedValueOnce(reply(null));
  await click('Retry');
  await act(async () => old.resolve(reply()));
  expect(input().value).toBe('');
  expect(button('Generate').disabled).toBe(false);
});
