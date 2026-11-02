import { fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, job, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import { renderPage, settle } from "./render_page";

const B = load(() => import("../src/pages/busy"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  State.m.sessionStore.set(session());
  State.m.toastStore.set([]);
  State.m.confirmStore.set(null);
});

async function answer(ok: boolean) {
  await settle();
  const req = State.m.confirmStore.get();
  if (!req) return null;
  const shown = [req.title, req.body, req.action, req.danger];
  req.resolve(ok);
  State.m.confirmStore.set(null);
  await settle();
  return shown;
}

const proc = (overrides: Record<string, unknown> = {}) => ({
  identity: "web-1.local:4242:ab12", hostname: "web-1.local", pid: 4242, tag: "app", labels: [], started_at: NOW - 86_400_000,
  version: "0.1.0", env: "production", embedded: false, concurrency: 5, queues: ["critical", "default"],
  busy: 2, beat: NOW - 2000, quiet: false, leader: true, rss_kb: 204_800, rtt_us: 1500, ...overrides,
});

const BUSY = {
  leader: "web-1.local:4242:ab12",
  processes: [
    proc({ gvl_contention: 12.4 }),
    proc({ identity: "web-2:7:cd", tag: null, leader: false, quiet: true, embedded: true, concurrency: 100, busy: 0, rss_kb: 0, rtt_us: 0 }),
  ],
  work: [
    { identity: "web-1.local:4242:ab12", thread: "robin.default.0", queue: "mail ers", run_at: NOW - 30_000, job: job({ jid: "w1", tags: ["eu"] }), progress: { pct: 42.5, msg: "Row 425", at: NOW } },
    { identity: "web-2:7:cd", thread: "robin.default.1", queue: "default", run_at: NOW - 5000, job: job({ jid: "w2", class: "Other", wrapper: "AJ::W" }), progress: { pct: 0, msg: null, at: NOW } },
    { identity: "web-2:7:cd", thread: "robin.default.2", queue: "default", run_at: NOW, job: job({ jid: "w3" }), progress: null },
    { identity: "web-2:7:cd", thread: "robin.default.3", queue: "default", run_at: NOW, job: job({ jid: "w4" }), progress: { pct: null, msg: null, at: NOW, meta: { iterations: 1200 } } },
  ],
};

describe("Busy", () => {
  test("narrows the page to processes or running jobs", async () => {
    mockApi({ busy: BUSY });
    R.m.navigate("/busy?only=bogus", { replace: true });
    const { container } = await renderPage(<B.m.Busy />);
    const headings = () => [...container.querySelectorAll("h2")].map((h) => h.textContent);
    const pressed = () => [...container.querySelectorAll('[aria-label="Show"] button')].map((b) => [b.textContent, b.getAttribute("aria-pressed")]);
    const choose = async (label: string) => {
      fireEvent.click([...container.querySelectorAll('[aria-label="Show"] button')].find((b) => b.textContent === label)!);
      await settle();
    };
    expect(headings()).toEqual(["Processes", "Running jobs"]);
    expect(pressed()).toEqual([["All", "true"], ["Processes", "false"], ["Running jobs", "false"]]);
    await choose("Processes");
    expect(location.search).toBe("?only=processes");
    expect(headings()).toEqual(["Processes"]);
    expect(pressed()).toEqual([["All", "false"], ["Processes", "true"], ["Running jobs", "false"]]);
    await choose("Running jobs");
    expect(location.search).toBe("?only=jobs");
    expect(headings()).toEqual(["Running jobs"]);
    expect(pressed()).toEqual([["All", "false"], ["Processes", "false"], ["Running jobs", "true"]]);
    await choose("All");
    expect(location.search).toBe("");
    expect(headings()).toEqual(["Processes", "Running jobs"]);
    R.m.navigate("/", { replace: true });
  });

  test("shows processes and running jobs", async () => {
    mockApi({ busy: BUSY });
    const { container } = await renderPage(<B.m.Busy />);
    expect(container).toMatchSnapshot();
    expect(container.querySelectorAll(".threads")[1].querySelectorAll("i")).toHaveLength(64);
  });

  test("signals one process", async () => {
    const api = mockApi({ busy: BUSY, "POST processes/web-1.local%3A4242%3Aab12/dump": {}, "POST processes/web-1.local%3A4242%3Aab12/quiet": {}, "POST processes/web-1.local%3A4242%3Aab12/stop": {} });
    const { container } = await renderPage(<B.m.Busy />);
    const first = container.querySelector(".proc")!;
    const button = (name: string) => [...first.querySelectorAll("button")].find((b) => b.textContent === name)!;

    fireEvent.click(button("Dump threads"));
    expect(await answer(true)).toBeNull();
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Thread dump requested; check the process logs");

    fireEvent.click(button("Quiet"));
    expect(await answer(true)).toEqual([
      "Quiet web-1.local?", "It finishes the jobs it's running but won't start new ones. This can't be undone without restarting it.", "Quiet", undefined,
    ]);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Quiet signal sent");

    fireEvent.click(button("Stop"));
    expect(await answer(true)).toEqual([
      "Stop web-1.local?", "Running jobs get the shutdown timeout to finish; unfinished jobs go back on their queues.", "Stop", true,
    ]);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Stop signal sent");
    expect(api.calls.filter((c) => c.method === "POST").map((c) => c.path)).toEqual([
      "processes/web-1.local%3A4242%3Aab12/dump", "processes/web-1.local%3A4242%3Aab12/quiet", "processes/web-1.local%3A4242%3Aab12/stop",
    ]);
    expect(api.to("busy")).toHaveLength(4);
  });

  test("signals every process", async () => {
    const api = mockApi({ busy: BUSY, "POST processes/quiet": {}, "POST processes/stop": {} });
    await renderPage(<B.m.Busy />);
    fireEvent.click(screen.getByText("Quiet all"));
    expect((await answer(true))?.[0]).toBe("Quiet every process?");
    fireEvent.click(screen.getByText("Stop all"));
    expect((await answer(false))?.[0]).toBe("Stop every process?");
    expect(api.calls.filter((c) => c.method === "POST").map((c) => c.path)).toEqual(["processes/quiet"]);
  });

  test("cancels a running job", async () => {
    const api = mockApi({ busy: BUSY, "POST jobs/w1/cancel": {} });
    await renderPage(<B.m.Busy />);
    fireEvent.click(screen.getAllByText("Cancel")[0]);
    expect(await answer(true)).toEqual(["Cancel HardJob?", "The job sees cancelled? turn true and should stop at its next check.", "Cancel job", true]);
    expect(api.to("jobs/w1/cancel", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Cancellation requested");
  });

  test("hides controls without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ busy: BUSY });
    const { container } = await renderPage(<B.m.Busy />);
    expect([...container.querySelectorAll("button:not(.jid)")].filter((b) => !b.closest(".seg"))).toHaveLength(0);
    expect(container.querySelector(".resizes, input")).toBeNull();
  });

  test("shows GVL contention, flagged when high", async () => {
    mockApi({
      busy: {
        leader: null, work: [],
        processes: [
          proc({ identity: "a:1:x", gvl_contention: 49.4 }), proc({ identity: "b:2:x", gvl_contention: 50 }), proc({ identity: "c:3:x", gvl_contention: 0 }),
          proc({ identity: "d:4:x", gvl_contention: null }), proc({ identity: "e:5:x" }),
        ],
      },
    });
    const { container } = await renderPage(<B.m.Busy />);
    const cells = [...container.querySelectorAll(".proc")].map((p) => p.children[4]);
    expect(cells.map((c) => [c.className, c.textContent, c.querySelector(".lat-warn")?.textContent])).toEqual([
      ["proc-hide", "GVL wait49%", undefined], ["proc-hide", "GVL wait50% high", "50% high"], ["proc-hide", "GVL wait0%", undefined],
      ["proc-hide", "", undefined], ["proc-hide", "", undefined],
    ]);
    expect(cells[1].querySelector(".proc-k")?.getAttribute("title")).toBe("Share of the last heartbeat interval threads spent waiting for Ruby's global VM lock (GVL)");
    expect(cells[1].querySelector(".proc-v .lat-warn")?.getAttribute("title")).toBe(
      "Threads often wait for the GVL; CPU-heavy jobs may run better with fewer threads or more processes",
    );
  });

  test("resizes a capsule", async () => {
    const one = proc({ identity: "a:1:x", capsules: { default: { concurrency: 5, queues: {} }, bulk: { concurrency: 2, queues: {} } } });
    const api = mockApi({
      busy: { leader: null, work: [], processes: [one, proc({ identity: "b:2:x", concurrency: 3 }), proc({ identity: "c:3:x", quiet: true })] },
      "POST processes/a%3A1%3Ax/resize": {},
      "POST processes/b%3A2%3Ax/resize": reply(400, { error: "concurrency must be 1 to 1000" }),
    });
    const { container } = await renderPage(<B.m.Busy />);
    const procs = [...container.querySelectorAll(".proc")];
    const forms = (p: Element) => [...p.querySelectorAll("form.resize")] as HTMLFormElement[];
    expect(procs.map((p) => forms(p).map((f) => [f.querySelector("label")!.textContent, f.querySelector("input")!.value]))).toEqual([
      [["default threads ", "5"], ["bulk threads ", "2"]], [["Threads ", "3"]], [],
    ]);
    expect(procs[2].querySelector(".resizes")).toBeNull();
    const [first, bulk] = forms(procs[0]);
    const input = first.querySelector("input")!;
    expect([input.type, input.min, input.max, input.step, input.required, input.className]).toEqual(["number", "1", "1000", "1", true, "input"]);
    const apply = first.querySelector("button")!;
    expect([apply.textContent, apply.type, apply.className]).toEqual(["Apply", "submit", "btn btn-small"]);
    const enabled = (value: string) => {
      fireEvent.input(input, { target: { value } });
      return !apply.disabled;
    };
    expect(["5", "", "0", "1", "1000", "1001", "2.5", "-3", "abc", "8"].map(enabled)).toEqual([false, false, false, true, true, false, false, false, false, true]);

    expect(fireEvent.submit(first)).toBe(false);
    await settle();
    expect(api.to("processes/a%3A1%3Ax/resize", "POST").map((c) => c.body)).toEqual([{ concurrency: 8, capsule: "default" }]);
    expect(State.m.toastStore.get().at(-1)).toMatchObject({ message: "Resize requested; the new thread count shows at the next heartbeat", kind: "ok" });
    expect(api.to("busy")).toHaveLength(2);
    // The heartbeat hasn't caught up: what was typed stays.
    expect(input.value).toBe("8");

    fireEvent.input(bulk.querySelector("input")!, { target: { value: "4" } });
    fireEvent.submit(bulk);
    await settle();
    expect(api.to("processes/a%3A1%3Ax/resize", "POST").at(-1)?.body).toEqual({ concurrency: 4, capsule: "bulk" });

    const other = forms(procs[1])[0];
    fireEvent.input(other.querySelector("input")!, { target: { value: "7" } });
    fireEvent.submit(other);
    await settle();
    expect(api.to("processes/b%3A2%3Ax/resize", "POST").map((c) => c.body)).toEqual([{ concurrency: 7, capsule: "default" }]);
    expect(State.m.toastStore.get().at(-1)).toMatchObject({ message: "concurrency must be 1 to 1000", kind: "error" });
    expect(api.to("busy")).toHaveLength(4);

    // A heartbeat with a new count replaces what was typed.
    api.routes.busy = { leader: null, work: [], processes: [{ ...one, capsules: { default: { concurrency: 6, queues: {} }, bulk: { concurrency: 3, queues: {} } } }] };
    fireEvent.submit(bulk);
    await settle();
    expect(forms(container.querySelector(".proc")!).map((f) => [f.querySelector("input")!.value, f.querySelector("button")!.disabled])).toEqual([["6", true], ["3", true]]);
  });

  test("explains idle clusters", async () => {
    const api = mockApi({ busy: { leader: null, processes: [], work: [] } });
    const { container } = await renderPage(<B.m.Busy />);
    expect(container).toMatchSnapshot();
    api.routes.busy = { leader: null, processes: [proc({ busy: 0, concurrency: 1 })], work: [] };
    const one = await renderPage(<B.m.Busy />);
    expect(one.container.querySelectorAll(".empty")).toHaveLength(1);
    expect(one.container.querySelector(".subtitle")?.textContent).toBe("1 process running 0 of 1 thread.");
    expect(one.container.querySelector(".threads")?.getAttribute("aria-label")).toBe("0 of 1 thread busy");
  });

  test("shows loading and errors", async () => {
    const api = mockApi({ busy: reply(500, { error: "Down" }) });
    const { container } = await renderPage(<B.m.Busy />);
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes.busy = BUSY;
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.querySelector(".subtitle")?.textContent).toBe("2 processes running 2 of 105 threads.");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<B.m.Busy />);
    expect(loading.container.querySelectorAll('[aria-busy="true"]')).toHaveLength(2);
    expect(loading.container.querySelector(".subtitle, .page-head .btn")).toBeNull();
  });
});
