import { fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, job, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import { renderPage, settle } from "./render_page";

const S = load(() => import("../src/pages/sets"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  R.m.navigate("/", { replace: true });
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

const failed = (n: number, overrides: Record<string, unknown> = {}) =>
  job({
    jid: `j${n}`, id: `${n}00-j${n}`, at: NOW + n * 60_000, error_class: "Net::ReadTimeout", error_message: "x".repeat(150),
    failures: n, failed_at: NOW - 3_600_000, ...overrides,
  });

const page = (jobs: unknown[], extra: Record<string, unknown> = {}) => ({ page: 1, per_page: 25, total: jobs.length, query: "", jobs, ...extra });

describe("setMeta", () => {
  test("knows the three sets and nothing else", () => {
    expect(S.m.setMeta("dead")?.title).toBe("Dead");
    expect(S.m.setMeta("toString")).toBeUndefined();
    expect(S.m.setMeta("nope")).toBeUndefined();
  });
});

describe("SetPage", () => {
  test("lists retries with their errors", async () => {
    const api = mockApi({ "sets/retries": page([failed(1), failed(2, { encrypted: true, error_message: null, failures: null, tags: ["t"] })]) });
    const { container } = await renderPage(<S.m.SetPage set="retries" />);
    expect(container).toMatchSnapshot();
    expect([...api.to("sets/retries")[0].url.searchParams]).toEqual([["page", "1"]]);
  });

  test("lists scheduled jobs without error columns", async () => {
    mockApi({ "sets/scheduled": page([job({ jid: "s1", id: "1-s1", at: NOW + 5000 })]) });
    const { container } = await renderPage(<S.m.SetPage set="scheduled" />);
    expect(container).toMatchSnapshot();
  });

  test("searches and pages through the address bar", async () => {
    R.m.navigate("/dead?q=boom&page=2");
    const api = mockApi({ "sets/dead": page([failed(1)], { total: 30, page: 2, query: "boom" }) });
    const { container } = await renderPage(<S.m.SetPage set="dead" />);
    expect([...api.to("sets/dead")[0].url.searchParams]).toEqual([["page", "2"], ["q", "boom"]]);
    expect(container.querySelector(".subtitle")?.textContent).toBe("30 jobs matching “boom”.");
    expect(container.querySelector(".pager .num")?.textContent).toBe("26–30 of 30");
    expect(screen.getByRole<HTMLInputElement>("searchbox").value).toBe("boom");
    fireEvent.input(screen.getByRole("searchbox"), { target: { value: "bang" } });
    fireEvent.submit(screen.getByRole("search"));
    await settle();
    expect(location.search).toBe("?q=bang");
    R.m.navigate("/dead?page=x", { replace: true });
    await settle();
    expect(api.to("sets/dead").at(-1)?.url.searchParams.get("page")).toBe("1");
  });

  test("explains empty sets and empty searches", async () => {
    const api = mockApi({ "sets/dead": page([]), "sets/scheduled": page([]), "sets/retries": page([]) });
    expect((await renderPage(<S.m.SetPage set="dead" />)).container.querySelector(".panel")).toMatchSnapshot();
    expect((await renderPage(<S.m.SetPage set="scheduled" />)).container.querySelector(".panel")).toMatchSnapshot();
    expect((await renderPage(<S.m.SetPage set="retries" />)).container.querySelector(".panel")).toMatchSnapshot();
    R.m.navigate("/retries?q=zzz");
    api.routes["sets/retries"] = page([], { query: "zzz" });
    expect((await renderPage(<S.m.SetPage set="retries" />)).container.querySelector(".panel")).toMatchSnapshot();
  });

  test("acts on selected jobs", async () => {
    const api = mockApi({ "sets/retries": page([failed(1), failed(2)]), "POST sets/retries/bulk": { affected: 2 } });
    const { container } = await renderPage(<S.m.SetPage set="retries" />);
    const bar = () => container.querySelector(".bulkbar")!;
    expect(bar().querySelector(".sel")?.textContent).toBe("Select jobs, or act on the whole set");
    fireEvent.click(screen.getByLabelText("Select all on this page"));
    expect(bar().querySelector(".sel")?.textContent).toBe("2 jobs selected");
    expect([...bar().querySelectorAll("button")].map((b) => b.textContent)).toEqual(["Retry now", "Kill", "Delete"]);

    fireEvent.click(screen.getByText("Retry now"));
    expect(await answer(true)).toBeNull();
    expect(api.to("sets/retries/bulk", "POST").at(-1)?.body).toEqual({ action: "retry", ids: ["100-j1", "200-j2"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Retried 2 jobs");
    expect(bar().querySelector(".sel")?.textContent).toBe("Select jobs, or act on the whole set");

    fireEvent.click(screen.getByLabelText("Select j2"));
    fireEvent.click(screen.getByText("Kill"));
    expect(await answer(true)).toEqual(["Kill 1 job?", "They move to the dead set without running again.", "Kill", true]);
    expect(api.to("sets/retries/bulk", "POST").at(-1)?.body).toEqual({ action: "kill", ids: ["200-j2"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Killed 2 jobs");

    fireEvent.click(screen.getByLabelText("Select j1"));
    fireEvent.click(screen.getByText("Delete"));
    expect(await answer(false)).toEqual(["Delete 1 job?", "They won't run again.", "Delete", true]);
    expect(api.to("sets/retries/bulk", "POST")).toHaveLength(2);
    expect(api.to("sets/retries")).toHaveLength(4);
    fireEvent.click(screen.getByLabelText("Select j1"));
    fireEvent.click(screen.getByText("Delete"));
    await answer(true);
    expect(api.to("sets/retries/bulk", "POST").at(-1)?.body).toEqual({ action: "delete", ids: ["100-j1"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Deleted 2 jobs");
  });

  test("acts on the whole set", async () => {
    const api = mockApi({ "sets/retries": page([failed(1)], { total: 40 }), "POST sets/retries/all": { affected: 40 } });
    await renderPage(<S.m.SetPage set="retries" />);
    fireEvent.click(screen.getByText("Retry all"));
    expect(await answer(true)).toEqual(["Retry all 40 jobs?", "Every job in this set is pushed onto its queue right away.", "Retry all", false]);
    expect(api.to("sets/retries/all", "POST").at(-1)?.body).toEqual({ action: "retry" });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Retried 40 jobs");
    fireEvent.click(screen.getByText("Kill all"));
    expect(await answer(true)).toEqual(["Kill all 40 jobs?", "Every job in this set moves to the dead set.", "Kill all", true]);
    expect(api.to("sets/retries/all", "POST").at(-1)?.body).toEqual({ action: "kill" });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Killed 40 jobs");
    fireEvent.click(screen.getByText("Delete all"));
    expect(await answer(false)).toEqual(["Delete all 40 jobs?", "Every job in this set is removed for good.", "Delete all", true]);
    expect(api.to("sets/retries/all", "POST")).toHaveLength(2);
    expect(api.to("sets/retries")).toHaveLength(4);
  });

  test("enqueues scheduled jobs", async () => {
    const api = mockApi({ "sets/scheduled": page([job({ jid: "s1", id: "1-s1", at: NOW + 5000 })]), "POST sets/scheduled/all": { affected: 1 }, "POST sets/scheduled/bulk": { affected: 1 } });
    await renderPage(<S.m.SetPage set="scheduled" />);
    fireEvent.click(screen.getByText("Enqueue all"));
    expect((await answer(true))?.[0]).toBe("Enqueue all 1 job?");
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Enqueued 1 job");
    fireEvent.click(screen.getByLabelText("Select s1"));
    fireEvent.click(screen.getByText("Enqueue now"));
    await settle();
    expect(api.to("sets/scheduled/bulk", "POST")[0]?.body).toEqual({ action: "retry", ids: ["1-s1"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Enqueued 1 job");
  });

  test("words every action for one job and for several", async () => {
    for (const n of [1, 2]) {
      const jobs = n === 1 ? "1 job" : `${n} jobs`;
      const list = Array.from({ length: n }, (_, i) => failed(i + 1));
      mockApi({ "sets/retries": page(list), "POST sets/retries/bulk": { affected: n }, "POST sets/retries/all": { affected: n } });
      const { container, unmount } = await renderPage(<S.m.SetPage set="retries" />);
      const toast = () => State.m.toastStore.get().at(-1)?.message;
      const selectAll = () => fireEvent.click(screen.getByLabelText("Select all on this page"));
      selectAll();
      expect(container.querySelector(".bulkbar .sel")?.textContent).toBe(`${jobs} selected`);
      fireEvent.click(screen.getByText("Retry now"));
      await answer(true);
      expect(toast()).toBe(`Retried ${jobs}`);
      selectAll();
      fireEvent.click(screen.getByText("Kill"));
      expect((await answer(true))?.[0]).toBe(`Kill ${jobs}?`);
      expect(toast()).toBe(`Killed ${jobs}`);
      selectAll();
      fireEvent.click(screen.getByText("Delete"));
      expect((await answer(true))?.[0]).toBe(`Delete ${jobs}?`);
      expect(toast()).toBe(`Deleted ${jobs}`);
      for (const [button, verb, done] of [["Retry all", "Retry all", "Retried"], ["Kill all", "Kill all", "Killed"], ["Delete all", "Delete all", "Deleted"]]) {
        fireEvent.click(screen.getByText(button));
        expect((await answer(true))?.[0]).toBe(`${verb} ${jobs}?`);
        expect(toast()).toBe(`${done} ${jobs}`);
      }
      unmount();
      R.m.navigate("/retries?q=x", { replace: true });
      mockApi({ "sets/retries": page(list, { query: "x" }) });
      const search = await renderPage(<S.m.SetPage set="retries" />);
      expect(search.container.querySelector(".subtitle")?.textContent).toBe(`${jobs} matching “x”.`);
      search.unmount();
      R.m.navigate("/", { replace: true });
      const scheduled = Array.from({ length: n }, (_, i) => job({ jid: `s${i}`, id: `${i}-s${i}`, at: NOW + 5000 }));
      mockApi({ "sets/scheduled": page(scheduled), "POST sets/scheduled/all": { affected: n } });
      const later = await renderPage(<S.m.SetPage set="scheduled" />);
      fireEvent.click(screen.getByText("Enqueue all"));
      expect((await answer(true))?.[0]).toBe(`Enqueue all ${jobs}?`);
      expect(toast()).toBe(`Enqueued ${jobs}`);
      later.unmount();
    }
  });

  test("explains empty searches of every set", async () => {
    for (const [set, name] of [["scheduled", "scheduled"], ["dead", "dead"]] as const) {
      R.m.navigate(`/${set}?q=zzz`, { replace: true });
      mockApi({ [`sets/${set}`]: page([], { query: "zzz" }) });
      const { container, unmount } = await renderPage(<S.m.SetPage set={set} />);
      expect(container.querySelector(".empty p")?.textContent).toBe(`Nothing in ${name} contains “zzz”. Search matches anywhere in the job's JSON.`);
      unmount();
    }
  });

  test("never offers to kill dead jobs", async () => {
    mockApi({ "sets/dead": page([failed(1)]) });
    const { container } = await renderPage(<S.m.SetPage set="dead" />);
    expect([...container.querySelectorAll("th")].map((t) => t.textContent)).toEqual(["", "Died", "Job", "Arguments", "Error", "Failures"]);
    expect([...container.querySelectorAll(".bulkbar button")].map((b) => b.textContent)).toEqual(["Retry all", "Delete all"]);
    fireEvent.click(screen.getByLabelText("Select j1"));
    expect([...container.querySelectorAll(".bulkbar button")].map((b) => b.textContent)).toEqual(["Retry now", "Delete"]);
  });

  test("shows only permitted actions", async () => {
    State.m.sessionStore.set(readOnlySession());
    const api = mockApi({ "sets/retries": page([failed(1)]) });
    const { container } = await renderPage(<S.m.SetPage set="retries" />);
    expect(container.querySelector(".bulkbar")).toBeNull();
    expect(container.querySelector("input[type=checkbox]")).toBeNull();
    State.m.sessionStore.set(session({ permissions: { retry: false, delete: false, kill: true } as never }));
    const killer = await renderPage(<S.m.SetPage set="retries" />);
    expect([...killer.container.querySelectorAll(".bulkbar button")].map((b) => b.textContent)).toEqual(["Kill all"]);
    State.m.sessionStore.set(session({ permissions: { retry: true, delete: false, kill: false } as never }));
    const retrier = await renderPage(<S.m.SetPage set="retries" />);
    expect([...retrier.container.querySelectorAll(".bulkbar button")].map((b) => b.textContent)).toEqual(["Retry all"]);
    State.m.sessionStore.set(session({ permissions: { retry: false, delete: true, kill: false } as never }));
    const deleterList = await renderPage(<S.m.SetPage set="retries" />);
    expect([...deleterList.container.querySelectorAll(".bulkbar button")].map((b) => b.textContent)).toEqual(["Delete all"]);
    State.m.sessionStore.set(session({ permissions: { retry: false, delete: false, kill: true } as never }));
    api.routes["sets/dead"] = page([failed(1)]);
    const dead = await renderPage(<S.m.SetPage set="dead" />);
    expect(dead.container.querySelector(".bulkbar")).toBeNull();
  });

  test("shows loading and errors", async () => {
    const api = mockApi({ "sets/dead": reply(500, { error: "Down" }) });
    const { container } = await renderPage(<S.m.SetPage set="dead" />);
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes["sets/dead"] = page([]);
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(container.querySelector("h1")?.textContent).toBe("Dead");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<S.m.SetPage set="dead" />);
    expect(loading.container.querySelector(".subtitle")).toBeNull();
    expect(loading.container.querySelector(".panel [aria-busy]")).not.toBeNull();
    expect(loading.container.querySelector(".bulkbar, .pager")).toBeNull();
  });
});

describe("SetEntryPage", () => {
  const entry = failed(3, { id: "300-j3", payload: { class: "HardJob" }, backtrace: ["app/a.rb:1"] });

  test("shows the job with its error", async () => {
    mockApi({ "sets/retries/300-j3": { job: entry } });
    const { container } = await renderPage(<S.m.SetEntryPage set="retries" id="300-j3" />);
    expect(container).toMatchSnapshot();
  });

  test("hides encrypted arguments and the editor for them", async () => {
    mockApi({ "sets/dead/1": { job: { ...entry, encrypted: true } } });
    const { container } = await renderPage(<S.m.SetEntryPage set="dead" id="1" />);
    expect(container.textContent).toContain("These arguments are encrypted at rest and can't be shown.");
    expect(screen.queryByText("Edit arguments")).toBeNull();
    expect(screen.queryByText("Kill")).toBeNull();
  });

  test("retries, kills and deletes, then goes back to the set", async () => {
    const api = mockApi({ "sets/retries/300-j3": { job: entry }, "POST sets/retries/bulk": { affected: 1 } });
    await renderPage(<S.m.SetEntryPage set="retries" id="300-j3" />);
    fireEvent.click(screen.getByText("Retry now"));
    expect(await answer(true)).toBeNull();
    expect(api.to("sets/retries/bulk", "POST").at(-1)?.body).toEqual({ action: "retry", ids: ["300-j3"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Job retried");
    expect(R.m.routeStore.get().path).toBe("/retries");

    R.m.navigate("/", { replace: true });
    fireEvent.click(screen.getByText("Kill"));
    expect(await answer(false)).toEqual(["Kill job?", undefined, "Kill job", true]);
    expect(R.m.routeStore.get().path).toBe("/");
    fireEvent.click(screen.getByText("Kill"));
    await answer(true);
    expect(api.to("sets/retries/bulk", "POST").at(-1)?.body).toEqual({ action: "kill", ids: ["300-j3"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Job killed");

    R.m.navigate("/", { replace: true });
    fireEvent.click(screen.getByText("Delete"));
    expect(await answer(true)).toEqual(["Delete job?", undefined, "Delete job", true]);
    expect(api.to("sets/retries/bulk", "POST").at(-1)?.body).toEqual({ action: "delete", ids: ["300-j3"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Job deleted");
    expect(R.m.routeStore.get().path).toBe("/retries");
  });

  test("enqueues a scheduled job", async () => {
    mockApi({ "sets/scheduled/1-s1": { job: job({ jid: "s1", id: "1-s1", at: NOW + 5000 }) }, "POST sets/scheduled/bulk": { affected: 1 } });
    await renderPage(<S.m.SetEntryPage set="scheduled" id="1-s1" />);
    fireEvent.click(screen.getByText("Enqueue now"));
    await settle();
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Job enqueued");
  });

  test("opens and closes the argument editor", async () => {
    mockApi({ "sets/dead/1": { job: entry } });
    const { container } = await renderPage(<S.m.SetEntryPage set="dead" id="1" />);
    expect(container.querySelector("textarea")).toBeNull();
    fireEvent.click(screen.getByText("Edit arguments"));
    expect(container.querySelector("textarea")).not.toBeNull();
    fireEvent.click(screen.getByText("Cancel"));
    expect(container.querySelector("textarea")).toBeNull();
  });

  test("shows only permitted actions", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ "sets/retries/1": { job: entry }, "sets/scheduled/1": { job: entry } });
    const { container } = await renderPage(<S.m.SetEntryPage set="retries" id="1" />);
    expect(container.querySelectorAll(".page-head button:not(.jid)")).toHaveLength(0);
    State.m.sessionStore.set(session());
    const scheduled = await renderPage(<S.m.SetEntryPage set="scheduled" id="1" />);
    expect(scheduled.container.querySelector(".crumb")?.innerHTML).toBe('<a href="/robin/scheduled">Scheduled</a>');
    expect([...scheduled.container.querySelectorAll(".page-head .btn-group button")].map((b) => b.textContent)).toEqual(["Enqueue now", "Kill", "Delete"]);
  });

  test("stays put when an action fails", async () => {
    mockApi({ "sets/retries/1": { job: entry }, "POST sets/retries/bulk": reply(409, { error: "Already gone" }) });
    await renderPage(<S.m.SetEntryPage set="retries" id="1" />);
    fireEvent.click(screen.getByText("Retry now"));
    await settle();
    expect(R.m.routeStore.get().path).toBe("/");
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Already gone");
  });

  test("handles unknown sets, loading and errors", async () => {
    mockApi({ "sets/dead/1": reply(404, { error: "That job is gone" }) });
    expect((await renderPage(<S.m.SetEntryPage set="bogus" id="1" />)).container.textContent).toBe('There\'s no "bogus" set.');
    const failedPage = await renderPage(<S.m.SetEntryPage set="dead" id="1" />);
    expect(failedPage.container.innerHTML).toMatchSnapshot();
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    expect((await renderPage(<S.m.SetEntryPage set="dead" id="1" />)).container.querySelectorAll(".skeleton")).toHaveLength(10);
  });
});
