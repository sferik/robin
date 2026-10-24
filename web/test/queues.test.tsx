import { act, fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, job, mockApi, NOW, readOnlySession, reply, session, STATS } from "./helpers";
import { renderPage, settle } from "./render_page";

const Q = load(() => import("../src/pages/queues"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
  State.m.liveStore.set(null);
  State.m.toastStore.set([]);
  State.m.confirmStore.set(null);
});

async function answer(ok: boolean) {
  await settle();
  const req = State.m.confirmStore.get()!;
  const shown = [req.title, req.body, req.action, req.danger];
  req.resolve(ok);
  State.m.confirmStore.set(null);
  await settle();
  return shown;
}

const QUEUES = [
  { name: "default", size: 152, latency: 26, paused: false },
  { name: "mail ers", size: 1, latency: 119, paused: true },
];

describe("QueueList", () => {
  test("lists queues with live sizes", async () => {
    mockApi({ queues: { queues: QUEUES } });
    const { container } = await renderPage(<Q.m.QueueList />);
    expect(container).toMatchSnapshot();
    await act(() => {
      State.m.liveStore.set({ stats: STATS, queues: { default: 1000 }, at: 1 });
    });
    expect(container.querySelector(".subtitle")?.textContent).toBe("1,001 jobs waiting across 2 queues.");
    expect(container.querySelector("tbody td.r")?.textContent).toBe("1,000");
  });

  test("pauses after confirming and resumes right away", async () => {
    const api = mockApi({ queues: { queues: QUEUES }, "POST queues/default/pause": {}, "POST queues/mail%20ers/unpause": {} });
    await renderPage(<Q.m.QueueList />);
    fireEvent.click(screen.getByText("Pause"));
    expect(await answer(false)).toEqual([
      "Pause default?", "Processes stop taking jobs from this queue until you resume it. Jobs can still be pushed.", "Pause queue", undefined,
    ]);
    expect(api.to("queues/default/pause")).toHaveLength(0);
    fireEvent.click(screen.getByText("Pause"));
    await answer(true);
    expect(api.to("queues/default/pause", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Paused default");
    fireEvent.click(screen.getByText("Resume"));
    await settle();
    expect(State.m.confirmStore.get()).toBeNull();
    expect(api.to("queues/mail%20ers/unpause", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Resumed mail ers");
    expect(api.to("queues")).toHaveLength(4);
  });

  test("clears a queue after confirming", async () => {
    const api = mockApi({ queues: { queues: QUEUES }, "DELETE queues/mail%20ers": {} });
    await renderPage(<Q.m.QueueList />);
    fireEvent.click(screen.getAllByText("Clear")[1]);
    expect(await answer(false)).toEqual(["Delete every job in mail ers?", "1 job will be removed for good.", "Delete all jobs", true]);
    expect(api.to("queues")).toHaveLength(1);
    fireEvent.click(screen.getAllByText("Clear")[1]);
    await answer(true);
    expect(api.to("queues/mail%20ers", "DELETE")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Cleared mail ers");
    expect(api.to("queues")).toHaveLength(2);
  });

  test("hides controls without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ queues: { queues: QUEUES } });
    const { container } = await renderPage(<Q.m.QueueList />);
    expect(container.querySelectorAll("button")).toHaveLength(0);
  });

  test("shows empty, loading and error states", async () => {
    const api = mockApi({ queues: { queues: [] } });
    expect((await renderPage(<Q.m.QueueList />)).container).toMatchSnapshot();
    api.routes.queues = reply(500, { error: "Down" });
    const failed = await renderPage(<Q.m.QueueList />);
    expect(failed.container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes.queues = { queues: QUEUES };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(failed.container.querySelector("h1")?.textContent).toBe("Queues");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<Q.m.QueueList />);
    expect(loading.container.querySelector(".subtitle")).toBeNull();
    expect(loading.container.querySelector(".panel [aria-busy]")).not.toBeNull();
  });
});

const PAGE = {
  queue: { name: "default", size: 3, latency: 45, paused: false },
  page: 1, per_page: 2, total: 3,
  jobs: [
    job({ jid: "a1", tags: ["x"] }),
    job({ jid: "b2", encrypted: true, enqueued_at: null, created_at: NOW - 7_200_000, wrapper: "AJ::Wrapper" }),
  ],
};

describe("QueueDetail", () => {
  test("shows a page of jobs", async () => {
    const api = mockApi({ "queues/default": PAGE });
    const { container } = await renderPage(<Q.m.QueueDetail name="default" />);
    expect(container).toMatchSnapshot();
    expect(api.to("queues/default")[0]?.url.searchParams.get("page")).toBe("1");
  });

  test("reads the page from the address", async () => {
    R.m.navigate("/queues/default?page=3");
    const api = mockApi({ "queues/default": { ...PAGE, page: 3 } });
    await renderPage(<Q.m.QueueDetail name="default" />);
    R.m.navigate("/queues/default?page=nope", { replace: true });
    await settle();
    expect(api.calls.map((c) => c.url.searchParams.get("page"))).toEqual(["3", "1"]);
  });

  test("deletes selected jobs", async () => {
    const api = mockApi({ "queues/default": PAGE, "POST queues/default/delete_jobs": { deleted: 2 } });
    const { container } = await renderPage(<Q.m.QueueDetail name="default" />);
    const deleteButton = () => container.querySelector<HTMLButtonElement>(".bulkbar button")!;
    expect(deleteButton().disabled).toBe(true);
    expect(container.querySelector(".bulkbar .sel")?.textContent).toBe("Select jobs to act on them");
    fireEvent.click(screen.getByLabelText("Select a1"));
    expect(container.querySelector(".bulkbar .sel")?.textContent).toBe("1 job selected");
    expect(screen.getByLabelText<HTMLInputElement>("Select a1").checked).toBe(true);
    fireEvent.click(screen.getByLabelText("Select all on this page"));
    expect(screen.getByLabelText<HTMLInputElement>("Select all on this page").checked).toBe(true);
    expect(deleteButton().disabled).toBe(false);
    fireEvent.click(deleteButton());
    expect(await answer(false)).toEqual(["Delete 2 jobs?", "They won't run.", "Delete", true]);
    expect(container.querySelector(".bulkbar .sel")?.textContent).toBe("Select jobs to act on them");
    fireEvent.click(screen.getByLabelText("Select b2"));
    fireEvent.click(deleteButton());
    await answer(true);
    expect(api.to("queues/default/delete_jobs", "POST")[0]?.body).toEqual({ jids: ["b2"] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Deleted 2 jobs");
    expect(api.to("queues/default")).toHaveLength(3);
  });

  test("deletes every job of the selected class", async () => {
    const api = mockApi({
      "queues/default": { ...PAGE, jobs: [...PAGE.jobs, job({ jid: "c3", class: "Other" })] },
      "POST queues/default/delete_class": { deleted: 40 },
    });
    const { container } = await renderPage(<Q.m.QueueDetail name="default" />);
    const classButton = () => [...container.querySelectorAll<HTMLButtonElement>(".bulkbar button")].map((b) => b.textContent);
    expect(classButton()).toEqual(["Delete"]);
    fireEvent.click(screen.getByLabelText("Select a1"));
    fireEvent.click(screen.getByLabelText("Select b2"));
    expect(classButton()).toEqual(["Delete", "Delete every HardJob"]);
    fireEvent.click(screen.getByLabelText("Select c3"));
    expect(classButton()).toEqual(["Delete"]);
    fireEvent.click(screen.getByLabelText("Select a1"));
    fireEvent.click(screen.getByLabelText("Select b2"));
    fireEvent.click(screen.getByText("Delete every Other"));
    expect(await answer(false)).toEqual([
      "Delete every Other job in default?", "This takes every one in the queue, not only those on this page. They won't run.", "Delete all", true,
    ]);
    expect(api.to("queues/default/delete_class", "POST")).toHaveLength(0);
    expect(container.querySelector(".bulkbar .sel")?.textContent).toBe("Select jobs to act on them");
    fireEvent.click(screen.getByLabelText("Select c3"));
    fireEvent.click(screen.getByText("Delete every Other"));
    await answer(true);
    expect(api.to("queues/default/delete_class", "POST")[0]?.body).toEqual({ class: "Other" });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Deleted 40 jobs");
    expect(api.to("queues/default")).toHaveLength(3);
    api.routes["POST queues/default/delete_class"] = { deleted: 1 };
    fireEvent.click(screen.getByLabelText("Select c3"));
    fireEvent.click(screen.getByText("Delete every Other"));
    await answer(true);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Deleted 1 job");
  });

  test("words one job and several", async () => {
    mockApi({ "queues/default": { ...PAGE, queue: { ...PAGE.queue, size: 1 } }, "POST queues/default/delete_jobs": { deleted: 1 } });
    const { container } = await renderPage(<Q.m.QueueDetail name="default" />);
    expect(container.querySelector(".subtitle")?.textContent).toMatch(/^1 job waiting\. Oldest has waited /);
    fireEvent.click(screen.getByLabelText("Select all on this page"));
    expect(container.querySelector(".bulkbar .sel")?.textContent).toBe("2 jobs selected");
    fireEvent.click(screen.getByLabelText("Select a1"));
    fireEvent.click(container.querySelector<HTMLButtonElement>(".bulkbar button")!);
    expect((await answer(true))[0]).toBe("Delete 1 job?");
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Deleted 1 job");
    mockApi({ queues: { queues: [{ name: "only", size: 1, latency: 0, paused: false }] } });
    const list = await renderPage(<Q.m.QueueList />);
    expect(list.container.querySelector(".subtitle")?.textContent).toBe("1 job waiting across 1 queue.");
  });

  test("pauses, resumes and clears the queue", async () => {
    const api = mockApi({
      "queues/mail": { ...PAGE, queue: { ...PAGE.queue, name: "mail", paused: true } },
      "POST queues/mail/unpause": {},
      "DELETE queues/mail": {},
    });
    const { container } = await renderPage(<Q.m.QueueDetail name="mail" />);
    expect(container.querySelector(".subtitle")?.innerHTML).toContain('<span class="badge amber">Paused</span>');
    fireEvent.click(screen.getByText("Resume queue"));
    await settle();
    expect(api.to("queues/mail/unpause", "POST")).toHaveLength(1);
    fireEvent.click(screen.getByText("Clear queue"));
    expect(await answer(false)).toEqual(["Delete every job in mail?", "3 jobs will be removed for good.", "Delete all jobs", true]);
    expect(R.m.routeStore.get().path).toBe("/");
    fireEvent.click(screen.getByText("Clear queue"));
    await answer(true);
    expect(R.m.routeStore.get().path).toBe("/queues");
  });

  test("pauses a running queue", async () => {
    const api = mockApi({ "queues/default": PAGE, "POST queues/default/pause": {} });
    await renderPage(<Q.m.QueueDetail name="default" />);
    fireEvent.click(screen.getByText("Pause queue"));
    await answer(true);
    expect(api.to("queues/default/pause", "POST")).toHaveLength(1);
  });

  test("hides controls without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ "queues/default": PAGE });
    const { container } = await renderPage(<Q.m.QueueDetail name="default" />);
    expect(container.querySelectorAll("input")).toHaveLength(0);
    expect(container.querySelectorAll(".page-head button")).toHaveLength(0);
    expect(container.querySelector(".bulkbar")).toBeNull();
  });

  test("shows empty, loading and error states", async () => {
    const api = mockApi({ "queues/q": { ...PAGE, queue: { name: "q", size: 0, latency: 0, paused: false }, total: 0, jobs: [] } });
    const empty = await renderPage(<Q.m.QueueDetail name="q" />);
    expect(empty.container.querySelector(".bulkbar")).toBeNull();
    expect(empty.container.querySelector(".panel")).toMatchSnapshot();
    api.routes["queues/q"] = reply(500, { error: "Down" });
    const failed = await renderPage(<Q.m.QueueDetail name="q" />);
    expect(failed.container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes["queues/q"] = PAGE;
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(failed.container.querySelectorAll("tbody tr")).toHaveLength(2);
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    const loading = await renderPage(<Q.m.QueueDetail name="q" />);
    expect(loading.container.querySelector(".panel [aria-busy]")).not.toBeNull();
    expect(loading.container.querySelector(".page-head .btn-group")).toBeNull();
    expect(loading.container.querySelector(".pager")).toBeNull();
  });
});
