import { fireEvent, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { freezeTime, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import { renderPage, settle } from "./render_page";

const B = load(() => import("../src/pages/batches"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
  State.m.toastStore.set([]);
  State.m.confirmStore.set(null);
});

const batch = (overrides: Record<string, unknown> = {}) => ({
  bid: "b-1", description: "Import users", total: 100, pending: 40, failures: 0, created_at: NOW - 600_000,
  complete_at: null, success_at: null, parent_bid: null, callbacks: {}, ...overrides,
});

const LIST = [
  batch(),
  batch({ bid: "b 2", description: null, pending: 0, success_at: NOW, complete_at: NOW }),
  batch({ bid: "b-3", description: "", pending: 5, failures: 2, complete_at: NOW }),
  batch({ bid: "b-4", pending: 10, failures: 3 }),
  batch({ bid: "b-5", total: 0, pending: 0 }),
  batch({ bid: "b-6", total: 10, pending: 4, failures: 9 }),
];

describe("BatchProgress", () => {
  test("splits done, failing and waiting", async () => {
    const html = async (b: ReturnType<typeof batch>) => (await renderPage(<B.m.BatchProgress b={b} />)).container.innerHTML;
    expect(await html(batch({ total: 10, pending: 4, failures: 1 }))).toBe(
      '<div><div class="progress" role="progressbar" aria-valuenow="60" aria-valuemin="0" aria-valuemax="100" aria-label="Batch progress">' +
        '<span class="p-ok" style="width: 60%;"></span><span class="p-fail" style="width: 10%;"></span></div>' +
        '<div class="progress-label"><span>6 of 10 done, 1 failing</span><span class="num">3 waiting</span></div></div>',
    );
    expect(await html(batch({ total: 3, pending: 3, failures: 0 }))).toBe(
      '<div><div class="progress" role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100" aria-label="Batch progress"></div>' +
        '<div class="progress-label"><span>0 of 3 done</span><span class="num">3 waiting</span></div></div>',
    );
    expect(await html(batch({ total: 3, pending: 2, failures: 5 }))).toContain("1 of 3 done, 2 failing</span><span class=\"num\"></span>");
    expect(await html(batch({ total: 3, pending: 0, failures: 0 }))).toContain('aria-valuenow="100"');
  });
});

describe("Batches", () => {
  test("lists batches with their state", async () => {
    mockApi({ batches: { available: true, batches: LIST } });
    const { container } = await renderPage(<B.m.Batches />);
    expect(container).toMatchSnapshot();
  });

  test("shows tags, and filters by one", async () => {
    const api = mockApi({ batches: { available: true, batches: [batch({ tags: ["nightly", "eu west"] }), batch({ bid: "b-2", tags: [] })] } });
    const { container } = await renderPage(<B.m.Batches />);
    const links = [...container.querySelectorAll("tbody a.tag")];
    expect(links.map((a) => [a.textContent, a.getAttribute("href")])).toEqual([
      ["nightly", "/robin/batches?tag=nightly"], ["eu west", "/robin/batches?tag=eu%20west"],
    ]);
    expect(container.querySelectorAll("tbody tr")[1].querySelector("td")!.children).toHaveLength(2);
    expect(api.to("batches")[0].url.searchParams.has("tag")).toBe(false);
    fireEvent.click(links[1]);
    await settle();
    expect(location.search).toBe("?tag=eu%20west");
    expect(api.to("batches").at(-1)!.url.searchParams.get("tag")).toBe("eu west");
    expect(container.querySelector(".subtitle")!.innerHTML).toBe('Batches tagged <span class="tag">eu west</span>. <a href="/robin/batches">Show all batches</a>');
    api.routes.batches = { available: true, batches: [] };
    R.m.navigate("/batches?tag=none");
    await settle();
    await settle();
    expect(container.querySelector(".empty")!.textContent).toContain("No batches have this tag");
    const tagIcon = container.querySelector(".empty svg")!.outerHTML;
    expect(container.querySelector(".empty p")!.textContent).toBe("Tagged batches show up here while Robin keeps them (30 days).");
    fireEvent.click(screen.getByText("Show all batches"));
    await settle();
    expect(location.search).toBe("");
    expect(container.textContent).toContain("No batches yet");
    expect(tagIcon).toBe(container.querySelector(".empty svg")!.outerHTML);
  });

  test("explains missing support, empty lists, loading and errors", async () => {
    const api = mockApi({ batches: { available: false } });
    expect((await renderPage(<B.m.Batches />)).container.textContent).toBe("BatchesGroups of jobs tracked together, with callbacks when they complete or succeed.Batches aren't available on this serverThis server's Robin version doesn't include batch support.");
    api.routes.batches = { available: true };
    expect((await renderPage(<B.m.Batches />)).container.querySelector(".empty")).toMatchSnapshot();
    api.routes.batches = reply(500, { error: "Down" });
    const failed = await renderPage(<B.m.Batches />);
    expect(failed.container.querySelector('[role="alert"]')?.textContent).toBe("DownTry again");
    api.routes.batches = { available: true, batches: [] };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(failed.container.textContent).toContain("No batches yet");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    expect((await renderPage(<B.m.Batches />)).container.querySelector(".panel [aria-busy]")).not.toBeNull();
  });
});

describe("BatchDetail", () => {
  const detail = batch({
    bid: "b/1", parent_bid: "p 1", failures: 2, complete_at: NOW - 1000,
    callbacks: { success: [["Notify", {}]] },
    failed_jobs: [{ jid: "f 1", error_class: "Boom", error_message: "It broke" }],
    children: ["c-1", { bid: "c-2", description: "Child", total: 4, pending: 1, failures: 0 }, { bid: "c-3", description: "", total: "?" }],
    jids: Array.from({ length: 60 }, (_, i) => `j${i}`),
  });

  test("shows progress, failures, children and details", async () => {
    mockApi({ "batches/b%2F1": { batch: detail } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b/1" />);
    expect(container).toMatchSnapshot();
    expect(container.querySelectorAll(".jid")).toHaveLength(50);
  });

  test("handles a plain batch", async () => {
    mockApi({ "batches/b-1": { batch: batch({ description: null, jids: [] }) } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b-1" />);
    expect(container).toMatchSnapshot();
  });

  test("lists a batch's tags with its details", async () => {
    mockApi({ "batches/b-1": { batch: batch({ tags: ["nightly"] }) } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b-1" />);
    const term = [...container.querySelectorAll("dt")].find((dt) => dt.textContent === "Tags")!;
    expect(term.nextElementSibling!.innerHTML).toBe('<a href="/robin/batches?tag=nightly" class="tag">nightly</a>');
    mockApi({ "batches/b-2": { batch: batch({ bid: "b-2", tags: [] }) } });
    const untagged = await renderPage(<B.m.BatchDetail bid="b-2" />);
    expect([...untagged.container.querySelectorAll("dt")].map((dt) => dt.textContent)).not.toContain("Tags");
  });

  test("counts a single job", async () => {
    mockApi({ "batches/b-1": { batch: batch({ total: 1, pending: 1 }) } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b-1" />);
    expect(container.querySelector(".kv dd")?.textContent).toBe("1 job");
  });

  test("deletes after confirming", async () => {
    const api = mockApi({ "batches/b-1": { batch: batch() }, "DELETE batches/b-1": { ok: true } });
    await renderPage(<B.m.BatchDetail bid="b-1" />);
    fireEvent.click(screen.getByText("Delete"));
    await settle();
    const req = State.m.confirmStore.get()!;
    expect([req.title, req.body, req.action, req.danger]).toEqual([
      "Delete this batch's tracking data?", "Jobs already pushed still run, but callbacks won't fire.", "Delete batch", true,
    ]);
    req.resolve(false);
    await settle();
    expect(R.m.routeStore.get().path).toBe("/");
    fireEvent.click(screen.getByText("Delete"));
    await settle();
    State.m.confirmStore.get()!.resolve(true);
    await settle();
    expect(api.to("batches/b-1", "DELETE")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Batch deleted");
    expect(R.m.routeStore.get().path).toBe("/batches");
  });

  test("cancels after confirming, while it's running", async () => {
    const api = mockApi({ "batches/b-1": { batch: batch({ complete_at: null }) }, "POST batches/b-1/cancel": { cancelled: ["b-1"] } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b-1" />);
    fireEvent.click(screen.getByText("Cancel batch"));
    await settle();
    const req = State.m.confirmStore.get()!;
    expect([req.title, req.body, req.action, req.danger]).toEqual([
      "Cancel this batch?",
      "Its jobs that haven't started are skipped, and running ones see cancelled? turn true. Child batches are cancelled too.",
      "Cancel batch", true,
    ]);
    req.resolve(true);
    await settle();
    expect(api.to("batches/b-1/cancel", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Batch cancelled");
    expect(api.to("batches/b-1")).toHaveLength(2); // reloaded
    expect(container.querySelector(".subtitle .badge")?.textContent).toBe("Running");
  });

  test("shows cancelled batches, without a cancel button", async () => {
    mockApi({ "batches/b-1": { batch: batch({ complete_at: null, cancelled_at: NOW - 5000 }) } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b-1" />);
    expect(container.querySelector(".subtitle .badge")?.textContent).toBe("Cancelled");
    expect(container.querySelector(".subtitle .badge")?.className).toBe("badge amber");
    expect(screen.queryByText("Cancel batch")).toBeNull();
    expect([...container.querySelectorAll(".kv dt")].map((d) => d.textContent)).toContain("Cancelled");
  });

  test("offers no cancelling for complete batches or without permission", async () => {
    mockApi({ "batches/b-1": { batch: batch({ complete_at: NOW }) } });
    await renderPage(<B.m.BatchDetail bid="b-1" />);
    expect(screen.queryByText("Cancel batch")).toBeNull();
    State.m.sessionStore.set(readOnlySession());
    mockApi({ "batches/b-2": { batch: batch({ bid: "b-2", complete_at: null }) } });
    await renderPage(<B.m.BatchDetail bid="b-2" />);
    expect(screen.queryByText("Cancel batch")).toBeNull();
  });

  test("stays put when deleting fails", async () => {
    mockApi({ "batches/b-1": { batch: batch() }, "DELETE batches/b-1": reply(500, { error: "No" }) });
    await renderPage(<B.m.BatchDetail bid="b-1" />);
    fireEvent.click(screen.getByText("Delete"));
    await settle();
    State.m.confirmStore.get()!.resolve(true);
    await settle();
    expect(R.m.routeStore.get().path).toBe("/");
  });

  test("hides delete without permission", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({ "batches/b-1": { batch: batch() } });
    const { container } = await renderPage(<B.m.BatchDetail bid="b-1" />);
    expect(container.querySelector("button")).toBeNull();
  });

  test("explains missing batches, loading and errors", async () => {
    const api = mockApi({ "batches/x": { available: false } });
    expect((await renderPage(<B.m.BatchDetail bid="x" />)).container.textContent).toBe("Batches aren't available on this serverThis server's Robin version doesn't include batch support.");
    api.routes["batches/x"] = reply(404, { error: "No such batch" });
    const failed = await renderPage(<B.m.BatchDetail bid="x" />);
    expect(failed.container.querySelector(".crumb")?.innerHTML).toBe('<a href="/robin/batches">Batches</a>');
    expect(failed.container.querySelector('[role="alert"]')?.textContent).toBe("No such batchTry again");
    api.routes["batches/x"] = { batch: batch({ bid: "x" }) };
    fireEvent.click(screen.getByText("Try again"));
    await settle();
    expect(failed.container.querySelector("h1")?.textContent).toBe("Import users");
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    expect((await renderPage(<B.m.BatchDetail bid="x" />)).container.querySelectorAll(".skeleton")).toHaveLength(8);
  });
});
