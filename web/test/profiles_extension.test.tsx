import { fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { deferred, freezeTime, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import { renderPage, settle } from "./render_page";

const Profiles = load(() => import("../src/pages/profiles"));
const Ext = load(() => import("../src/pages/extension"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));
const I = load(() => import("../src/i18n"));

beforeEach(() => {
  freezeTime();
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
  State.m.toastStore.set([]);
  State.m.confirmStore.set(null);
});

async function confirm(answer = true) {
  await settle();
  const req = State.m.confirmStore.get()!;
  const shown = { title: req.title, body: req.body, action: req.action, danger: req.danger };
  req.resolve(answer);
  State.m.confirmStore.set(null);
  await settle();
  return shown;
}

const PROFILES = [
  { jid: "p1", class: "ExportJob", queue: "low", label: "big export", started_at: NOW - 60_000, duration_ms: 1530, ok: true, bytes: 2_500_000 },
  { jid: "p 2", class: "Mail::Job", queue: null, label: null, started_at: NOW - 5000, duration_ms: 12, ok: false, bytes: 900 },
];

describe("size", () => {
  test("reads like a file size", () => {
    expect(Profiles.m.size(0)).toBe("0 B");
    expect(Profiles.m.size(1023)).toBe("1023 B");
    expect(Profiles.m.size(1024)).toBe("1.0 KB");
    expect(Profiles.m.size(1024 * 1024 - 1)).toBe("1024.0 KB");
    expect(Profiles.m.size(1024 * 1024)).toBe("1.0 MB");
  });
});

describe("Profiles", () => {
  test("lists profiles with downloads", async () => {
    mockApi({ profiles: { profiles: PROFILES } });
    const { container } = await renderPage(<Profiles.m.Profiles />);
    expect(container).toMatchSnapshot();
    const downloads = [...container.querySelectorAll("a[download]")];
    expect(downloads.map((a) => [a.getAttribute("href"), a.getAttribute("download")])).toEqual([
      ["api/profiles/p1", "robin-p1.json"], ["api/profiles/p%202", "robin-p 2.json"],
    ]);
  });

  test("explains how to record one", async () => {
    mockApi({ profiles: { profiles: [] } });
    const { container } = await renderPage(<Profiles.m.Profiles />);
    expect(container.querySelector(".empty")?.textContent).toBe(
      "No profiles yetPush a job with set(profile: true) (servers need the vernier gem) and its run shows up here for a week.",
    );
  });

  test("shows a skeleton while loading, and problems", async () => {
    const pending = deferred<unknown>();
    mockApi({ profiles: () => pending.promise });
    const { container } = await renderPage(<Profiles.m.Profiles />);
    expect(container.querySelector('[aria-busy="true"]')).not.toBeNull();
    pending.resolve(reply(500, { error: "Redis is down" }));
    await settle();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Redis is down");
  });

  test("deletes after confirming, with permission", async () => {
    const api = mockApi({ profiles: { profiles: PROFILES.slice(1) }, "DELETE profiles/p%202": { deleted: true } });
    await renderPage(<Profiles.m.Profiles />);
    fireEvent.click(screen.getByText("Delete"));
    expect(await confirm()).toEqual({ title: "Delete this profile?", body: "The profile of Mail::Job (p 2) is removed.", action: "Delete", danger: true });
    expect(api.to("profiles/p%202", "DELETE")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Profile deleted");
    expect(api.to("profiles")).toHaveLength(2);
  });

  test("hides delete without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ profiles: { profiles: PROFILES.slice(0, 1) } });
    const { container } = await renderPage(<Profiles.m.Profiles />);
    expect(container.querySelectorAll("button")).toHaveLength(0);
    expect(container.querySelectorAll("a[download]")).toHaveLength(1);
  });
});

const PAGE = {
  slug: "billing", title: "Billing desk",
  blocks: [
    { type: "heading", text: "Today" },
    { type: "stats", items: [{ label: "Waiting", value: 12 }, { label: "Paused", value: true }, { label: "Owner", value: null }] },
    { type: "text", text: "<b>not html</b>" },
    { type: "table", columns: ["Customer", "Total", "Paid"], rows: [["Acme", 99.5, false], ["Zed", null, true]] },
    { type: "table", columns: ["Empty"], rows: [] },
    { type: "actions", items: [{ label: "Send now", action: "send" }, { label: "Purge", action: "purge all", confirm: "Purge everything?", danger: true }] },
    { type: "sparkline", points: [1, 2] },
  ],
};

describe("Extension", () => {
  test("renders every kind of block as text", async () => {
    mockApi({ "extensions/billing": PAGE });
    const { container } = await renderPage(<Ext.m.Extension slug="billing" />);
    expect(container).toMatchSnapshot();
    expect(container.querySelector("b")).toBeNull();
    expect(container.querySelector(".ext-text")?.textContent).toBe("<b>not html</b>");
  });

  test("text", () => {
    expect([Ext.m.text(null), Ext.m.text(0), Ext.m.text(false), Ext.m.text("x"), Ext.m.text(1284.5), Ext.m.text("1284")])
      .toEqual(["–", "0", "false", "x", "1,284.5", "1284"]);
  });

  test("runs actions, confirming when asked, and reloads", async () => {
    const api = mockApi({
      "extensions/billing": PAGE,
      "POST extensions/billing/actions/send": { message: "Sending invoices" },
      "POST extensions/billing/actions/purge%20all": { message: "Purged" },
    });
    await renderPage(<Ext.m.Extension slug="billing" />);
    fireEvent.click(screen.getByText("Send now"));
    await settle();
    expect(State.m.confirmStore.get()).toBeNull();
    expect(api.to("extensions/billing/actions/send", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Sending invoices");
    expect(api.to("extensions/billing")).toHaveLength(2);
    fireEvent.click(screen.getByText("Purge"));
    expect(await confirm()).toEqual({ title: "Purge everything?", body: undefined, action: "Purge", danger: true });
    expect(api.to("extensions/billing/actions/purge%20all", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Purged");
  });

  test("hides actions without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ "extensions/billing": PAGE });
    const { container } = await renderPage(<Ext.m.Extension slug="billing" />);
    expect(container.querySelectorAll("button")).toHaveLength(0);
  });

  test("loading, empty pages and errors", async () => {
    const pending = deferred<unknown>();
    mockApi({ "extensions/a%2Fb": () => pending.promise });
    const { container } = await renderPage(<Ext.m.Extension slug="a/b" />);
    expect(container.querySelector("h1")?.textContent).toBe("Loading…");
    expect(container.querySelector('[aria-busy="true"]')).not.toBeNull();
    pending.resolve({ slug: "a/b", title: "Blank", blocks: [] });
    await settle();
    expect(container.querySelector("h1")?.textContent).toBe("Blank");
    expect(container.querySelector(".empty")?.textContent).toBe("This page is empty");
    mockApi({ "extensions/broken": reply(500, { error: "Broken failed: RuntimeError: db down" }) });
    const broken = await renderPage(<Ext.m.Extension slug="broken" />);
    expect(broken.container.querySelector('[role="alert"]')?.textContent).toContain("Broken failed: RuntimeError: db down");
  });
});

describe("Extension scripts", () => {
  const SCRIPTED = {
    slug: "reports", title: "Reports", titles: { de: "Berichte" }, script: "extensions/reports/app.js", stylesheet: "extensions/reports/app.css",
    blocks: [{ type: "text", text: "Above the script" }], messages: { "Late: {n}": "Verspätet: {n}" },
  };

  test("renders into an element with a context, and cleans up", async () => {
    const cleanup = vi.fn();
    const render = vi.fn((element: HTMLElement, ctx: { t: (s: string, v?: Record<string, number>) => string; locale: string; slug: string }) => {
      element.textContent = `${ctx.slug} ${ctx.locale} ${ctx.t("Late: {n}", { n: 2 })} ${ctx.t("Other")}`;
      return cleanup;
    });
    const load = vi.spyOn(Ext.m.modules, "load").mockResolvedValue({ default: render });
    const api = mockApi({ "extensions/reports": SCRIPTED });
    const { container, unmount } = await renderPage(<Ext.m.Extension slug="reports" />);
    await settle();
    expect(load).toHaveBeenCalledWith("http://localhost/robin/extensions/reports/app.js");
    expect(container.querySelector(".ext-text")?.textContent).toBe("Above the script");
    expect(container.querySelector(".ext-script")?.textContent).toBe("reports en Verspätet: 2 Other");
    expect(render.mock.calls[0][0]).toBe(container.querySelector(".ext-script"));
    expect([...api.to("extensions/reports")[0].url.searchParams]).toEqual([["locale", "en"]]);
    const link = document.head.querySelector<HTMLLinkElement>('link[href="http://localhost/robin/extensions/reports/app.css"]');
    expect(link?.rel).toBe("stylesheet");
    expect(cleanup).not.toHaveBeenCalled();
    unmount();
    expect(cleanup).toHaveBeenCalledTimes(1);
    expect(document.head.querySelector('link[href$="app.css"]')).toBeNull();
  });

  test("works without a stylesheet, translations or a cleanup function", async () => {
    vi.spyOn(Ext.m.modules, "load").mockResolvedValue({ default: () => "not a function" });
    mockApi({ "extensions/reports": { ...SCRIPTED, stylesheet: undefined, messages: undefined, blocks: [] } });
    const { container, unmount } = await renderPage(<Ext.m.Extension slug="reports" />);
    await settle();
    expect(container.querySelector(".empty")).toBeNull();
    expect(container.querySelector(".ext-script")).not.toBeNull();
    expect(document.head.querySelector('link[rel="stylesheet"][href*="extensions"]')).toBeNull();
    unmount();
  });

  test("explains scripts that fail to load or export nothing", async () => {
    vi.spyOn(Ext.m.modules, "load").mockRejectedValueOnce(new Error("404")).mockResolvedValueOnce({});
    mockApi({ "extensions/reports": SCRIPTED });
    const first = await renderPage(<Ext.m.Extension slug="reports" />);
    await settle();
    expect(first.container.querySelector('[role="alert"]')?.textContent).toBe("extensions/reports/app.js couldn't be loaded: 404");
    first.unmount();
    const second = await renderPage(<Ext.m.Extension slug="reports" />);
    await settle();
    expect(second.container.querySelector('[role="alert"]')?.textContent).toBe("extensions/reports/app.js has no default export to call.");
  });

  test("doesn't render into a page that has gone", async () => {
    const pending = deferred<{ default: () => void }>();
    const render = vi.fn();
    vi.spyOn(Ext.m.modules, "load").mockReturnValue(pending.promise);
    mockApi({ "extensions/reports": SCRIPTED });
    const { unmount } = await renderPage(<Ext.m.Extension slug="reports" />);
    unmount();
    pending.resolve({ default: render });
    await settle();
    expect(render).not.toHaveBeenCalled();
  });

  test("shows the title in the dashboard's language", async () => {
    vi.spyOn(Ext.m.modules, "load").mockResolvedValue({ default: () => undefined });
    I.m.localeStore.set({ code: "de", catalogue: {} });
    mockApi({ "extensions/reports": SCRIPTED });
    const { container } = await renderPage(<Ext.m.Extension slug="reports" />);
    expect(container.querySelector("h1")?.textContent).toBe("Berichte");
    I.m.localeStore.set({ code: "en", catalogue: {} });
  });

  test("context fetches data, runs actions, toasts and navigates", async () => {
    I.m.localeStore.set({ code: "fr", catalogue: {} });
    const api = mockApi({
      "extensions/re%2Fports/data/sum%20mary": { late: 3 },
      "POST extensions/re%2Fports/actions/save%20it": { message: "Saved" },
    });
    const ctx = Ext.m.context("re/ports");
    I.m.localeStore.set({ code: "en", catalogue: {} });
    expect([ctx.slug, ctx.locale, ctx.t("Hi {name}", { name: "A" }), ctx.t("toString")]).toEqual(["re/ports", "fr", "Hi A", "toString"]);
    expect(await ctx.data("sum mary", { since: "monday" })).toEqual({ late: 3 });
    expect([...api.to("extensions/re%2Fports/data/sum%20mary")[0].url.searchParams]).toEqual([["since", "monday"], ["locale", "fr"]]);
    expect(await ctx.data("sum mary")).toEqual({ late: 3 });
    expect(await ctx.action("save it", { name: "Q3" })).toBe("Saved");
    const call = api.to("extensions/re%2Fports/actions/save%20it", "POST")[0];
    expect([call.body, [...call.url.searchParams]]).toEqual([{ name: "Q3" }, [["locale", "fr"]]]);
    expect(await ctx.action("save it")).toBe("Saved");
    expect(api.to("extensions/re%2Fports/actions/save%20it", "POST")[1].body).toEqual({});
    ctx.toast("Hello", "error");
    expect(State.m.toastStore.get().at(-1)).toMatchObject({ message: "Hello", kind: "error" });
    ctx.navigate("/queues");
    expect(R.m.routeStore.get().path).toBe("/queues");
  });

  test("follows a reloaded page's stylesheet, script and translations", async () => {
    const render = vi.fn();
    const load = vi.spyOn(Ext.m.modules, "load").mockResolvedValue({ default: render });
    let calls = 0;
    const actions = { type: "actions", items: [{ label: "Go", action: "go" }] };
    mockApi({
      "extensions/reports": () => (++calls === 1
        ? { ...SCRIPTED, blocks: [actions] }
        : { ...SCRIPTED, blocks: [actions], stylesheet: "extensions/reports/b.css", script: "extensions/reports/b.js", messages: { Hi: "Hallo" } }),
      "POST extensions/reports/actions/go": { message: "Done" },
    });
    await renderPage(<Ext.m.Extension slug="reports" />);
    await settle();
    expect(render).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByText("Go"));
    await settle();
    await settle();
    expect(document.head.querySelector('link[href$="app.css"]')).toBeNull();
    expect(document.head.querySelector('link[href$="b.css"]')).not.toBeNull();
    expect(load.mock.calls.map(([url]) => url.split("/").pop())).toEqual(["app.js", "b.js"]);
    expect(render).toHaveBeenCalledTimes(2);
    expect((render.mock.calls[1][1] as { t: (s: string) => string }).t("Hi")).toBe("Hallo");
  });

  test("imports scripts by URL", async () => {
    const module = await Ext.m.modules.load("data:text/javascript,export default 42");
    expect(module.default).toBe(42);
  });

  test("actions on block pages send the dashboard's language", async () => {
    const api = mockApi({ "extensions/billing": PAGE, "POST extensions/billing/actions/send": { message: "Sent" } });
    await renderPage(<Ext.m.Extension slug="billing" />);
    fireEvent.click(screen.getByText("Send now"));
    await settle();
    expect([...api.to("extensions/billing/actions/send", "POST")[0].url.searchParams]).toEqual([["locale", "en"]]);
  });
});
