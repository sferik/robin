// Shared test doubles. Nothing here may import from src/: source modules
// are loaded through load() so import failures count as test failures.
import { vi } from "vitest";

export const NOW = Date.UTC(2026, 9, 14, 9, 30, 0);

/** Freeze Date (only) at NOW; timers keep running normally. */
export function freezeTime(now = NOW): void {
  vi.useFakeTimers({ now, toFake: ["Date"] });
}

/** A JSON-able value, a Response, or a function of the request returning either (or a promise of one). */
export type Handler = unknown;

export interface ApiCall { method: string; path: string; url: URL; body: unknown; headers: Record<string, string> }

/** A JSON response with a status code, for handlers that need one. */
export function reply(status: number, body: unknown): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
}

/**
 * Stub fetch for the dashboard API. Routes are keyed by "METHOD path"
 * (or just "path" for GET), with the path relative to /robin/api/.
 * Unknown routes answer 404.
 */
export function mockApi(routes: Record<string, Handler> = {}) {
  const calls: ApiCall[] = [];
  const fetch = vi.fn((input: string, init: RequestInit = {}) => {
    const url = new URL(input, "http://localhost/robin/"); // where <base href> points in the real page
    const method = init.method ?? "GET";
    const path = url.pathname.replace(/^\/robin\/api\//, "");
    const body: unknown = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    calls.push({ method, path, url, body, headers: init.headers as Record<string, string> });
    const handler = routes[`${method} ${path}`] ?? (method === "GET" ? routes[path] : undefined);
    if (handler === undefined) return Promise.resolve(reply(404, { error: `No route for ${method} ${path}` }));
    const value = typeof handler === "function" ? (handler as (u: URL, i: RequestInit) => unknown)(url, init) : handler;
    return Promise.resolve(value).then((v) => (v instanceof Response ? v.clone() : reply(200, v)));
  });
  vi.stubGlobal("fetch", fetch);
  return {
    fetch,
    calls,
    routes,
    /** Calls made to `path` (optionally only with `method`). */
    to(path: string, method?: string) {
      return calls.filter((c) => c.path === path && (method === undefined || c.method === method));
    },
  };
}

/** A controllable stand-in for the browser's EventSource. */
export class FakeEventSource {
  static instances: FakeEventSource[] = [];
  listeners: Record<string, ((e: MessageEvent<string>) => void)[]> = {};
  onerror: (() => void) | null = null;
  closed = false;

  constructor(public url: string) {
    FakeEventSource.instances.push(this);
  }

  addEventListener(type: string, fn: (e: MessageEvent<string>) => void) {
    (this.listeners[type] ??= []).push(fn);
  }

  close() {
    this.closed = true;
  }

  emit(type: string, data: unknown) {
    for (const fn of this.listeners[type] ?? []) fn(new MessageEvent(type, { data: JSON.stringify(data) }));
  }

  fail() {
    this.onerror?.();
  }

  static latest(): FakeEventSource {
    return FakeEventSource.instances[FakeEventSource.instances.length - 1];
  }
}

/** Give every element a width (charts measure themselves) and report resizes. */
export function stubLayout(width = 640) {
  const observers: { cb: ResizeObserverCallback; el?: Element; disconnected: boolean }[] = [];
  vi.stubGlobal(
    "ResizeObserver",
    class {
      entry: (typeof observers)[number];
      constructor(cb: ResizeObserverCallback) {
        this.entry = { cb, disconnected: false };
        observers.push(this.entry);
      }
      observe(el: Element) {
        this.entry.el = el;
      }
      disconnect() {
        this.entry.disconnected = true;
      }
      unobserve() {
        // not used
      }
    },
  );
  vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(width);
  return {
    observers,
    /** Report a new width to every live observer. */
    resize(next: number) {
      for (const o of observers) {
        if (!o.disconnected) o.cb([{ contentRect: { width: next } } as ResizeObserverEntry], {} as ResizeObserver);
      }
    },
  };
}

export const SESSION = {
  title: "Robin",
  brand_color: null,
  version: "0.1.0",
  read_only: false,
  permissions: {
    read: true, retry: true, edit: true, delete: true, kill: true, pause: true, cancel: true,
    process_control: true, enqueue: true, limiters: true, batches: true, profiles: true, extensions: true,
  },
  clusters: ["default"],
  cluster: "default",
  features: { batches: true, limiters: true, cron: true },
  stream_interval: 2,
  live_updates: "poll" as "poll" | "stream",
  extensions: [] as { slug: string; title: string; titles?: Record<string, string> }[],
};

export function session(overrides: Partial<typeof SESSION> = {}) {
  return { ...SESSION, ...overrides, permissions: { ...SESSION.permissions, ...overrides.permissions } };
}

/** Session with every permission denied except reading. */
export function readOnlySession() {
  const permissions = Object.fromEntries(Object.keys(SESSION.permissions).map((k) => [k, k === "read"]));
  return { ...SESSION, read_only: true, permissions: permissions as typeof SESSION.permissions };
}

export const STATS = {
  processed: 38_900_000, failed: 350_600, scheduled: 48, retries: 36, dead: 14,
  processes: 4, busy: 15, enqueued: 4581, default_latency: 26,
};

export function job(overrides: Record<string, unknown> = {}) {
  return {
    jid: "a1b2c3d4e5f6a1b2c3d4e5f6", class: "HardJob", wrapper: null, queue: "default", args: [1, "two"],
    created_at: NOW - 60_000, enqueued_at: NOW - 30_000, tags: [], bid: null, error_class: null, error_message: null,
    failures: null, failed_at: null, retried_at: null, encrypted: false, ...overrides,
  };
}

/** A promise you resolve or reject from the outside. */
export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** A fake prefers-color-scheme media query you can flip. */
export function stubColorScheme(dark: boolean) {
  const listeners: (() => void)[] = [];
  const query = {
    matches: dark,
    addEventListener: (type: string, fn: () => void) => {
      if (type === "change") listeners.push(fn);
    },
  };
  vi.stubGlobal("matchMedia", vi.fn(() => query));
  return {
    query,
    set(next: boolean) {
      query.matches = next;
      for (const fn of listeners) fn();
    },
  };
}

/** Let pending promise callbacks (fetch responses, state updates) run. */
export async function flush(times = 5): Promise<void> {
  for (let i = 0; i < times; i++) await new Promise((r) => setTimeout(r, 0));
}
