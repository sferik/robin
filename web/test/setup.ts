import { cleanup } from "@testing-library/preact";
import { afterEach, vi } from "vitest";

// Node 26 defines its own (disabled) Web Storage globals, which can shadow
// the DOM environment's depending on the worker pool. Install a plain
// in-memory Storage so every run behaves the same.
class MemoryStorage implements Storage {
  #items = new Map<string, string>();
  get length() {
    return this.#items.size;
  }
  clear() {
    this.#items.clear();
  }
  getItem(key: string) {
    return this.#items.get(key) ?? null;
  }
  key(index: number) {
    return [...this.#items.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.#items.delete(key);
  }
  setItem(key: string, value: string) {
    this.#items.set(key, value);
  }
}

for (const name of ["localStorage", "sessionStorage"]) {
  Object.defineProperty(globalThis, name, { value: new MemoryStorage(), configurable: true, writable: true });
}

afterEach(() => {
  cleanup();
  localStorage.clear();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
