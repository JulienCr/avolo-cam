import { writable } from 'svelte/store';

export type ToastType = 'success' | 'error' | 'info';

export interface Toast {
  id: number;
  message: string;
  type: ToastType;
}

let nextId = 0;

export const toasts = writable<Toast[]>([]);

export function toast(message: string, type: ToastType = 'info', duration = 3000) {
  const id = nextId++;
  toasts.update((t) => [...t, { id, message, type }]);
  setTimeout(() => {
    toasts.update((t) => t.filter((x) => x.id !== id));
  }, duration);
}

export function toastSuccess(message: string) {
  toast(message, 'success');
}

export function toastError(message: string) {
  toast(message, 'error', 5000);
}
