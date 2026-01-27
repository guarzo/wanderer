import { InputSwitch } from 'primereact/inputswitch';
import { Controller, useFormContext } from 'react-hook-form';
import { SystemSignature } from '@/hooks/Mapper/types';

export interface SignatureCriticalCheckboxProps {
  name: string;
  defaultValue?: boolean;
}

export const SignatureCriticalCheckbox = ({ name, defaultValue = false }: SignatureCriticalCheckboxProps) => {
  const { control } = useFormContext<SystemSignature>();

  return (
    <Controller
      // @ts-ignore
      name={name}
      control={control}
      defaultValue={defaultValue}
      render={({ field }) => {
        return <InputSwitch className="my-1" checked={!!field.value} onChange={e => field.onChange(e.value)} />;
      }}
    />
  );
};
