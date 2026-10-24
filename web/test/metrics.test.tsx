import { fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, mockApi, reply, session, stubLayout } from "./helpers";
import { renderPage, settle } from "./render_page";

const M = load(() => import("../src/pages/metrics"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  stubLayout(800);
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
});

const minutes = (n: number, start = 202610140900) => Array.from({ length: n }, (_, i) => ({ t: String(start + i), s: 10 * i, f: i % 2, ms: 100 * i }));
const hours = (n: number) => Array.from({ length: n }, (_, i) => ({ t: String(2026101400 + i), s: 100, f: 1, ms: 1000 }));

const CLASSES = {
  "Billing::Charge": { s: 900, f: 3, ms: 90_000, avg_ms: 99.7 },
  "Mailer": { s: 50, f: 0, ms: 2_500, avg_ms: 50 },
  "Report": { s: 100, f: 100, ms: 4_000_000, avg_ms: 20_000 },
};

const queuePoints = (names: string[], n = 3) =>
  Array.from({ length: n }, (_, i) => ({
    t: String(202610140900 + i),
    queues: Object.fromEntries(names.filter((_, j) => i > 0 || j === 0).map((q, j) => [q, { size: (j + 1) * 10 + i, latency: 1 }])),
  }));

describe("Metrics", () => {
  test("shows executions, classes and queue sizes for the last hour", async () => {
    const api = mockApi({ metrics: { classes: CLASSES, series: minutes(4) }, "metrics/queues": { points: queuePoints(["default", "mail"]) } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect(container).toMatchSnapshot();
    expect([...api.to("metrics")[0].url.searchParams]).toEqual([["minutes", "60"]]);
    expect([...api.to("metrics/queues")[0].url.searchParams]).toEqual([["granularity", "minute"], ["points", "60"]]);
  });

  test("switches windows, using hourly history for days", async () => {
    const api = mockApi({
      metrics: { classes: CLASSES, series: minutes(3) },
      "metrics/history": { classes: { Mailer: { s: 1000, f: 1, ms: 5, avg_ms: 1 } }, series: hours(3) },
      "metrics/queues": { points: queuePoints(["default"]) },
    });
    const { container } = await renderPage(<M.m.Metrics />);
    fireEvent.click(screen.getByText("8 hours"));
    await settle();
    expect([...api.to("metrics").at(-1)!.url.searchParams]).toEqual([["minutes", "480"]]);
    expect(container.querySelector(".subtitle")?.textContent).toBe("1,153 executions in the last 8 hours, 8.9% failed.");
    fireEvent.click(screen.getByText("7 days"));
    await settle();
    expect([...api.to("metrics/history").at(-1)!.url.searchParams]).toEqual([["hours", "168"]]);
    expect([...api.to("metrics/queues").at(-1)!.url.searchParams]).toEqual([["granularity", "hour"], ["points", "168"]]);
    expect(container.querySelector(".subtitle")?.textContent).toBe("1,001 executions in the last 7 days, 0.10% failed.");
    expect(container.querySelector(".panel-note")?.textContent).toBe("per hour");
    expect([...container.querySelectorAll(".chart svg")[0].querySelectorAll(".axis text[text-anchor='start'], .axis text[text-anchor='middle']")].map((t) => t.textContent)).toEqual([
      "Oct 14, 12 AM", "Oct 14, 01 AM", "Oct 14, 02 AM",
    ]);
    expect(screen.getByText("7 days").getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(screen.getByText("30 days"));
    await settle();
    expect([...api.to("metrics/history").at(-1)!.url.searchParams]).toEqual([["hours", "720"]]);
    expect(container.querySelector(".subtitle")?.textContent).toBe("1,001 executions in the last 30 days, 0.10% failed.");
    fireEvent.click(screen.getByText("1 hour"));
    await settle();
    expect(container.querySelector(".subtitle")?.textContent).toBe("1,153 executions in the last hour, 8.9% failed.");
  });

  test("refreshes hourly history less often", async () => {
    vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
    const api = mockApi({ metrics: { classes: {}, series: [] }, "metrics/history": { classes: {}, series: [] }, "metrics/queues": { points: [] } });
    await renderPage(<M.m.Metrics />);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(api.to("metrics")).toHaveLength(2);
    fireEvent.click(screen.getByText("7 days"));
    await settle();
    await vi.advanceTimersByTimeAsync(299_999);
    expect(api.to("metrics/history")).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(api.to("metrics/history")).toHaveLength(2);
  });

  test("filters classes by name", async () => {
    mockApi({ metrics: { classes: CLASSES, series: minutes(2) }, "metrics/queues": { points: [] } });
    const { container } = await renderPage(<M.m.Metrics />);
    const rows = () => [...container.querySelectorAll("tbody tr td:first-child")].map((t) => t.textContent);
    expect(rows()).toEqual(["Billing::Charge", "Report", "Mailer"]);
    fireEvent.input(screen.getByLabelText("Filter by class"), { target: { value: "MAIL" } });
    expect(rows()).toEqual(["Mailer"]);
    fireEvent.input(screen.getByLabelText("Filter by class"), { target: { value: "zzz" } });
    expect(container.querySelector(".grid-3-1 .empty h3")?.textContent).toBe("No classes match");
  });

  test("explains quiet windows", async () => {
    mockApi({ metrics: { classes: {}, series: [] }, "metrics/queues": { points: queuePoints([]) } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect(container.querySelector(".subtitle")?.textContent).toBe("0 executions in the last hour, none failed.");
    expect(container.querySelector(".grid-3-1")).toMatchSnapshot();
  });

  test("shows at most five queues, in a stable order", async () => {
    const names = ["f", "e", "d", "c", "b", "a"];
    mockApi({ metrics: { classes: {}, series: [] }, "metrics/queues": { points: queuePoints(names) } });
    const { container } = await renderPage(<M.m.Metrics />);
    const panel = container.querySelectorAll(".grid-3-1 > .panel")[1];
    expect([...panel.querySelectorAll(".legend span")].map((s) => s.textContent)).toEqual(["a", "b", "c", "d", "e"]);
    expect(panel.querySelector(".small.dim")?.textContent).toBe("Showing the five queues with the largest peaks.");
    expect(panel.querySelector(".tt-row")).toBeNull();
    expect(panel.querySelector(".legend")).toMatchSnapshot();
  });

  test("reports failure rates precisely", async () => {
    const api = mockApi({ metrics: { classes: { A: { s: 1000, f: 10, ms: 1, avg_ms: 1 } }, series: [] }, "metrics/queues": { points: [] } });
    const { container, unmount } = await renderPage(<M.m.Metrics />);
    expect(container.querySelector(".subtitle")?.textContent).toBe("1,010 executions in the last hour, 0.99% failed.");
    unmount();
    api.routes.metrics = { classes: { A: { s: 99, f: 1, ms: 1, avg_ms: 1 } }, series: [] };
    const exact = await renderPage(<M.m.Metrics />);
    expect(exact.container.querySelector(".subtitle")?.textContent).toBe("100 executions in the last hour, 1.0% failed.");
  });

  test("ranks classes by total executions, failures included", async () => {
    mockApi({ metrics: { classes: { Quiet: { s: 300, f: 0, ms: 1, avg_ms: 1 }, Flaky: { s: 1, f: 500, ms: 1, avg_ms: 1 } }, series: [] }, "metrics/queues": { points: [] } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect([...container.querySelectorAll("tbody tr td:first-child")].map((t) => t.textContent)).toEqual(["Flaky", "Quiet"]);
  });

  test("charts queues that had jobs, even if others never did", async () => {
    mockApi({ metrics: { classes: {}, series: [] }, "metrics/queues": { points: [{ t: "202610140900", queues: { a: { size: 0, latency: 0 }, b: { size: 5, latency: 0 } } }] } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect(container.querySelector(".chart-empty")).toBeNull();
    expect([...container.querySelectorAll(".grid-3-1 .legend span")].map((s) => s.textContent)).toEqual(["a", "b"]);
  });

  test("doesn't mention trimming with exactly five queues", async () => {
    mockApi({ metrics: { classes: {}, series: [] }, "metrics/queues": { points: queuePoints(["a", "b", "c", "d", "e"]) } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect(container.querySelectorAll(".grid-3-1 .legend span")).toHaveLength(5);
    expect(container.querySelector(".grid-3-1 .small.dim")).toBeNull();
  });

  test("says when every sampled queue is empty", async () => {
    mockApi({ metrics: { classes: {}, series: [] }, "metrics/queues": { points: [{ t: "202610140900", queues: { a: { size: 0, latency: 0 } } }] } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect(container.querySelector(".chart-empty")?.textContent).toBe("Queue sizes are sampled once a minute by the leader process.");
  });

  test("shows loading and errors", async () => {
    const api = mockApi({ metrics: reply(500, { error: "Down" }), "metrics/queues": { points: [] } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes.metrics = { classes: {}, series: [] };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.querySelector("h1")?.textContent).toBe("Metrics");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<M.m.Metrics />);
    expect(loading.container.querySelector(".subtitle")).toBeNull();
    expect(loading.container.querySelectorAll('[aria-busy="true"]')).toHaveLength(3);
  });
});

describe("deploy marks", () => {
  const at = Date.UTC(2026, 9, 14, 9, 1, 30);

  test("are drawn on the executions chart", async () => {
    mockApi({ metrics: { classes: CLASSES, series: minutes(4), deploys: [{ at, label: "v9" }] }, "metrics/queues": { points: queuePoints(["default"]) } });
    const { container } = await renderPage(<M.m.Metrics />);
    expect([...container.querySelectorAll(".mark title")].map((t) => t.textContent)).toEqual(["Deploy: v9"]);
  });

  test("are drawn on a class's charts", async () => {
    mockApi({
      "metrics/jobs/J": {
        class: "J", minutes: 60, totals: { s: 1, f: 0, ms: 1, avg_ms: 1 }, histogram: [{ le: 50, count: 1 }],
        series: minutes(4), deploys: [{ at, label: "v9" }],
      },
    });
    const { container } = await renderPage(<M.m.MetricsJob klass="J" />);
    expect(container.querySelectorAll(".mark")).toHaveLength(2);
  });
});

describe("MetricsJob", () => {
  const JOB = {
    class: "Billing::Charge", minutes: 60, totals: { s: 900, f: 3, ms: 90_000, avg_ms: 99.7 },
    series: [{ t: "202610140900", s: 9, f: 1, ms: 1000 }, { t: "202610140901", s: 0, f: 0, ms: 0 }, { t: "202610140902", s: 1, f: 1, ms: 10 }, { t: "202610140903", s: 1, f: 0, ms: 5 }],
    histogram: [{ le: 50, count: 0 }, { le: 100, count: 800 }, { le: null, count: 103 }],
  };

  test("shows a class's executions, timing and histogram", async () => {
    const api = mockApi({ "metrics/jobs/Billing%3A%3ACharge": JOB });
    const { container } = await renderPage(<M.m.MetricsJob klass="Billing::Charge" />);
    expect(container).toMatchSnapshot();
    expect([...api.calls[0].url.searchParams]).toEqual([["minutes", "60"]]);
    const avgPanel = () => container.querySelectorAll(".grid-2 > .panel")[2];
    fireEvent.mouseMove(avgPanel().querySelector("svg")!, { clientX: 9999 });
    await settle();
    expect(avgPanel().querySelector(".tooltip")?.textContent).toBe("09:02 AMAverage5 ms");
  });

  test("switches windows", async () => {
    const api = mockApi({ "metrics/jobs/Mailer": { ...JOB, class: "Mailer", totals: { s: 5, f: 0, ms: 50, avg_ms: 10 } } });
    const { container } = await renderPage(<M.m.MetricsJob klass="Mailer" />);
    expect(container.querySelector(".subtitle")?.textContent).toBe("5 executions in the last hour, averaging 10 ms.");
    fireEvent.click(screen.getByText("4 h"));
    await settle();
    expect(api.calls.at(-1)?.url.searchParams.get("minutes")).toBe("240");
    expect(container.querySelector(".subtitle")?.textContent).toBe("5 executions in the last 4 hours, averaging 10 ms.");
    expect(screen.getByText("4 h").getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(screen.getByText("8 h"));
    await settle();
    expect(api.calls.at(-1)?.url.searchParams.get("minutes")).toBe("480");
  });

  test("shows loading and errors", async () => {
    const api = mockApi({ "metrics/jobs/X": reply(500, { error: "Down" }) });
    const { container } = await renderPage(<M.m.MetricsJob klass="X" />);
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes["metrics/jobs/X"] = { ...JOB, class: "X" };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.querySelector("h1")?.textContent).toBe("X");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<M.m.MetricsJob klass="X" />);
    expect(loading.container.querySelector(".subtitle")).toBeNull();
    expect(loading.container.querySelectorAll(".skeleton")).toHaveLength(8);
  });
});
