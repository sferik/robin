import { useEffect, useState } from "preact/hooks";

export interface Store<T> {
  get(): T;
  set(value: T): void;
  update(fn: (value: T) => T): void;
  subscribe(fn: () => void): () => void;
}

export function createStore<T>(initial: T): Store<T> {
  let value = initial;
  const subs = new Set<() => void>();
  return {
    get: () => value,
    set(next) {
      value = next;
      subs.forEach((f) => f());
    },
    update(fn) {
      this.set(fn(value));
    },
    subscribe(fn) {
      subs.add(fn);
      return () => {
        subs.delete(fn);
      };
    },
  };
}

export function useStore<T>(store: Store<T>): T {
  const [, rerender] = useState({});
  useEffect(() => store.subscribe(() => {
    rerender({});
  }), [store]);
  return store.get();
}
