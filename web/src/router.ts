// History-API router aware of the mount path (<base href>).
import { createStore, useStore } from "./store";

const basePath = new URL(document.baseURI).pathname.replace(/\/$/, "");

function current(): { path: string; query: URLSearchParams } {
  const full = location.pathname;
  // "/robin/queues" → "/queues"; the mount point itself ("/robin") → "/".
  const path = full.startsWith(`${basePath}/`) ? full.slice(basePath.length) : "/";
  return { path, query: new URLSearchParams(location.search) };
}

export const routeStore = createStore(current());

window.addEventListener("popstate", () => routeStore.set(current()));

export function href(path: string): string {
  return `${basePath}${path}`;
}

export function navigate(path: string, { replace = false } = {}): void {
  const url = href(path);
  const method = replace ? "replaceState" : "pushState";
  // Stryker disable next-line StringLiteral: browsers ignore the title argument
  history[method](null, "", url);
  routeStore.set(current());
  if (!replace) window.scrollTo({ top: 0 });
}

/** Update query parameters in place (used for paging and search). */
export function setQuery(params: Record<string, string | number | undefined>): void {
  const { path, query } = current();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === "" || v === 1 && k === "page") query.delete(k);
    else query.set(k, String(v));
  }
  const qs = query.toString();
  navigate(`${path}${qs ? `?${qs}` : ""}`, { replace: true });
}

export function useRoute() {
  return useStore(routeStore);
}

const segments = (path: string) => path.replace(/\/$/, "").split("/");

/** Match "/queues/:name" style patterns; a trailing slash is ignored. */
export function match(pattern: string, path: string): Record<string, string> | null {
  const pp = segments(pattern);
  const ap = segments(path);
  if (pp.length !== ap.length) return null;
  const params: Record<string, string> = {};
  for (const [i, p] of pp.entries()) {
    const a = ap[i];
    if (p.startsWith(":")) params[p.slice(1)] = decodeURIComponent(a);
    else if (p !== a) return null;
  }
  return params;
}
