import { act, useState } from 'react';
import { createRoot, Root } from 'react-dom/client';
import { PrimeReactProvider } from 'primereact/api';
import { MapSettingsComp } from './MapSettings';

const command = jest.fn();
const setUserRemoteSettings = jest.fn();
let isAdmin = false;
let mapSlug = 'map-one';
jest.mock('@/hooks/Mapper/mapRootProvider', () => ({
  useMapRootState: () => ({
    outCommand: command,
    data: { map_slug: mapSlug, clientEnv: { intelSharingEnabled: false } },
    storedSettings: { getSettingsForExport: () => undefined },
  }),
}));
jest.mock('@/hooks/Mapper/mapRootProvider/hooks/api', () => ({ useMapCheckPermissions: () => isAdmin }));
jest.mock('./MapSettingsProvider', () => ({
  useMapSettings: () => ({ renderSettingItem: () => null, setUserRemoteSettings, settings: {} }),
}));
// Other settings panels are unrelated to this contract. Keep the real dialog, tabs, and API controls.
jest.mock('./constants.ts', () => ({
  CONNECTIONS_CHECKBOXES_PROPS: [],
  SIGNATURES_CHECKBOXES_PROPS: [],
  SYSTEMS_CHECKBOXES_PROPS: [],
}));
jest.mock('./components/CommonSettings', () => ({ CommonSettings: () => null }));
jest.mock('./components/WidgetsSettings', () => ({ WidgetsSettings: () => null }));
jest.mock('./components/BookmarksSettings', () => ({ BookmarksSettings: () => null }));
jest.mock('./components/ImportExport', () => ({ ImportExport: () => null }));
jest.mock('./components/ServerSettings', () => ({ ServerSettings: () => null }));
jest.mock('./components/IntelSettings', () => ({ IntelSettings: () => null }));
jest.mock('@/hooks/Mapper/helpers', () => ({
  callToastError: jest.fn(),
  callToastSuccess: jest.fn(),
  callToastWarn: jest.fn(),
}));
jest.mock('@/hooks/Mapper/components/helpers', () => ({ parseMapUserSettings: () => ({}) }));
jest.mock('@/hooks/Mapper/components/hooks', () => ({ useDetectSettingsChanged: () => false }));
jest.mock('@/hooks/Mapper/hooks', () => ({ useConfirmPopup: () => ({ cfRef: { current: null }, cfVisible: false }) }));
// Isolate the legacy default-settings button's non-forwarding ref. API controls use real WdButton directly.
jest.mock('@/hooks/Mapper/components/ui-kit', () => ({ WdButton: jest.requireActual('primereact/button').Button }));

let root: Root;
let container: HTMLDivElement;
const styleContainer = document.createElement('div');
const Host = () => {
  const [visible, setVisible] = useState(true);
  return <MapSettingsComp visible={visible} onHide={() => setVisible(false)} />;
};
const render = async () => {
  await act(async () => {
    root.render(
      <PrimeReactProvider value={{ ripple: false, styleContainer }}>
        <Host />
      </PrimeReactProvider>,
    );
  });
  // Dialog's onShow fires after the real 300ms .p-dialog-enter-active transition.
  // Poll for its observable effect instead of sleeping past it.
  await act(async () => {
    const deadline = Date.now() + 2000;
    while (!setUserRemoteSettings.mock.calls.length && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  });
  expect(setUserRemoteSettings).toHaveBeenCalled();
};
const tab = (name: string) =>
  Array.from(document.querySelectorAll('[role="tab"]')).find(el => el.textContent === name) as HTMLElement | undefined;
const openTab = async (name: string) => {
  const target = tab(name);
  expect(target).toBeDefined();
  await act(async () => target!.click());
};
const input = () => document.querySelector('input[readonly]') as HTMLInputElement | null;

beforeEach(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  isAdmin = false;
  mapSlug = 'map-one';
  setUserRemoteSettings.mockClear();
  command.mockReset().mockImplementation(async ({ type }) => {
    switch (type) {
      case 'get_user_settings':
        return { user_settings: { bookmark_name_format: 'example' } };
      case 'get_default_settings':
        return { default_settings: null };
      case 'get_location_api_token':
        return {
          success: true,
          available: true,
          enabled: true,
          token: { id: 'own', generation: 1, value: 'private-token' },
        };
      case 'get_location_api_settings':
        return { success: true, available: true, enabled: false };
      default:
        throw new Error(`Unexpected contract command ${type}`);
    }
  });
  container = document.createElement('div');
  document.body.appendChild(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

it('offers personal tokens to viewers without exposing the admin tab or fetching tokens in generic settings', async () => {
  await render();
  expect(tab('Admin Settings')).toBeUndefined();
  expect(command).not.toHaveBeenCalledWith({ type: 'get_location_api_token', data: null });
  await openTab('Location API');
  expect(input()?.value).toBe('private-token');
  expect(setUserRemoteSettings.mock.calls).toEqual([[{ bookmark_name_format: 'example' }]]);
  expect(command.mock.calls.map(([event]) => event.type)).not.toContain('update_user_settings');
  expect(localStorage.length).toBe(0);
});

it('places the opt-in only inside the existing admin settings panel', async () => {
  isAdmin = true;
  await render();
  expect(tab('Location API')).toBeDefined();
  await openTab('Admin Settings');
  expect(document.querySelector('input[role="switch"]')).not.toBeNull();
  expect(command).toHaveBeenCalledWith({ type: 'get_location_api_settings', data: null });
  expect(command).not.toHaveBeenCalledWith({ type: 'get_location_api_token', data: null });
});

it('removes the secret when the dialog closes even if its host remains mounted', async () => {
  await render();
  await openTab('Location API');
  expect(input()?.value).toBe('private-token');
  const close = document.querySelector('button.p-dialog-header-close') as HTMLButtonElement;
  await act(async () => close.click());
  expect(input()).toBeNull();
});

it('discards personal state on tab exit and refetches after an admin disable', async () => {
  isAdmin = true;
  await render();
  await openTab('Location API');
  expect(input()?.value).toBe('private-token');
  await openTab('Admin Settings');
  expect(input()).toBeNull();
  command.mockResolvedValueOnce({ success: true, available: true, enabled: false, token: null });
  await openTab('Location API');
  expect(input()?.value).toBe('');
  expect(command.mock.calls.filter(([event]) => event.type === 'get_location_api_token')).toHaveLength(2);
});
