import { useEffect, useRef, useState } from "preact/hooks";
import type { Block, Cell, ExtensionPage, Params } from "../api";
import { enc, get } from "../api";
import { act, post } from "../actions";
import { extensionTitle } from "../components/layout";
import { Empty, Loading, Problem } from "../components/ui";
import { fill, locale, t, type Params as Values } from "../i18n";
import { navigate } from "../router";
import { can, toast, useResource } from "../state";

/** Extension values are always shown as plain text; numbers get separators. */
export function text(value: Cell): string {
  return value === null ? "–" : value.toLocaleString(locale());
}

/**
 * What an extension's script gets, next to the element to render into. Its
 * module's default export is called as `render(element, context)` and may
 * return a function to call when the page goes away.
 */
export interface ExtensionContext {
  slug: string;
  /** The dashboard's language, e.g. "en" or "pt-BR". */
  locale: string;
  /** `text` in the dashboard's language (from the extension's translations), with {name} placeholders filled. */
  t: (text: string, values?: Values) => string;
  /** The value of the extension's `data name` block. */
  data: <T = unknown>(name: string, params?: Params) => Promise<T>;
  /** Runs the extension's `action name` block with `body` (a JSON object); resolves to its message. */
  action: (name: string, body?: Record<string, unknown>) => Promise<string>;
  toast: (message: string, kind?: "ok" | "error") => void;
  /** Goes to a dashboard page, e.g. "/queues". */
  navigate: (path: string) => void;
}

type Render = (element: HTMLElement, context: ExtensionContext) => unknown;

/** Imports a script by URL (replaced in tests). */
export const modules = { load: (url: string): Promise<{ default?: unknown }> => import(/* @vite-ignore */ url) as Promise<{ default?: unknown }> };

export function context(slug: string, messages: Record<string, string> = {}): ExtensionContext {
  const code = locale();
  return {
    slug,
    locale: code,
    t: (text, values = {}) => fill(Object.hasOwn(messages, text) ? messages[text] : text, values),
    data: (name, params = {}) => get(`extensions/${enc(slug)}/data/${enc(name)}`, { ...params, locale: code }),
    action: async (name, body = {}) =>
      (await post<{ message: string }>(`extensions/${enc(slug)}/actions/${enc(name)}`, body, { locale: code })).message,
    toast,
    navigate: (path) => navigate(path),
  };
}

/** Runs an extension's own script in an element of the page, with its stylesheet. */
function Script({ page }: { page: ExtensionPage & { script: string } }) {
  const ref = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const { slug, script, stylesheet, messages } = page;

  useEffect(() => {
    if (!stylesheet) return undefined;
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = new URL(stylesheet, document.baseURI).href;
    document.head.append(link);
    return () => link.remove();
  }, [stylesheet]);

  useEffect(() => {
    let gone = false;
    let cleanup: unknown;
    modules.load(new URL(script, document.baseURI).href).then(
      (module) => {
        if (gone) return;
        if (typeof module.default !== "function") {
          setError(t("{script} has no default export to call.", { script }));
          return;
        }
        cleanup = (module.default as Render)(ref.current!, context(slug, messages));
      },
      (e: unknown) => setError(t("{script} couldn't be loaded: {error}", { script, error: (e as Error).message })),
    );
    return () => {
      gone = true;
      if (typeof cleanup === "function") (cleanup as () => void)();
    };
  }, [slug, script, messages]);

  return (
    <>
      {error && <Problem message={error} />}
      <div class="ext-script" ref={ref} />
    </>
  );
}

function Actions({ slug, items, reload }: { slug: string; items: Extract<Block, { type: "actions" }>["items"]; reload: () => void }) {
  if (!can("extensions")) return null;
  return (
    <div class="btn-group">
      {items.map((a) => (
        <button
          class={a.danger ? "btn btn-danger" : "btn"}
          key={a.action}
          onClick={() => act(
            () => post<{ message: string }>(`extensions/${enc(slug)}/actions/${enc(a.action)}`, undefined, { locale: locale() }),
            (r) => r.message,
            a.confirm ? { title: a.confirm, action: a.label, danger: a.danger } : undefined,
          ).then(reload)}
        >
          {a.label}
        </button>
      ))}
    </div>
  );
}

export function BlockView({ block, slug, reload }: { block: Block; slug: string; reload: () => void }) {
  switch (block.type) {
    case "heading":
      return <h2 class="ext-heading">{block.text}</h2>;
    case "text":
      return <p class="ext-text">{block.text}</p>;
    case "stats":
      return (
        <div class="facts">
          {block.items.map((item) => (
            <div class="fact" key={item.label}>
              <span class="fact-value">{text(item.value)}</span>
              <span class="fact-label">{item.label}</span>
            </div>
          ))}
        </div>
      );
    case "table":
      return (
        <section class="panel ext-block">
          {block.rows.length === 0 ? <Empty title={t("Nothing to show")} /> : (
            <div class="table-wrap">
              <table class="table">
                <thead><tr>{block.columns.map((c) => <th key={c}>{c}</th>)}</tr></thead>
                <tbody>{block.rows.map((row, i) => <tr key={i}>{row.map((cell, j) => <td key={j}>{text(cell)}</td>)}</tr>)}</tbody>
              </table>
            </div>
          )}
        </section>
      );
    case "actions":
      return <div class="ext-block"><Actions slug={slug} items={block.items} reload={reload} /></div>;
  }
  return null; // a block from a newer version of Robin
}

export function Extension({ slug }: { slug: string }) {
  const res = useResource<ExtensionPage>(`extensions/${enc(slug)}`, { locale: locale() }, 0);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const page = res.data;
  return (
    <>
      <div class="page-head">
        <div><h1>{page ? extensionTitle(page) : t("Loading…")}</h1></div>
      </div>
      {!page ? <section class="panel"><Loading /></section> : page.blocks.length === 0 && !page.script ? (
        <section class="panel"><Empty title={t("This page is empty")} icon="extension" /></section>
      ) : (
        <>
          {page.blocks.map((block, i) => <BlockView block={block} slug={slug} reload={res.reload} key={i} />)}
          {page.script && <Script page={{ ...page, script: page.script }} />}
        </>
      )}
    </>
  );
}
