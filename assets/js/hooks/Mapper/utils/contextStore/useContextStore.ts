import { useCallback, useState } from 'react';

import { ContextStoreDataOpts, ProvideConstateDataReturnType, ContextStoreDataUpdate } from './types';

/**
 * Constrain T to `object`, so we can do Partial<T>, index by keys, etc.
 */
export const useContextStore = <T extends object>(
  initialValue: T,
  { notNeedRerender = false, handleBeforeUpdate, onAfterAUpdate }: ContextStoreDataOpts<T> = {},
): ProvideConstateDataReturnType<T> => {
  // CHANGED: Store everything in state, not in a ref
  const [store, setStore] = useState<T>(initialValue);

  const update: ContextStoreDataUpdate<T> = useCallback(
    (valOrFunc, force = false) => {
      setStore(prevStore => {
        const values = typeof valOrFunc === 'function' ? valOrFunc(prevStore) : valOrFunc;
        // values is `Partial<T>`

        // We'll create a copy for next so that we return a new reference
        const next = { ...prevStore };
        let didChange = false;

        // For each key in values
        Object.keys(values).forEach(k => {
          // Cast k to `keyof T` so we can index into `values` and `next`
          const key = k as keyof T;

          // If the key doesn't exist in prevStore, skip
          if (!(key in prevStore)) {
            return;
          }

          // If handleBeforeUpdate is defined and we are not forcing, call it
          if (handleBeforeUpdate && !force) {
            const newVal = values[key];
            const oldVal = next[key];
            const updateResult = handleBeforeUpdate(newVal, oldVal);

            if (!updateResult) {
              // Just assign the newVal
              (next[key] as T[keyof T]) = newVal as T[keyof T];
              didChange = didChange || newVal !== oldVal;
              return;
            }

            if (updateResult.prevent) {
              return; // skip
            }

            // If there's an override `value`, use that
            if ('value' in updateResult) {
              const finalVal = updateResult.value as T[keyof T];
              (next[key] as T[keyof T]) = finalVal;
              didChange = didChange || finalVal !== oldVal;
            } else {
              // fallback: assign newVal
              (next[key] as T[keyof T]) = newVal as T[keyof T];
              didChange = didChange || newVal !== oldVal;
            }
          } else {
            // handleBeforeUpdate not defined OR force = true
            const newVal = values[key] as T[keyof T];
            const oldVal = next[key];
            (next[key] as T[keyof T]) = newVal;
            didChange = didChange || newVal !== oldVal;
          }
        });

        // If nothing changed or notNeedRerender is true, return old store
        if (!didChange && notNeedRerender) {
          return prevStore;
        }

        // onAfterAUpdate is called with the final store object
        onAfterAUpdate?.(next);

        // Return the new object reference
        return next;
      });
    },
    [handleBeforeUpdate, onAfterAUpdate, notNeedRerender],
  );

  return { update, ref: store };
};
