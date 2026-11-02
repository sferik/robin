import { act, fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, mockApi, reply, session, STATS, stubLayout } from "./helpers";
import { renderPage, settle } from "./render_page";

const D = load(() => import("../src/pages/dashboard"));
const State = load(() => import("../src/state"));

beforeEach(() => {
  freezeTime();
  stubLayout(800);
  State.m.sessionStore.set(session());
  State.m.liveStore.set(null);
});

// q3 and q5 tie for the oldest job; the first one wins.
const QUEUES = Array.from({ length: 9 }, (_, i) => ({ name: `q${i}`, size: (9 - i) * 100, latency: i === 3 || i === 5 ? 320 : i * 10, paused: i === 1 }));

const DASH = {
  stats: STATS,
  queues: QUEUES,
  history: {
    processed: { "2026-10-13": 1000, "2026-10-12": 500, "2026-10-14": 10 },
    failed: { "2026-10-13": 10, "2026-10-14": 20 },
  },
  realtime: [
    { t: "202610140927", s: 500, f: 5, ms: 1 },
    { t: "202610140928", s: 544, f: 1, ms: 1 },
    { t: "202610140929", s: 3, f: 0, ms: 1 },
  ],
  leader: "web-1:1:aa",
};

const statusLine = (c: Element) => c.querySelector(".status-line")?.textContent;

async function dashboard(data: unknown) {
  const api = mockApi({ dashboard: data });
  const page = await renderPage(<D.m.Dashboard />);
  return { ...page, api };
}

describe("Dashboard", () => {
  test("summarizes the cluster", async () => {
    const { container, api } = await dashboard(DASH);
    expect(container).toMatchSnapshot();
    expect([...api.to("dashboard")[0].url.searchParams]).toEqual([["minutes", "60"], ["days", "30"]]);
  });

  test("describes a busy cluster with a backlog", async () => {
    const { container } = await dashboard(DASH);
    expect(statusLine(container)).toBe(
      "Robin is working through 545 jobs a minute on 4 processes, with 15 threads busy right now. " +
        "The oldest of 4,581 waiting jobs has been in q3 for 5 m 20 s. 36 jobs are waiting to retry.",
    );
  });

  test("counts a single waiting job", async () => {
    const { container } = await dashboard({ ...DASH, stats: { ...STATS, enqueued: 1 }, queues: [{ name: "a", size: 1, latency: 3, paused: false }] });
    expect(statusLine(container)).toContain("The oldest of 1 waiting job has been in a for 3.0 s.");
  });

  test("describes quieter clusters", async () => {
    const quiet = { ...DASH, stats: { ...STATS, processes: 1, busy: 1, retries: 1 }, realtime: [{ t: "202610140927", s: 1, f: 0, ms: 1 }, { t: "202610140928", s: 0, f: 0, ms: 0 }], queues: [{ name: "a", size: 1, latency: 0.5, paused: false }] };
    const { container, api } = await dashboard(quiet);
    expect(statusLine(container)).toBe("Robin is working through 1 job a minute on 1 process, with 1 thread busy right now. 1 job is waiting to retry.");

    api.routes.dashboard = { ...quiet, stats: { ...quiet.stats, busy: 0, retries: 0 }, realtime: [] };
    const idle = await renderPage(<D.m.Dashboard />);
    expect(statusLine(idle.container)).toBe("Robin is standing by on 1 process. Nothing is waiting to retry.");

    api.routes.dashboard = { ...quiet, stats: { ...quiet.stats, busy: 2, enqueued: 0 }, realtime: [{ t: "1", s: 0, f: 0, ms: 0 }, { t: "2", s: 0, f: 0, ms: 0 }] };
    const running = await renderPage(<D.m.Dashboard />);
    expect(statusLine(running.container)).toBe("Robin is running on 1 process, with 2 threads busy right now. 1 job is waiting to retry.");

    api.routes.dashboard = { ...quiet, stats: { ...quiet.stats, enqueued: 5 }, queues: [{ name: "a", size: 5, latency: 1, paused: false }] };
    const waiting = await renderPage(<D.m.Dashboard />);
    expect(statusLine(waiting.container)).toContain("The oldest of 5 waiting jobs has been in a for 1.0 s.");

    api.routes.dashboard = { ...quiet, stats: { ...quiet.stats, enqueued: 0 }, queues: [{ name: "a", size: 0, latency: 9, paused: false }] };
    const drained = await renderPage(<D.m.Dashboard />);
    expect(statusLine(drained.container)).not.toContain("oldest");

    api.routes.dashboard = { ...quiet, stats: { ...quiet.stats, enqueued: 5 }, queues: [] };
    const noQueues = await renderPage(<D.m.Dashboard />);
    expect(statusLine(noQueues.container)).not.toContain("oldest");
  });

  test("explains when no processes are running", async () => {
    const down = { ...DASH, stats: { ...STATS, processes: 0, busy: 0, enqueued: 1, retries: 0 } };
    const { container, api } = await dashboard(down);
    expect(statusLine(container)).toBe("No Robin processes are running. 1 job is waiting for one to start.Nothing is waiting to retry.");
    expect(container.querySelector(".status-line")).toMatchSnapshot();
    api.routes.dashboard = { ...down, stats: { ...down.stats, enqueued: 7 } };
    expect(statusLine((await renderPage(<D.m.Dashboard />)).container)).toContain("7 jobs are waiting for one to start.");
    api.routes.dashboard = { ...down, stats: { ...down.stats, enqueued: 0 } };
    expect(statusLine((await renderPage(<D.m.Dashboard />)).container)).toBe("No Robin processes are running. Nothing is waiting, either.Nothing is waiting to retry.");
  });

  test("prefers live numbers when they arrive", async () => {
    const { container } = await dashboard(DASH);
    await act(() => {
      State.m.liveStore.set({ stats: { ...STATS, retries: 0, processed: 1 }, queues: { q0: 5000 }, at: 1 });
    });
    expect(container.querySelector(".fact-value")?.textContent).toBe("1");
    expect(container.querySelector(".fact.alert")).toBeNull();
    expect(container.querySelector("tbody td.r")?.textContent).toBe("5,000");
    expect(container.querySelectorAll("tbody td.r")[2].textContent).toBe("800");
    expect(container.querySelector<HTMLElement>(".qbar span")?.style.width).toBe("100%");
    expect(container.querySelectorAll<HTMLElement>(".qbar span")[1].style.width).toBe("16%");
  });

  test("changes the throughput and history windows", async () => {
    const { api } = await dashboard(DASH);
    fireEvent.click(screen.getByText("4 h"));
    await settle();
    expect(screen.getByText("4 h").getAttribute("aria-pressed")).toBe("true");
    expect(screen.getByText("1 h").getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(screen.getByText("8 h"));
    fireEvent.click(screen.getByText("90 d"));
    await settle();
    fireEvent.click(screen.getByText("7 d"));
    await settle();
    expect(api.to("dashboard").map((c) => `${c.url.searchParams.get("minutes")}/${c.url.searchParams.get("days")}`)).toEqual([
      "60/30", "240/30", "480/30", "480/90", "480/7",
    ]);
  });

  test("explains a cluster with no queues", async () => {
    const { container } = await dashboard({ ...DASH, queues: [] });
    expect(container.querySelector(".grid-3-1 .panel")?.textContent).toContain("No queues yet. They appear as soon as a job is pushed.");
  });

  test("labels days and explains them on hover", async () => {
    const { container } = await dashboard(DASH);
    const history = container.querySelectorAll(".grid-3-1 .panel")[1];
    expect([...history.querySelectorAll(".axis text[text-anchor='middle']")].map((t) => t.textContent)).toEqual(["10/12", "10/13", "10/14"]);
    fireEvent.mouseEnter(history.querySelectorAll("svg > g:not(.grid):not(.axis)")[1]);
    await settle();
    expect(history.querySelector(".tooltip")?.textContent).toBe("Tue, Oct 13Succeeded990Failed10");
    fireEvent.mouseEnter(history.querySelectorAll("svg > g:not(.grid):not(.axis)")[2]);
    await settle();
    expect(history.querySelector(".tooltip")?.textContent).toBe("Wed, Oct 14Succeeded0Failed20");
    fireEvent.mouseEnter(history.querySelectorAll("svg > g:not(.grid):not(.axis)")[0]);
    await settle();
    expect(history.querySelector(".tooltip")?.textContent).toBe("Mon, Oct 12Succeeded500Failed0");
  });

  test("shows loading and errors", async () => {
    const { container, api } = await dashboard(reply(500, { error: "Down" }));
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes.dashboard = DASH;
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.querySelector(".status-line")).not.toBeNull();
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    expect((await renderPage(<D.m.Dashboard />)).container.querySelectorAll(".skeleton")).toHaveLength(8);
  });
});
