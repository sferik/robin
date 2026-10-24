import { fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, job, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import { renderPage, settle } from "./render_page";

const P = load(() => import("../src/pages/job"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
});

describe("JobLookup", () => {
  test("shows a running job with its progress", async () => {
    mockApi({
      "jobs/j%201": {
        jid: "j 1", cancelled: true, progress: { pct: 42, msg: "Row 42", at: NOW },
        results: [{ where: "busy", identity: "web-1:9:aa", thread: "t1", job: job({ jid: "j 1" }) }],
      },
    });
    const { container } = await renderPage(<P.m.JobLookup jid="j 1" />);
    expect(container).toMatchSnapshot();
  });

  test("shows a queued job and where else it appears", async () => {
    mockApi({
      "jobs/j2": {
        jid: "j2", cancelled: false, progress: { pct: 10, msg: null, at: NOW },
        results: [
          { where: "queue", queue: "mail", job: job({ jid: "j2" }) },
          { where: "retries", job: job({ jid: "j2", id: "1-j2", at: NOW + 1000, error_class: "Boom", error_message: "m", payload: { a: 1 } }) },
          { where: "mystery", job: job({ jid: "j2", id: "x" }) },
          { where: "scheduled", job: job({ jid: "j2" }) },
        ],
      },
    });
    const { container } = await renderPage(<P.m.JobLookup jid="j2" />);
    expect(container).toMatchSnapshot();
  });

  test("offers no cancel button for dead jobs", async () => {
    mockApi({ "jobs/j3": { jid: "j3", cancelled: false, progress: null, results: [{ where: "dead", job: job({ jid: "j3", id: "5-j3" }) }] } });
    const { container } = await renderPage(<P.m.JobLookup jid="j3" />);
    expect(container.querySelector(".page-head button")).toBeNull();
    expect(container.querySelector(".mb a")?.textContent).toBe("Open in Dead to retry, edit or delete it");
  });

  test("respects the cancel permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ "jobs/j4": { jid: "j4", cancelled: false, progress: null, results: [{ where: "queue", queue: "q", job: job({ jid: "j4" }) }] } });
    const { container } = await renderPage(<P.m.JobLookup jid="j4" />);
    expect(container.querySelector(".page-head button")).toBeNull();
  });

  test("says when the job can't be found", async () => {
    mockApi({ "jobs/gone": { jid: "gone", cancelled: false, progress: null, results: [] } });
    const { container } = await renderPage(<P.m.JobLookup jid="gone" />);
    expect(container).toMatchSnapshot();
  });

  test("shows loading and errors", async () => {
    const api = mockApi({ "jobs/x": reply(500, { error: "Down" }) });
    const { container } = await renderPage(<P.m.JobLookup jid="x" />);
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes["jobs/x"] = { jid: "x", cancelled: false, progress: null, results: [] };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.querySelector("h1")?.textContent).toBe("Job not found");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    expect((await renderPage(<P.m.JobLookup jid="x" />)).container.querySelectorAll(".skeleton")).toHaveLength(8);
  });
});
