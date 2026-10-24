import { act, fireEvent, render, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { flush, mockApi, session, STATS } from "./helpers";

// The layout reads its brand images from <meta> tags at import time.
for (const [name, content] of [["robin-logo", "assets/robin-1.svg"], ["robin-wordmark", "assets/robin-wordmark-1.svg"]]) {
  const meta = document.createElement("meta");
  meta.name = name;
  meta.content = content!;
  document.head.append(meta);
}

const Layout = load(() => import("../src/components/layout"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));
const Api = load(() => import("../src/api"));
const I = load(() => import("../src/i18n"));

beforeEach(() => {
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
  State.m.liveStore.set(null);
  State.m.pausedStore.set(false);
  State.m.connectionStore.set("live");
  State.m.themeStore.set("system");
  mockApi({ stats: { stats: STATS, queues: {}, at: 1 }, session: session() });
});

function page() {
  return render(<Layout.m.Layout><p>Page body</p></Layout.m.Layout>);
}

const current = () => [...document.querySelectorAll('.nav a[aria-current="page"], .side-foot a[aria-current="page"]')].map((a) => a.textContent);

describe("Layout", () => {
  test("renders the shell with brand, navigation and page", () => {
    expect(page().container).toMatchSnapshot();
  });

  test("shows live counts, flagging retries", async () => {
    const { container } = page();
    await act(() => {
      State.m.liveStore.set({ stats: { ...STATS, busy: 0, retries: 12_345 }, queues: {}, at: 1 });
    });
    expect([...container.querySelectorAll(".nav .count")].map((c) => `${c.className}:${c.textContent}`)).toEqual([
      "count:0", "count:4,581", "count:48", "count alert:12.3K", "count:14",
    ]);
    await act(() => {
      State.m.liveStore.set({ stats: { ...STATS, retries: 0 }, queues: {}, at: 2 });
    });
    expect(container.querySelectorAll(".nav .count.alert")).toHaveLength(0);
  });

  test("marks the current section", async () => {
    page();
    const at = async (path: string) => {
      await act(() => R.m.navigate(path));
      return current();
    };
    expect(await at("/")).toEqual(["Dashboard"]);
    expect(await at("/busy")).toEqual(["Busy"]);
    expect(await at("/queues/mail")).toEqual(["Queues"]);
    expect(await at("/queuesish")).toEqual([]);
    expect(await at("/metrics/jobs/X")).toEqual(["Metrics"]);
    expect(await at("/sets/retries/1-a")).toEqual(["Retries"]);
    expect(await at("/sets/dead/1-a")).toEqual(["Dead"]);
    expect(await at("/sets/scheduled/1-a")).toEqual(["Scheduled"]);
    expect(await at("/settings")).toEqual([" Settings & about"]);
    expect(await at("/cron/x")).toEqual(["Cron"]);
    expect(await at("/profiles")).toEqual(["Profiles"]);
  });

  test("lists pages added by extensions", async () => {
    const { container } = page();
    const groups = () => [...container.querySelectorAll(".nav-group")].map((g) => g.textContent);
    expect(groups()).toEqual(["Insight"]);
    await act(() => {
      State.m.sessionStore.set(session({ extensions: [{ slug: "billing", title: "Billing" }, { slug: "a b", title: "Odd one" }] }));
    });
    expect(groups()).toEqual(["Insight", "Extensions"]);
    const links = [...container.querySelectorAll(".nav a")].slice(-2);
    expect(links.map((a) => [a.getAttribute("href"), a.textContent])).toEqual([["/robin/ext/billing", "Billing"], ["/robin/ext/a%20b", "Odd one"]]);
    expect(links[0].querySelector("path")?.getAttribute("d")).toContain("M4 4 H9 V7");
    await act(() => R.m.navigate("/ext/billing"));
    expect(current()).toEqual(["Billing"]);
    await act(() => {
      State.m.sessionStore.set(session({ extensions: [] }));
    });
    expect(groups()).toEqual(["Insight"]);
  });

  test("shows navigation in the dashboard's language, with extensions' own translations", () => {
    I.m.localeStore.set({ code: "de", catalogue: { Busy: "Beschäftigt", Insight: "Einblick", Extensions: "Erweiterungen" } });
    State.m.sessionStore.set(session({ extensions: [{ slug: "billing", title: "Billing", titles: { de: "Abrechnung" } }, { slug: "busy", title: "Busy" }] }));
    const { container } = page();
    expect([...container.querySelectorAll(".nav-group")].map((g) => g.textContent)).toEqual(["Einblick", "Erweiterungen"]);
    expect([...container.querySelectorAll(".nav a")].slice(-2).map((a) => a.textContent)).toEqual(["Abrechnung", "Busy"]);
    expect(container.querySelector('.nav a[href="/robin/busy"]')?.textContent).toBe("Beschäftigt");
    I.m.localeStore.set({ code: "en", catalogue: {} });
    expect(Layout.m.extensionTitle({ slug: "x", title: "X", titles: { de: "Y" } })).toBe("X");
  });

  test("uses a custom title in place of the wordmark", async () => {
    const { container } = page();
    expect(container.querySelector(".brand-wordmark")?.getAttribute("alt")).toBe("Robin");
    await act(() => {
      State.m.sessionStore.set(session({ title: "Acme jobs", version: "9.9" }));
    });
    expect(container.querySelector(".brand-wordmark")).toBeNull();
    expect(container.querySelector(".brand-name")?.textContent).toBe("Acme jobsv9.9");
    await act(() => {
      State.m.sessionStore.set(null);
    });
    expect(container.querySelector(".brand-wordmark")).not.toBeNull();
  });

  test("toggles live updates", async () => {
    page();
    const button = () => screen.getByTitle(/live updates/);
    expect(button().outerHTML).toContain('data-state="live"');
    expect(button().getAttribute("aria-pressed")).toBe("true");
    expect(button().textContent).toBe("Live");
    fireEvent.click(button());
    expect(State.m.pausedStore.get()).toBe(true);
    await act(flush);
    expect(button().textContent).toBe("Paused");
    expect(button().title).toBe("Resume live updates");
    expect(button().getAttribute("data-state")).toBe("paused");
    expect(button().getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(button());
    expect(State.m.pausedStore.get()).toBe(false);
    await act(flush);
    expect(button().title).toBe("Pause live updates");
    await act(() => {
      State.m.connectionStore.set("polling");
    });
    expect(button().textContent).toBe("Polling");
    await act(() => {
      State.m.connectionStore.set("offline");
    });
    expect(button().textContent).toBe("Offline");
    expect(button().getAttribute("data-state")).toBe("offline");
  });

  test("switches the theme", () => {
    const { container } = page();
    const buttons = [...container.querySelectorAll(".seg button")];
    expect(buttons.map((b) => [b.getAttribute("title"), b.getAttribute("aria-pressed"), b.textContent])).toEqual([
      ["Light theme", "false", "Light"], ["System theme", "true", "Auto"], ["Dark theme", "false", "Dark"],
    ]);
    fireEvent.click(buttons[2]);
    expect(State.m.themeStore.get()).toBe("dark");
    expect(buttons[2].getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(buttons[0]);
    expect(State.m.themeStore.get()).toBe("light");
    fireEvent.click(buttons[1]);
    expect(State.m.themeStore.get()).toBe("system");
  });

  test("finds a job by id", async () => {
    page();
    const input = screen.getByLabelText<HTMLInputElement>("Find a job by ID");
    expect(input.value).toBe("");
    fireEvent.input(input, { target: { value: "   " } });
    expect(fireEvent.submit(input.form!)).toBe(false);
    expect(R.m.routeStore.get().path).toBe("/");
    expect(input.value).toBe("");
    fireEvent.input(input, { target: { value: " abc/def " } });
    fireEvent.submit(input.form!);
    await act(flush);
    expect(R.m.routeStore.get().path).toBe("/jobs/abc%2Fdef");
    expect(input.value).toBe("");
  });

  test("offers a cluster picker when there are several clusters", async () => {
    const { container } = page();
    expect(container.querySelector("select")).toBeNull();
    await act(() => {
      State.m.sessionStore.set(session({ clusters: ["us", "eu"], cluster: "us" }));
    });
    const select = container.querySelector("select")!;
    expect(select.closest("label")).toMatchSnapshot();
    fireEvent.change(select, { target: { value: "eu" } });
    expect(Api.m.clusterStore.get()).toBe("eu");
    await act(() => {
      State.m.sessionStore.set(null);
    });
    expect(container.querySelector("select")).toBeNull();
  });

  test("opens and closes the mobile menu", async () => {
    const { container } = page();
    const shell = container.querySelector(".shell")!;
    expect(shell.className).toBe("shell");
    fireEvent.click(screen.getByLabelText("Open navigation"));
    expect(shell.className).toBe("shell nav-open");
    fireEvent.keyDown(window, { key: "Escape" });
    expect(shell.className).toBe("shell");
    fireEvent.click(screen.getByLabelText("Open navigation"));
    fireEvent.click(container.querySelector(".nav a[href='/robin/busy']")!);
    await act(flush);
    expect(shell.className).toBe("shell");
    fireEvent.click(screen.getByLabelText("Open navigation"));
    fireEvent.click(container.querySelector(".brand")!);
    expect(shell.className).toBe("shell");
    fireEvent.click(screen.getByLabelText("Open navigation"));
    fireEvent.click(container.querySelector(".side-foot a")!);
    expect(shell.className).toBe("shell");
    fireEvent.click(screen.getByLabelText("Open navigation"));
    await act(() => R.m.navigate("/dead"));
    expect(shell.className).toBe("shell");
    fireEvent.click(screen.getByLabelText("Open navigation"));
    fireEvent.keyDown(window, { key: "Enter" });
    expect(shell.className).toBe("shell nav-open");
    // Following a link to the page you're already on still closes the menu.
    fireEvent.click(container.querySelector(".nav a[href='/robin/dead']")!);
    expect(R.m.routeStore.get().path).toBe("/dead");
    expect(shell.className).toBe("shell");
  });

  test("focuses job search on '/' unless typing", () => {
    const { container, unmount } = page();
    const search = screen.getByLabelText("Find a job by ID");
    const other = document.createElement("textarea");
    document.body.append(other);
    other.focus();
    expect(fireEvent.keyDown(other, { key: "/" })).toBe(true);
    expect(document.activeElement).toBe(other);
    const input = document.createElement("input");
    document.body.append(input);
    input.focus();
    expect(fireEvent.keyDown(input, { key: "/" })).toBe(true);
    expect(document.activeElement).toBe(input);
    expect(fireEvent.keyDown(container, { key: "/" })).toBe(false);
    expect(document.activeElement).toBe(search);
    expect(fireEvent.keyDown(container, { key: "x" })).toBe(true);
    unmount();
    const remove = vi.spyOn(window, "removeEventListener");
    page().unmount();
    expect(remove).toHaveBeenCalledWith("keydown", expect.any(Function));
    other.remove();
    input.remove();
  });
});

describe("without brand images", () => {
  test("falls back to text", async () => {
    for (const m of document.querySelectorAll("meta")) m.remove();
    vi.resetModules();
    const fresh = await import("../src/components/layout");
    const state = await import("../src/state");
    state.sessionStore.set(session());
    expect(fresh.logoSrc).toBe("");
    const { container } = render(<fresh.Layout><p /></fresh.Layout>);
    expect(container.querySelectorAll("img")).toHaveLength(0);
    expect(container.querySelector(".brand-name")?.textContent).toBe("Robinv0.1.0");
    expect(container.querySelector(".mobile-bar")?.innerHTML).toMatchSnapshot();
  });
});
