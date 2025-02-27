import classes from './WdRadioButton.module.scss';
import { WithClassName } from '@/hooks/Mapper/types/common';
import clsx from 'clsx';
import React, { useMemo } from 'react';

let counter = 0;

export interface WdRadioButtonProps {
  label: React.ReactNode | string;
  classNameLabel?: string;
  value: string | number;
  name: string;
  checked: boolean;
  labelSide?: 'left' | 'right';
  onChange?: () => void;
  size?: 'xs' | 'm' | 'normal';
  disabled?: boolean;
  inactive?: boolean;
}

export const WdRadioButton = ({
  label,
  className,
  classNameLabel,
  // value is used for the component API but not in the implementation
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  value,
  name,
  checked,
  onChange,
  labelSide = 'right',
  size = 'normal',
  disabled = false,
  inactive = false,
}: WdRadioButtonProps & WithClassName) => {
  const id = useMemo(() => `radio-${name}-${(++counter).toString()}`, [name]);

  const handleClick = () => {
    if (!disabled && onChange) {
      onChange();
    }
  };

  const labelElement = (
    <label
      htmlFor={id}
      className={clsx(
        classes.Label,
        'select-none',
        {
          ['ml-1']: labelSide === 'right' && size === 'xs',
          ['mr-1']: labelSide === 'left' && size === 'xs',
          ['ml-1.5']: labelSide === 'right' && (size === 'normal' || size === 'm'),
          ['mr-1.5']: labelSide === 'left' && (size === 'normal' || size === 'm'),
        },
        classNameLabel,
      )}
    >
      {label}
    </label>
  );

  // Size based on the size prop
  const radioSize = size === 'xs' ? '14px' : size === 'm' ? '16px' : '18px';
  const dotSize = size === 'xs' ? '6px' : size === 'm' ? '8px' : '10px';

  // Colors that exactly match WdCheckbox
  const uncheckedBorderColor = 'rgb(56, 56, 56)';
  const uncheckedBackgroundColor = 'rgb(18, 18, 18)';
  const checkedBorderColor = 'rgb(100, 181, 246)';
  const checkedBackgroundColor = 'rgb(100, 181, 246)';
  const dotColor = 'rgba(254, 254, 254, 0.87)';
  
  // Determine opacity based on disabled and inactive states
  const opacityValue = disabled ? 0.5 : inactive ? 0.7 : 1;

  return (
    <div className={clsx(className, 'flex items-center')}>
      {labelSide === 'left' && labelElement}
      <div
        id={id}
        role="radio"
        aria-checked={checked}
        tabIndex={disabled ? -1 : 0}
        onClick={handleClick}
        onKeyDown={e => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            handleClick();
          }
        }}
        className={clsx(
          classes.RadioButtonRoot,
          {
            [classes.SizeNormal]: size === 'normal',
            [classes.SizeM]: size === 'm',
            [classes.SizeXS]: size === 'xs',
            [classes.Disabled]: disabled,
            [classes.Inactive]: inactive && !disabled,
            [classes.Checked]: checked,
          },
          'custom-radio-button',
        )}
        style={{
          width: radioSize,
          height: radioSize,
          borderRadius: '50%',
          border: `2px solid ${checked ? checkedBorderColor : uncheckedBorderColor}`,
          backgroundColor: checked ? checkedBackgroundColor : uncheckedBackgroundColor,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          cursor: disabled ? 'default' : 'pointer',
          opacity: opacityValue,
          transition: 'all 0.2s ease',
          position: 'relative',
        }}
      >
        {checked && (
          <div
            className="radio-dot"
            style={{
              width: dotSize,
              height: dotSize,
              borderRadius: '50%',
              backgroundColor: dotColor,
              position: 'absolute',
              left: '50%',
              top: '50%',
              transform: 'translate(-50%, -50%)',
            }}
          />
        )}
      </div>
      {labelSide === 'right' && labelElement}
    </div>
  );
};
