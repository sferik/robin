// Thin client for Robin's JSON API. Paths are relative to <base href>, so
// the dashboard works wherever it's mounted.
import { t } from "./i18n";
import { createStore } from "./store";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export const clusterStore = createStore<string>(localStorage.getItem("robin.cluster") ?? "");

export function setCluster(name: string): void {
  localStorage.setItem("robin.cluster", name);
  clusterStore.set(name);
}

export type Params = Record<string, string | number | undefined>;

export function apiUrl(path: string, params: Params = {}): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== "") q.set(k, String(v));
  const cluster = clusterStore.get();
  if (cluster) q.set("cluster", cluster);
  const qs = q.toString();
  return `api/${path}${qs ? `?${qs}` : ""}`;
}

async function handle<T>(res: Response): Promise<T> {
  const text = await res.text();
  let body: { error?: string };
  try {
    body = text ? (JSON.parse(text) as { error?: string }) : {};
  } catch {
    throw new ApiError(res.status, t("The server sent an unexpected response ({status}).", { status: res.status }));
  }
  if (!res.ok) throw new ApiError(res.status, body.error ?? t("Request failed ({status}).", { status: res.status }));
  return body as T;
}

export async function get<T>(path: string, params?: Params): Promise<T> {
  const res = await fetch(apiUrl(path, params), { headers: { accept: "application/json" }, credentials: "same-origin" });
  return handle<T>(res);
}

export async function send<T = unknown>(method: "POST" | "DELETE", path: string, body?: unknown, params?: Params): Promise<T> {
  const res = await fetch(apiUrl(path, params), {
    method,
    credentials: "same-origin",
    headers: { "content-type": "application/json", accept: "application/json", "x-robin-request": "1" },
    body: JSON.stringify(body), // undefined when there's no body
  });
  return handle<T>(res);
}

export const enc = encodeURIComponent;

// -- response types ---------------------------------------------------------

export interface Stats {
  processed: number; failed: number; scheduled: number; retries: number; dead: number;
  processes: number; busy: number; enqueued: number; default_latency: number;
}

export interface QueueRow { name: string; size: number; latency: number; paused: boolean }

export interface Job {
  jid: string; class: string; wrapper: string | null; queue: string; args: unknown[];
  created_at?: number; enqueued_at?: number; tags: string[]; bid?: string | null;
  error_class?: string | null; error_message?: string | null; failures?: number | null;
  failed_at?: number | null; retried_at?: number | null; encrypted: boolean;
  id?: string; at?: number; payload?: Record<string, unknown>; backtrace?: string[] | null;
  /** Rows added with Robin::Web.job_info (job pages only; missing from older servers). */
  info?: InfoRow[];
}

/** A row added with Robin::Web.job_info; the server only sends http(s) and path links. */
export interface InfoRow { label: string; text: string; href?: string }

export interface Point { t: string; s: number; f: number; ms: number }

export interface Session {
  title: string; brand_color: string | null; version: string; read_only: boolean;
  permissions: Record<string, boolean>; clusters: string[]; cluster: string;
  features: { batches: boolean; limiters: boolean; cron: boolean }; stream_interval: number; live_updates: "poll" | "stream";
  /** Pages added with Robin::Web.register (missing from older servers). */
  extensions?: ExtensionInfo[];
}

export interface ProcessInfo {
  identity: string; hostname: string; pid: number; tag?: string; labels?: string[]; started_at?: number;
  version?: string; env?: string; embedded?: boolean; concurrency: number; queues: string[];
  busy: number; beat: number; quiet: boolean; leader: boolean; rss_kb: number; rtt_us: number;
  capsules?: Record<string, { concurrency: number; queues: Record<string, number> }>;
  /** Percent of the possible time threads spent waiting for the GVL (missing where unmeasured, e.g. JRuby). */
  gvl_contention?: number | null;
}

/** What a job last reported with progress!; `pct` is null when it can't tell (an iterable job's `meta.iterations` then counts what it has done). */
export interface Progress { pct: number | null; msg?: string | null; at: number; meta?: { iterations?: number } & Record<string, unknown> }

export interface Work {
  identity: string; thread: string; queue: string; run_at: number; job: Job;
  progress?: Progress | null;
}

export interface Batch {
  bid: string; description?: string | null; total: number; pending: number; failures: number;
  created_at?: number; complete_at?: number | null; success_at?: number | null; parent_bid?: string | null; cancelled_at?: number | null;
  callbacks?: unknown; failed_jobs?: { jid: string; error_class: string; error_message: string }[];
  children?: unknown[]; jids?: string[];
  /** Set with Robin::Batch#tags= (missing from older servers). */
  tags?: string[];
}

export interface Limiter {
  name: string; type: string; limit: number; interval?: number | null; used?: number | null;
  over_limit_count?: number | null; last_used_at?: number | null;
}

export interface CronJob {
  id: string; cron: string; class: string; queue: string; args: unknown[]; tz?: string | null;
  description?: string | null; next_at?: number | null; last_at?: number | null; last_jid?: string | null; paused: boolean;
}

export interface Profile {
  jid: string; class: string; queue: string | null; label: string | null; started_at: number;
  duration_ms: number; ok: boolean; bytes: number;
}

/** A value shown as text (never as HTML). */
export type Cell = string | number | boolean | null;

export type Block =
  | { type: "heading"; text: string }
  | { type: "text"; text: string }
  | { type: "stats"; items: { label: string; value: Cell }[] }
  | { type: "table"; columns: string[]; rows: Cell[][] }
  | { type: "actions"; items: { label: string; action: string; confirm?: string; danger?: boolean }[] };

/** An extension: its title (and translations of it), and its own script and stylesheet, if any. */
export interface ExtensionInfo { slug: string; title: string; titles?: Record<string, string>; script?: string; stylesheet?: string }

export interface ExtensionPage extends ExtensionInfo {
  blocks: Block[];
  /** The extension's translations for the dashboard's language (English text → translation). */
  messages?: Record<string, string>;
}
