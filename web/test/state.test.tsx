import { act, render } from "@testing-library/preact";
import { describe, expect, test, vi } from "vitest";
import { deferred, FakeEventSource, flush, mockApi, reply, session, STATS, stubColorScheme } from "./helpers";

// state.ts keeps connection state at module level, so every test loads
// fresh copies of it (and of api.ts, whose cluster store it watches).
async function fresh() {
  vi.resetModules();
  const api = await import("../src/api");
  const state = await import("../src/state");
  return { api, state };
}

const live = (processed: number, at = 1) => ({ stats: { ...STATS, processed }, queues: { default: 3 }, at });

async function advance(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
}

function fakeIntervals() {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
}

describe("session", () => {
  test("loads the session and answers permission checks", async () => {
    const { state } = await fresh();
    expect(state.can("retry")).toBe(false);
    mockApi({ session: session({ permissions: { retry: false } as never }) });
    await state.loadSession();
    expect(state.sessionStore.get()?.version).toBe("0.1.0");
    expect(state.can("delete")).toBe(true);
    expect(state.can("retry")).toBe(false);
    expect(state.can("made_up")).toBe(false);
  });
});

describe("live updates by polling", () => {
  test("polls stats on the session's interval", async () => {
    const { state } = await fresh();
    let n = 0;
    const api = mockApi({ stats: () => live(++n, n) });
    state.sessionStore.set(session({ stream_interval: 3 }));
    fakeIntervals();
    state.startLive();
    await vi.advanceTimersByTimeAsync(0);
    expect(state.connectionStore.get()).toBe("live");
    expect(state.liveStore.get()?.stats.processed).toBe(1);
    await vi.advanceTimersByTimeAsync(2999);
    expect(api.to("stats")).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(api.to("stats")).toHaveLength(2);
    expect(state.pulseStore.get()).toEqual([
      { at: 1, processed: 1, failed: STATS.failed },
      { at: 2, processed: 2, failed: STATS.failed },
    ]);
  });

  test("polls at most once a second", async () => {
    const { state } = await fresh();
    const api = mockApi({ stats: live(1) });
    state.sessionStore.set(session({ stream_interval: 0 }));
    fakeIntervals();
    state.startLive();
    await vi.advanceTimersByTimeAsync(999);
    expect(api.to("stats")).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(api.to("stats")).toHaveLength(2);
  });

  test("keeps the last 90 samples", async () => {
    const { state } = await fresh();
    mockApi({ stats: live(999, 999) });
    state.pulseStore.set(Array.from({ length: 95 }, (_, i) => ({ at: i, processed: i, failed: 0 })));
    state.sessionStore.set(session());
    state.startLive();
    await flush();
    const pulse = state.pulseStore.get();
    expect(pulse).toHaveLength(90);
    expect(pulse[0].at).toBe(6);
    expect(pulse[89]).toEqual({ at: 999, processed: 999, failed: STATS.failed });
  });

  test("goes offline when polling fails", async () => {
    const { state } = await fresh();
    mockApi({ stats: reply(500, {}) });
    state.sessionStore.set(session());
    state.startLive();
    await flush();
    expect(state.connectionStore.get()).toBe("offline");
  });

  test("doesn't start while paused, and restarts when resumed", async () => {
    localStorage.setItem("robin.paused", "1");
    const { state } = await fresh();
    expect(state.pausedStore.get()).toBe(true);
    const api = mockApi({ stats: live(1) });
    state.sessionStore.set(session());
    fakeIntervals();
    state.startLive();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(api.to("stats")).toHaveLength(0);

    state.setPaused(false);
    expect(localStorage.getItem("robin.paused")).toBe("0");
    expect(state.pausedStore.get()).toBe(false);
    await vi.advanceTimersByTimeAsync(0);
    expect(api.to("stats")).toHaveLength(1);

    state.setPaused(true);
    expect(localStorage.getItem("robin.paused")).toBe("1");
    await vi.advanceTimersByTimeAsync(10_000);
    expect(api.to("stats")).toHaveLength(1);
  });

  test("starts unpaused unless told otherwise", async () => {
    localStorage.setItem("robin.paused", "0");
    const { state } = await fresh();
    expect(state.pausedStore.get()).toBe(false);
  });
});

describe("live updates by streaming", () => {
  async function streaming() {
    FakeEventSource.instances = [];
    vi.stubGlobal("EventSource", FakeEventSource);
    const ctx = await fresh();
    const api = mockApi({ stats: live(7) });
    ctx.state.sessionStore.set(session({ live_updates: "stream" }));
    ctx.api.clusterStore.set("eu");
    await flush();
    return { ...ctx, http: api };
  }

  test("listens to the stream for the current cluster", async () => {
    const { state, http } = await streaming();
    state.startLive();
    const es = FakeEventSource.latest();
    expect(es.url).toBe("api/stream?cluster=eu");
    state.connectionStore.set("offline");
    es.emit("stats", live(42, 5));
    expect(state.connectionStore.get()).toBe("live");
    expect(state.liveStore.get()?.stats.processed).toBe(42);
    expect(state.pulseStore.get().at(-1)).toEqual({ at: 5, processed: 42, failed: STATS.failed });
    expect(http.to("stats")).toHaveLength(0);
  });

  test("falls back to polling after repeated errors", async () => {
    const { state, http } = await streaming();
    state.startLive();
    const first = FakeEventSource.latest();
    first.fail();
    first.fail();
    expect(first.closed).toBe(false);
    first.emit("stats", live(1));
    first.fail();
    first.fail();
    expect(first.closed).toBe(false);
    first.fail();
    expect(first.closed).toBe(true);
    await flush();
    expect(state.connectionStore.get()).toBe("polling");
    expect(http.to("stats")).toHaveLength(1);

    // Once it has given up, later restarts poll straight away.
    const count = FakeEventSource.instances.length;
    state.startLive();
    expect(FakeEventSource.instances).toHaveLength(count);
    expect(state.MAX_STREAM_FAILURES).toBe(3);
  });

  test("closes the stream when paused", async () => {
    const { state } = await streaming();
    state.startLive();
    const es = FakeEventSource.latest();
    state.setPaused(true);
    expect(es.closed).toBe(true);
  });
});

describe("switching clusters", () => {
  test("clears live data and reloads the session", async () => {
    const { api, state } = await fresh();
    const s = deferred<unknown>();
    mockApi({ session: () => s.promise, stats: live(3) });
    state.sessionStore.set(session());
    state.liveStore.set(live(1));
    state.pulseStore.set([{ at: 1, processed: 1, failed: 0 }]);
    api.clusterStore.set("eu");
    expect(state.liveStore.get()).toBeNull();
    expect(state.pulseStore.get()).toEqual([]);
    s.resolve(session({ cluster: "eu" }));
    await flush();
    expect(state.sessionStore.get()?.cluster).toBe("eu");
    expect(state.liveStore.get()?.stats.processed).toBe(3);
  });

  test("goes offline if the session can't load", async () => {
    const { api, state } = await fresh();
    mockApi({ session: reply(500, {}) });
    api.clusterStore.set("eu");
    await flush();
    expect(state.connectionStore.get()).toBe("offline");
  });
});

describe("theme", () => {
  test("follows the system setting by default", async () => {
    const scheme = stubColorScheme(true);
    const { state } = await fresh();
    expect(matchMedia).toHaveBeenCalledWith("(prefers-color-scheme: dark)");
    expect(state.themeStore.get()).toBe("system");
    state.applyTheme();
    expect(document.documentElement.dataset.theme).toBe("dark");
    scheme.set(false);
    expect(document.documentElement.dataset.theme).toBe("light");
  });

  test("can be forced light or dark, and remembers the choice", async () => {
    const scheme = stubColorScheme(true);
    const { state } = await fresh();
    state.setTheme("light");
    expect(localStorage.getItem("robin.theme")).toBe("light");
    expect(state.themeStore.get()).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");
    scheme.set(false);
    state.setTheme("dark");
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  test("starts with the remembered choice", async () => {
    stubColorScheme(false);
    localStorage.setItem("robin.theme", "dark");
    const { state } = await fresh();
    expect(state.themeStore.get()).toBe("dark");
  });
});

describe("toasts", () => {
  test("stack up to four and expire", async () => {
    const { state } = await fresh();
    fakeIntervals();
    state.toast("one");
    state.toast("two", "error");
    state.toast("three");
    state.toast("four");
    state.toast("five");
    expect(state.toastStore.get().map((t) => t.message)).toEqual(["two", "three", "four", "five"]);
    expect(state.toastStore.get().map((t) => t.kind)).toEqual(["error", "ok", "ok", "ok"]);
    expect(state.toastStore.get().map((t) => t.id)).toEqual([2, 3, 4, 5]);
    vi.advanceTimersByTime(3499);
    expect(state.toastStore.get()).toHaveLength(4);
    vi.advanceTimersByTime(1);
    expect(state.toastStore.get().map((t) => t.message)).toEqual(["two"]);
    vi.advanceTimersByTime(3499);
    expect(state.toastStore.get()).toHaveLength(1);
    vi.advanceTimersByTime(1);
    expect(state.toastStore.get()).toEqual([]);
  });
});

describe("confirmAction", () => {
  test("asks through the confirm store", async () => {
    const { state } = await fresh();
    const answer = state.confirmAction({ title: "Sure?", action: "Yes", danger: true });
    expect(state.confirmStore.get()).toMatchObject({ title: "Sure?", action: "Yes", danger: true });
    state.confirmStore.get()!.resolve(true);
    await expect(answer).resolves.toBe(true);
  });
});

describe("useResource", () => {
  async function harness() {
    const ctx = await fresh();
    const seen: { data: unknown; error: string | null }[] = [];
    let reload: () => void = () => undefined;
    function Probe({ path, params, refresh }: { path: string; params?: Record<string, string | number | undefined>; refresh?: number }) {
      const res = ctx.state.useResource<{ v: number }>(path, params, refresh);
      seen.push({ data: res.data, error: res.error });
      reload = res.reload;
      return <p>{res.error ?? (res.data ? `v${res.data.v}` : "loading")}</p>;
    }
    return { ...ctx, Probe, seen, reload: () => reload() };
  }

  test("loads data, passing params", async () => {
    const { Probe } = await harness();
    const api = mockApi({ thing: (url: URL) => ({ v: Number(url.searchParams.get("n")) }) });
    const { container } = render(<Probe path="thing" params={{ n: 4 }} />);
    expect(container.textContent).toBe("loading");
    await act(flush);
    expect(container.textContent).toBe("v4");
    expect(api.to("thing")).toHaveLength(1);
  });

  test("keeps the last data when a reload fails", async () => {
    const h = await harness();
    let fail = false;
    mockApi({ thing: () => (fail ? reply(500, { error: "Down" }) : { v: 1 }) });
    const { container } = render(<h.Probe path="thing" />);
    await act(flush);
    fail = true;
    h.reload();
    await act(flush);
    expect(container.textContent).toBe("Down");
    expect(h.seen.at(-1)).toEqual({ data: { v: 1 }, error: "Down" });
    fail = false;
    h.reload();
    await act(flush);
    expect(h.seen.at(-1)).toEqual({ data: { v: 1 }, error: null });
  });

  test("refetches when the params or cluster change, ignoring stale answers", async () => {
    const h = await harness();
    const slow = deferred<unknown>();
    const api = mockApi({ thing: (url: URL) => (url.searchParams.get("n") === "1" ? slow.promise : { v: Number(url.searchParams.get("n")) }) });
    const { container, rerender } = render(<h.Probe path="thing" params={{ n: 1 }} />);
    rerender(<h.Probe path="thing" params={{ n: 2 }} />);
    await act(flush);
    expect(container.textContent).toBe("v2");
    slow.resolve({ v: 1 });
    await act(flush);
    expect(container.textContent).toBe("v2");

    await act(() => h.api.clusterStore.set("eu"));
    await act(flush);
    expect(api.to("thing").at(-1)?.url.searchParams.get("cluster")).toBe("eu");
  });

  test("ignores stale failures too", async () => {
    const h = await harness();
    const slow = deferred<unknown>();
    mockApi({ a: () => slow.promise, b: { v: 2 } });
    const { container, rerender } = render(<h.Probe path="a" />);
    rerender(<h.Probe path="b" />);
    await act(flush);
    slow.resolve(reply(500, { error: "Old failure" }));
    await act(flush);
    expect(container.textContent).toBe("v2");
  });

  test("refreshes on an interval while visible and not paused", async () => {
    const h = await harness();
    const api = mockApi({ thing: { v: 1 } });
    fakeIntervals();
    const { unmount } = render(<h.Probe path="thing" refresh={5} />);
    await advance(4999);
    expect(api.to("thing")).toHaveLength(1);
    await advance(1);
    expect(api.to("thing")).toHaveLength(2);

    const visibility = vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden");
    await advance(5000);
    expect(api.to("thing")).toHaveLength(2);
    visibility.mockReturnValue("visible");

    await act(() => h.state.pausedStore.set(true));
    await advance(20_000);
    expect(api.to("thing")).toHaveLength(2);
    await act(() => h.state.pausedStore.set(false));
    await advance(5000);
    expect(api.to("thing")).toHaveLength(3);

    unmount();
    await advance(20_000);
    expect(api.to("thing")).toHaveLength(3);
  });

  test("doesn't refresh without an interval", async () => {
    const h = await harness();
    const api = mockApi({ thing: { v: 1 } });
    fakeIntervals();
    render(<h.Probe path="thing" />);
    await advance(60_000);
    expect(api.to("thing")).toHaveLength(1);
  });
});
