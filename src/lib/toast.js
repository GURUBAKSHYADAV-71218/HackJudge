const listeners = new Set();

export function toast(message) {
  for (const listener of listeners) listener(String(message));
}

export function subscribeToToasts(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
