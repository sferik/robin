// Formatting helpers, in the dashboard's current language.
import { locale, t } from "./i18n";

const formats = new Map<string, Intl.NumberFormat>();

/** A number format for the current language, made once per language and options. */
function format(options: Intl.NumberFormatOptions = {}): Intl.NumberFormat {
  const key = `${locale()} ${JSON.stringify(options)}`;
  let f = formats.get(key);
  if (!f) formats.set(key, (f = new Intl.NumberFormat(locale(), options)));
  return f;
}

/** `n` with exactly `digits` decimals and no grouping ("1024.5"; "1024,5" in German). */
export const fixed = (n: number, digits: number): string =>
  format({ minimumFractionDigits: digits, maximumFractionDigits: digits, useGrouping: false }).format(n);

/** 1234 → "1,234"; 1234567 → "1.2M" when `short` is set. */
export function num(n: number | null | undefined, short = false): string {
  if (n == null || Number.isNaN(n)) return "–";
  if (short && Math.abs(n) >= 10_000) return format({ notation: "compact", maximumFractionDigits: 1 }).format(n);
  return format().format(Math.round(n));
}

/** Seconds → "850 ms", "4.2 s", "3 m 10 s", "2 h 5 m", "3 d 4 h". */
export function duration(seconds: number | null | undefined): string {
  if (seconds == null || Number.isNaN(seconds)) return "–";
  const s = Math.max(0, seconds);
  if (s < 1) return t("{n} ms", { n: Math.round(s * 1000) });
  if (s < 60) return t("{n} s", { n: s < 10 ? fixed(s, 1) : Math.round(s) });
  const m = Math.floor(s / 60);
  if (m < 60) return t("{m} m {s} s", { m, s: Math.round(s % 60) });
  const h = Math.floor(m / 60);
  if (h < 24) return t("{h} h {m} m", { h, m: m % 60 });
  const d = Math.floor(h / 24);
  return t("{d} d {h} h", { d: num(d), h: h % 24 });
}

/** Milliseconds → compact duration ("120 ms", "1.5 s"). */
export function ms(value: number | null | undefined): string {
  if (value == null || Number.isNaN(value)) return "–";
  if (value < 1) return t("{n} ms", { n: fixed(value, 2) });
  return duration(value / 1000);
}

// [unit, seconds per unit, use this unit below this many seconds]
const UNITS: [Intl.RelativeTimeFormatUnit, number, number][] = [
  ["second", 1, 60],
  ["minute", 60, 3600],
  ["hour", 3600, 86400],
  ["day", 86400, 86400 * 30],
  ["month", 86400 * 30, 86400 * 365],
  ["year", 86400 * 365, Infinity],
];

/** Epoch ms → "in 5 minutes" / "3 hours ago" relative to `now`. */
export function relative(at: number | null | undefined, now = Date.now()): string {
  if (!at) return "–";
  const diff = (at - now) / 1000;
  const abs = Math.abs(diff);
  if (abs < 5) return t("just now");
  const [unit, size] = UNITS.find(([, , limit]) => abs < limit)!;
  return new Intl.RelativeTimeFormat(locale(), { numeric: "auto" }).format(Math.round(diff / size), unit);
}

/** Epoch ms → "2026-10-14 09:30:12" in local time. */
export function absolute(at: number | null | undefined): string {
  if (!at) return "";
  const d = new Date(at);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** KB → "512 MB". */
export function bytesKb(kb: number | null | undefined): string {
  if (!kb) return "–";
  if (kb < 1024) return t("{n} KB", { n: kb });
  if (kb < 1024 * 1024) return t("{n} MB", { n: fixed(kb / 1024, kb < 10240 ? 1 : 0) });
  return t("{n} GB", { n: fixed(kb / 1024 / 1024, 1) });
}

/** Robin metric stamps ("202610140930" UTC minute or "2026101409" hour) → epoch ms. */
export function stampToMs(stamp: string): number {
  const y = +stamp.slice(0, 4), mo = +stamp.slice(4, 6) - 1, d = +stamp.slice(6, 8);
  // Hour stamps have no minutes: slicing past the end gives "" and +"" is 0.
  const h = +stamp.slice(8, 10), mi = +stamp.slice(10, 12);
  return Date.UTC(y, mo, d, h, mi);
}

/** Short, readable preview of (JSON-decoded) job arguments, truncated to `max` characters. */
export function argsPreview(args: unknown[], max = 120): string {
  const s = args.map((a) => JSON.stringify(a)).join(", ");
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

export function pct(part: number, whole: number): number {
  return whole > 0 ? Math.min(100, Math.max(0, (part / whole) * 100)) : 0;
}

/** Process identity "host:pid:suffix" → {host, pid}. */
export function splitIdentity(identity: string): { host: string; pid: string } {
  const parts = identity.split(":");
  return { host: parts.slice(0, -2).join(":") || identity, pid: parts[parts.length - 2] ?? "" };
}

/** Pick "nice" axis ticks for 0..max. */
export function niceTicks(max: number, count = 4): number[] {
  if (max <= 0) return [0];
  const raw = max / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  // raw / mag is in [1, 10), so one of these always fits.
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw)!;
  // Enough steps to reach max; the epsilon absorbs float error (0.3 / 0.1 is 2.9999999999999996).
  const steps = Math.ceil(max / step - 1e-9);
  return Array.from({ length: steps + 1 }, (_, i) => Math.round(i * step * 1e6) / 1e6);
}
