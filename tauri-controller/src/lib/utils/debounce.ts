export type DebouncedFn<T extends (...args: any[]) => any> = ((...args: Parameters<T>) => void) & { cancel(): void };

export function debounce<T extends (...args: any[]) => any>(
  func: T,
  wait: number
): DebouncedFn<T> {
  let timeout: ReturnType<typeof setTimeout> | null = null;

  const executedFunction = function (...args: Parameters<T>) {
    const later = () => {
      timeout = null;
      func(...args);
    };

    if (timeout !== null) {
      clearTimeout(timeout);
    }
    timeout = setTimeout(later, wait);
  } as DebouncedFn<T>;

  executedFunction.cancel = () => {
    if (timeout !== null) {
      clearTimeout(timeout);
      timeout = null;
    }
  };

  return executedFunction;
}
