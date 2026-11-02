import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { absolute, duration, num, relative } from "../format";
import { t } from "../i18n";
import { Link } from "./link";
import { confirmStore, toast, toastStore, useStore } from "../state";
import { Icon, type IconName } from "./icons";
import { setQuery } from "../router";

/** Re-render every `seconds` so relative times stay fresh. */
export function useNow(seconds = 15): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), seconds * 1000);
    return () => clearInterval(id);
  }, [seconds]);
  return now;
}

export function Time({ at }: { at?: number | null }) {
  const now = useNow();
  if (!at) return <span class="dim">–</span>;
  return (
    <time dateTime={new Date(at).toISOString()} title={absolute(at)}>
      {relative(at, now)}
    </time>
  );
}

export function Jid({ jid }: { jid?: string | null }) {
  if (!jid) return <span class="dim">–</span>;
  const copy = () => {
    // The Clipboard API only exists in secure contexts.
    const clipboard = navigator.clipboard as Clipboard | undefined;
    if (!clipboard) {
      toast(t("Copying needs HTTPS"), "error");
      return;
    }
    clipboard.writeText(jid).then(
      () => toast(t("Copied {jid}", { jid })),
      () => toast(t("Couldn't copy to the clipboard"), "error"),
    );
  };
  return (
    <button type="button" class="jid" title={t("Copy job ID")} onClick={copy}>
      {jid}
    </button>
  );
}

/** Queue latency with a status word, so meaning never rides on color alone. */
export function Latency({ seconds }: { seconds: number }) {
  if (seconds >= 300) return <span class="lat-bad" title={t("Jobs are waiting more than 5 minutes")}>{t("{time} behind", { time: duration(seconds) })}</span>;
  if (seconds >= 30) return <span class="lat-warn" title={t("Jobs are waiting more than 30 seconds")}>{t("{time} slow", { time: duration(seconds) })}</span>;
  return <span class="lat-ok">{duration(seconds)}</span>;
}

export function Empty({ title, children, icon = "gem" }: { title: string; children?: ComponentChildren; icon?: IconName }) {
  return (
    <div class="empty">
      <Icon name={icon} />
      <h3>{title}</h3>
      {children && <p>{children}</p>}
    </div>
  );
}

export function Problem({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div class="problem row" role="alert">
      <Icon name="alert" width={18} height={18} />
      <span>{message}</span>
      {onRetry && <button class="btn btn-small right" onClick={onRetry}>{t("Try again")}</button>}
    </div>
  );
}

export function Loading({ rows = 5 }: { rows?: number }) {
  return (
    <div class="panel-pad stack" aria-busy="true" aria-label={t("Loading")}>
      {Array.from({ length: rows }, (_, i) => (
        <div class="skeleton" style={{ width: `${90 - i * 9}%` }} key={i} />
      ))}
    </div>
  );
}

export function Pager({ page, perPage, total }: { page: number; perPage: number; total: number }) {
  const pages = Math.max(1, Math.ceil(total / perPage));
  if (total <= perPage && page === 1) return null;
  const from = total === 0 ? 0 : (page - 1) * perPage + 1;
  const to = Math.min(total, page * perPage);
  return (
    <nav class="pager" aria-label={t("Pagination")}>
      <span class="num">{t("{from}–{to} of {total}", { from: num(from), to: num(to), total: num(total) })}</span>
      <span class="spacer" />
      <button class="btn btn-small" disabled={page <= 1} onClick={() => setQuery({ page: page - 1 })}>{t("Previous")}</button>
      <span class="num">{t("Page {page} of {pages}", { page: num(page), pages: num(pages) })}</span>
      <button class="btn btn-small" disabled={page >= pages} onClick={() => setQuery({ page: page + 1 })}>{t("Next")}</button>
    </nav>
  );
}

export function SearchBox({ value, placeholder, onSearch }: { value: string; placeholder: string; onSearch: (q: string) => void }) {
  const [q, setQ] = useState(value);
  useEffect(() => setQ(value), [value]);
  return (
    <form
      class="search"
      role="search"
      onSubmit={(e) => {
        e.preventDefault();
        onSearch(q.trim());
      }}
    >
      <Icon name="search" />
      <input class="input" type="search" placeholder={placeholder} aria-label={placeholder} value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
    </form>
  );
}

export function Tags({ tags }: { tags?: string[] }) {
  return <>{tags?.map((t) => <span class="tag" key={t}>{t}</span>)}</>;
}

export function JobClass({ name, wrapper }: { name: string; wrapper?: string | null }) {
  return (
    <span class="cls">
      <Link href={`/metrics/jobs/${encodeURIComponent(name)}`}>{name}</Link>
      {wrapper && <span class="dim small" style={{ fontWeight: 400 }}> {t("via {name}", { name: wrapper.split("::").pop()! })}</span>}
    </span>
  );
}

// -- JSON & backtraces -------------------------------------------------------

function JsonNode({ value, indent }: { value: unknown; indent: number }): ComponentChildren {
  const pad = "  ".repeat(indent);
  if (value === null || typeof value === "boolean") return <span class="json-lit">{String(value)}</span>;
  if (typeof value === "number") return <span class="json-num">{value}</span>;
  if (typeof value === "string") return <span class="json-str">{JSON.stringify(value)}</span>;
  if (Array.isArray(value)) {
    const items = value as unknown[];
    if (items.length === 0) return "[]";
    return (
      <>
        {"[\n"}
        {items.map((v, i) => (
          <>
            {pad}  <JsonNode value={v} indent={indent + 1} />
            {i < items.length - 1 ? ",\n" : "\n"}
          </>
        ))}
        {pad}]
      </>
    );
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length === 0) return "{}";
  return (
    <>
      {"{\n"}
      {entries.map(([k, v], i) => (
        <>
          {pad}  <span class="json-key">{JSON.stringify(k)}</span>: <JsonNode value={v} indent={indent + 1} />
          {i < entries.length - 1 ? ",\n" : "\n"}
        </>
      ))}
      {pad}
      {"}"}
    </>
  );
}

export function JsonView({ value }: { value: unknown }) {
  return (
    <pre class="code">
      <JsonNode value={value} indent={0} />
    </pre>
  );
}

export function Backtrace({ lines }: { lines: string[] }) {
  return (
    <pre class="code">
      {lines.map((l) => (
        <div class={/\/(gems|ruby|rubygems)\//.test(l) ? "bt-lib" : "bt-app"}>{l}</div>
      ))}
    </pre>
  );
}

// -- global overlays ---------------------------------------------------------

export function Toasts() {
  const toasts = useStore(toastStore);
  return (
    <div class="toasts" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div class={`toast ${t.kind}`} key={t.id}>
          <Icon name={t.kind === "error" ? "alert" : "check"} />
          {t.message}
        </div>
      ))}
    </div>
  );
}

export function ConfirmDialog() {
  const req = useStore(confirmStore);
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current!; // refs are attached before effects run
    if (req && !d.open) d.showModal();
    if (!req && d.open) d.close();
  }, [req]);
  const finish = (ok: boolean) => {
    req?.resolve(ok);
    confirmStore.set(null);
  };
  return (
    <dialog class="confirm" ref={ref} onCancel={(e) => { e.preventDefault(); finish(false); }} aria-labelledby="confirm-title">
      {req && (
        <form method="dialog" onSubmit={(e) => { e.preventDefault(); finish(true); }}>
          <h3 id="confirm-title">{req.title}</h3>
          {req.body && <p>{req.body}</p>}
          <div class="btn-group">
            {/* destructive actions start focused on Cancel so Enter can't delete by accident */}
            <button type="button" class="btn" onClick={() => finish(false)} autofocus={!!req.danger}>{t("Cancel")}</button>
            <button type="submit" class={req.danger ? "btn btn-danger solid" : "btn btn-primary"} autofocus={!req.danger}>{req.action}</button>
          </div>
        </form>
      )}
    </dialog>
  );
}
