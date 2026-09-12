export type LocationApiSettings = { available: boolean; enabled: boolean };
export type PersonalLocationApiToken = { id: string; generation: number; value: string };
type LocationApiError = { success: false; error: string; code: string };
export type LocationApiSettingsReply = ({ success: true } & LocationApiSettings) | LocationApiError;
export type LocationApiTokenReply =
  | ({ success: true; token: PersonalLocationApiToken | null } & LocationApiSettings)
  | LocationApiError;

export const locationApiError = (code?: string) => {
  switch (code) {
    case 'forbidden':
      return 'You no longer have permission to use these Location API controls.';
    case 'disabled':
      return 'The Location API is currently disabled.';
    case 'conflict':
      return 'Your token changed elsewhere. Retry to load the current token.';
    default:
      return 'Unable to complete the Location API request. Please retry.';
  }
};

// LiveView replies have no rejection timeout. Release the controls so a lost reply can be retried.
export const withLocationApiTimeout = async <T>(request: Promise<T>): Promise<T> => {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      request,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error('Location API request timed out')), 15_000);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
};
