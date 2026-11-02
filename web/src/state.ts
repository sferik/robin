import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { apiUrl, clusterStore, get, type Params, type Session, type Stats } from "./api";
import { createStore, useStore } from "./store";

// -- session ----------------------------------------------------------------

export const sessionStore = createStore<Session | null>(null);

export async function loadSession(): Promise<void> {
  sessionStore.set(await get<Session>("session"));
}

export function can(action: string): boolean {
  return sessionStore.get()?.permissions[action] === true;
}

// -- live stats: polling by default, server-sent events when enabled -------

export interface LiveStats { stats: Stats; queues: Record<string, number>; at: number }

export const liveStore = createStore<LiveStats | null>(null);
/** Recent samples of processed/failed totals, for the realtime chart. */
export const pulseStore = createStore<{ at: number; processed: number; failed: number }[]>([]);
export const pausedStore = createStore<boolean>(localStorage.getItem("robin.paused") === "1");
export const connectionStore = createStore<"live" | "polling" | "offline">("live");

/** Streaming gives up and falls back to polling after this many errors. */
export const MAX_STREAM_FAILURES = 3;

let source: EventSource | null = null;
let pollTimer: ReturnType<typeof setInterval> | undefined;
let failures = 0;

function accept(data: LiveStats): void {
  liveStore.set(data);
  pulseStore.update((s) => [...s.slice(-89), { at: data.at, processed: data.stats.processed, failed: data.stats.failed }]);
}

function stopLive(): void {
  source?.close();
  source = null;
  clearInterval(pollTimer);
}

function startPolling(): void {
  const session = sessionStore.get()!;
  connectionStore.set(session.live_updates === "stream" ? "polling" : "live");
  const tick = () => {
    get<LiveStats>("stats").then(accept, () => connectionStore.set("offline"));
  };
  tick();
  pollTimer = setInterval(tick, Math.max(1, session.stream_interval) * 1000);
}

/** (Re)start live updates for the current session and cluster. */
export function startLive(): void {
  stopLive();
  if (pausedStore.get()) return;
  if (sessionStore.get()!.live_updates !== "stream" || failures >= MAX_STREAM_FAILURES) {
    startPolling();
    return;
  }
  const stream = new EventSource(apiUrl("stream"));
  source = stream;
  stream.addEventListener("stats", (e) => {
    failures = 0;
    connectionStore.set("live");
    accept(JSON.parse((e as MessageEvent<string>).data) as LiveStats);
  });
  stream.onerror = () => {
    failures += 1;
    if (failures >= MAX_STREAM_FAILURES) startLive();
  };
}

export function setPaused(paused: boolean): void {
  localStorage.setItem("robin.paused", paused ? "1" : "0");
  pausedStore.set(paused);
  startLive();
}

clusterStore.subscribe(() => {
  pulseStore.set([]);
  liveStore.set(null);
  loadSession().then(startLive, () => connectionStore.set("offline"));
});

// -- theme ------------------------------------------------------------------

export type Theme = "light" | "dark" | "system";
export const themeStore = createStore<Theme>((localStorage.getItem("robin.theme") ?? "system") as Theme);
const darkQuery = matchMedia("(prefers-color-scheme: dark)");

export function applyTheme(): void {
  const t = themeStore.get();
  const dark = t === "dark" || (t === "system" && darkQuery.matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

export function setTheme(t: Theme): void {
  localStorage.setItem("robin.theme", t);
  themeStore.set(t);
  applyTheme();
}

darkQuery.addEventListener("change", applyTheme);

// -- toasts -----------------------------------------------------------------

export interface Toast { id: number; message: string; kind: "ok" | "error" }
export const toastStore = createStore<Toast[]>([]);
let toastId = 0;

export function toast(message: string, kind: Toast["kind"] = "ok"): void {
  const id = ++toastId;
  toastStore.update((t) => [...t.slice(-3), { id, message, kind }]);
  setTimeout(() => {
    toastStore.update((t) => t.filter((x) => x.id !== id));
  }, kind === "error" ? 7000 : 3500);
}

// -- confirm dialog ---------------------------------------------------------

export interface ConfirmRequest {
  title: string; body?: string; action: string; danger?: boolean; resolve: (ok: boolean) => void;
}
export const confirmStore = createStore<ConfirmRequest | null>(null);

export function confirmAction(opts: Omit<ConfirmRequest, "resolve">): Promise<boolean> {
  return new Promise((resolve) => {
    confirmStore.set({ ...opts, resolve });
  });
}

// -- data hooks ---------------------------------------------------------------

export interface Resource<T> { data: T | null; error: string | null; reload: () => void }

/**
 * Fetch an API resource; refetch when the path, params or cluster change,
 * and every `refresh` seconds while live updates are on and the tab is visible.
 */
export function useResource<T>(path: string, params: Params = {}, refresh = 0): Resource<T> {
  const cluster = useStore(clusterStore);
  const paused = useStore(pausedStore);
  const [state, setState] = useState<{ data: T | null; error: string | null }>({ data: null, error: null });
  const query = JSON.stringify(params);
  const key = `${path}?${query}@${cluster}`;
  const keyRef = useRef(key);
  keyRef.current = key;

  const load = useCallback(() => {
    get<T>(path, JSON.parse(query) as Params).then(
      (data) => {
        if (keyRef.current === key) setState({ data, error: null });
      },
      (err: unknown) => {
        if (keyRef.current === key) setState((s) => ({ data: s.data, error: (err as Error).message }));
      },
    );
  }, [path, query, key]);

  useEffect(load, [load]);

  useEffect(() => {
    if (!refresh || paused) return undefined;
    const id = setInterval(() => {
      if (document.visibilityState === "visible") load();
    }, refresh * 1000);
    return () => {
      clearInterval(id);
    };
  }, [load, refresh, paused]);

  return { ...state, reload: load };
}

export { useStore };
