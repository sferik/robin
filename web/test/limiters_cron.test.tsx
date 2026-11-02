import { act, fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import { renderPage, settle } from "./render_page";

const Lim = load(() => import("../src/pages/limiters"));
const Cron = load(() => import("../src/pages/cron"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

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

const LIMITERS = [
  { name: "stripe", type: "concurrent", limit: 10, interval: null, used: 10, over_limit_count: 4, last_used_at: NOW - 5000 },
  { name: "geo/coder", type: "bucket", limit: 50, interval: 1, used: 12, over_limit_count: null, last_used_at: null },
  { name: "smtp", type: "window", limit: 1000, interval: 3600, used: null, over_limit_count: 0, last_used_at: NOW - 60_000 },
  { name: "crawl", type: "leaky", limit: 60, interval: 86400, used: 61, over_limit_count: 2, last_used_at: NOW },
  { name: "llm", type: "points", limit: 90000, interval: 60, used: 1, over_limit_count: 0, last_used_at: NOW },
  { name: "odd", type: "custom", limit: 5, interval: 7200, used: 0, over_limit_count: 0, last_used_at: NOW },
];

describe("Limiters", () => {
  test("lists limiters with their usage", async () => {
    mockApi({ limiters: { available: true, limiters: LIMITERS } });
    const { container } = await renderPage(<Lim.m.Limiters />);
    expect(container).toMatchSnapshot();
  });

  test("hides controls without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ limiters: { available: true, limiters: LIMITERS.slice(0, 1) } });
    const { container } = await renderPage(<Lim.m.Limiters />);
    expect(container.querySelectorAll("button")).toHaveLength(0);
  });

  test("resets and deletes after confirming", async () => {
    const api = mockApi({
      limiters: { available: true, limiters: LIMITERS.slice(1, 2) },
      "POST limiters/geo%2Fcoder/reset": { ok: true },
      "DELETE limiters/geo%2Fcoder": { ok: true },
    });
    await renderPage(<Lim.m.Limiters />);
    fireEvent.click(screen.getByText("Reset"));
    expect(await confirm()).toEqual({
      title: "Reset geo/coder?", body: "Its current usage is cleared, so waiting jobs may run right away.", action: "Reset", danger: undefined,
    });
    expect(api.to("limiters/geo%2Fcoder/reset", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Reset geo/coder");
    expect(api.to("limiters")).toHaveLength(2);
    fireEvent.click(screen.getByText("Delete"));
    expect(await confirm()).toEqual({
      title: "Delete geo/coder?", body: "Its state and statistics are removed. It's recreated the next time a job uses it.", action: "Delete", danger: true,
    });
    expect(api.to("limiters/geo%2Fcoder", "DELETE")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Deleted geo/coder");
    expect(api.to("limiters")).toHaveLength(3);
  });

  test("explains missing support and empty lists", async () => {
    const api = mockApi({ limiters: { available: false } });
    const { container } = await renderPage(<Lim.m.Limiters />);
    expect(container.textContent).toContain("Rate limits aren't available on this server");
    expect(container.textContent).toContain("This server's Robin version doesn't include rate limiting.");
    api.routes.limiters = { available: true };
    const empty = await renderPage(<Lim.m.Limiters />);
    expect(empty.container.querySelector(".empty")).toMatchSnapshot();
  });

  test("shows loading and errors", async () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<Lim.m.Limiters />);
    expect(loading.container.querySelector(".panel [aria-busy]")).not.toBeNull();
    loading.unmount();
    const api = mockApi({ limiters: reply(500, { error: "Nope" }) });
    const { container } = await renderPage(<Lim.m.Limiters />);
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("NopeTry again");
    api.routes.limiters = { available: true, limiters: [] };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.textContent).toContain("No rate limiters yet");
  });
});

const JOBS = [
  { id: "hourly", cron: "0 * * * *", class: "SyncJob", queue: "default", args: [], tz: null, description: null, next_at: NOW + 60_000, last_at: NOW - 3_540_000, last_jid: "j1", paused: false },
  { id: "digest/1", cron: "0 9 * * 1-5", class: "Digest", queue: "mail", args: ["weekly", 2], tz: "America/New_York", description: "Morning digest", next_at: null, last_at: null, last_jid: null, paused: true },
];

describe("Cron", () => {
  test("lists periodic jobs and the leader", async () => {
    mockApi({ cron: { available: true, jobs: JOBS, leader: "web-2:7:ab" } });
    const { container } = await renderPage(<Cron.m.Cron />);
    expect(container).toMatchSnapshot();
  });

  test("runs and pauses jobs", async () => {
    const api = mockApi({
      cron: { available: true, jobs: JOBS, leader: null },
      "POST cron/hourly/enqueue": { jid: "new1" },
      "POST cron/hourly/pause": { ok: true },
      "POST cron/digest%2F1/unpause": { ok: true },
    });
    const { container } = await renderPage(<Cron.m.Cron />);
    expect(container.querySelector(".subtitle")?.textContent).toBe("Jobs pushed on a schedule by the cluster leader.");
    const [run] = screen.getAllByText("Run now");
    fireEvent.click(run);
    await settle();
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Enqueued SyncJob as new1");
    fireEvent.click(screen.getByText("Pause"));
    await settle();
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Paused SyncJob");
    fireEvent.click(screen.getByText("Resume"));
    await settle();
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Resumed Digest");
    expect(api.calls.filter((c) => c.method === "POST").map((c) => c.path)).toEqual(["cron/hourly/enqueue", "cron/hourly/pause", "cron/digest%2F1/unpause"]);
    expect(api.to("cron")).toHaveLength(4);
  });

  test("hides actions without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ cron: { available: true, jobs: JOBS } });
    const { container } = await renderPage(<Cron.m.Cron />);
    expect(container.querySelectorAll("button")).toHaveLength(0);
  });

  test("explains missing support, empty lists, loading and errors", async () => {
    const api = mockApi({ cron: { available: false } });
    const { container } = await renderPage(<Cron.m.Cron />);
    expect(container.textContent).toContain("Cron jobs aren't available on this serverThis server's Robin version doesn't include periodic jobs.");
    api.routes.cron = { available: true, jobs: [] };
    expect((await renderPage(<Cron.m.Cron />)).container.querySelector(".empty")).toMatchSnapshot();
    api.routes.cron = { available: true };
    expect((await renderPage(<Cron.m.Cron />)).container.textContent).toContain("No cron jobs registered");
    api.routes.cron = reply(500, { error: "Down" });
    const failed = await renderPage(<Cron.m.Cron />);
    expect(failed.container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    expect((await renderPage(<Cron.m.Cron />)).container.querySelector(".panel [aria-busy]")).not.toBeNull();
  });
});

describe("CronDetail", () => {
  test("shows a job's schedule and recent runs", async () => {
    mockApi({ "cron/digest%2F1": { available: true, job: { ...JOBS[1], last_jid: "abc" }, history: [{ at: NOW - 86_400_000, jid: "r1" }, { at: NOW - 172_800_000, jid: "r 2" }] } });
    const { container } = await renderPage(<Cron.m.CronDetail id="digest/1" />);
    expect(container).toMatchSnapshot();
  });

  test("handles a job that hasn't run", async () => {
    mockApi({ "cron/hourly": { available: true, job: { ...JOBS[0], last_jid: null } } });
    const { container } = await renderPage(<Cron.m.CronDetail id="hourly" />);
    expect(container).toMatchSnapshot();
  });

  test("explains missing jobs, loading and errors", async () => {
    const api = mockApi({ "cron/x": { available: false } });
    expect((await renderPage(<Cron.m.CronDetail id="x" />)).container.textContent).toBe("Cron jobs aren't available on this serverThis server's Robin version doesn't include periodic jobs.");
    api.routes["cron/x"] = reply(404, { error: "No such job" });
    const failed = await renderPage(<Cron.m.CronDetail id="x" />);
    expect(failed.container.querySelector(".crumb")?.innerHTML).toBe('<a href="/robin/cron">Cron</a>');
    expect(failed.container.querySelector('[role="alert"]')?.textContent).toBe("No such jobTry again");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<Cron.m.CronDetail id="x" />);
    expect(loading.container.querySelectorAll(".skeleton")).toHaveLength(8);
  });

  test("retries after an error", async () => {
    const api = mockApi({ "cron/hourly": reply(500, { error: "Down" }) });
    const { container } = await renderPage(<Cron.m.CronDetail id="hourly" />);
    api.routes["cron/hourly"] = { available: true, job: JOBS[0], history: [] };
    await act(() => {
      fireEvent.click(screen.getByText("Try again"));
    });
    await settle();
    expect(container.querySelector("h1")?.textContent).toBe("SyncJob");
  });
});
