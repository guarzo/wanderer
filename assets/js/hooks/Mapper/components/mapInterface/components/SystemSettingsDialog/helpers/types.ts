// CustomSystemSettingsDialog.types.ts

export interface OwnerSuggestion {
  label: string;
  value: string;
  corporation?: boolean;
  alliance?: boolean;
  formatted: string;
  name: string;
  ticker: string;
  id: string;
  type: 'corp' | 'alliance';
}

export interface CustomSystemSettingsDialogProps {
  systemId: string;
  visible: boolean;
  setVisible: (visible: boolean) => void;
}
