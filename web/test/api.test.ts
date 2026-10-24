import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { mockApi, reply } from "./helpers";

const A = load(() => import("../src/api"));

beforeEach(() => {
  A.m.clusterStore.set("");
});

describe("clusters", () => {
  test("starts with the cluster remembered in localStorage", async () => {
    localStorage.setItem("robin.cluster", "eu");
    vi.resetModules();
    const fresh = await import("../src/api");
    expect(fresh.clusterStore.get()).toBe("eu");
  });

  test("defaults to no cluster", async () => {
    vi.resetModules();
    const fresh = await import("../src/api");
    expect(fresh.clusterStore.get()).toBe("");
  });

  test("setCluster remembers the choice", () => {
    A.m.setCluster("us");
    expect(A.m.clusterStore.get()).toBe("us");
    expect(localStorage.getItem("robin.cluster")).toBe("us");
  });
});

describe("apiUrl", () => {
  test("adds non-empty params and the cluster", () => {
    expect(A.m.apiUrl("stats")).toBe("api/stats");
    expect(A.m.apiUrl("sets/dead", { page: 2, q: "", x: undefined, n: 0 })).toBe("api/sets/dead?page=2&n=0");
    A.m.setCluster("eu");
    expect(A.m.apiUrl("stats")).toBe("api/stats?cluster=eu");
    expect(A.m.apiUrl("queues", { page: 1 })).toBe("api/queues?page=1&cluster=eu");
  });
});

describe("get", () => {
  test("fetches JSON from the API", async () => {
    const api = mockApi({ stats: { processed: 1 } });
    await expect(A.m.get("stats", { a: 1 })).resolves.toEqual({ processed: 1 });
    expect(api.fetch).toHaveBeenCalledWith("api/stats?a=1", { headers: { accept: "application/json" }, credentials: "same-origin" });
  });

  test("treats an empty body as an empty object", async () => {
    mockApi({ empty: () => new Response("", { status: 200 }) });
    await expect(A.m.get("empty")).resolves.toEqual({});
  });

  test("reports server errors", async () => {
    mockApi({ nope: reply(403, { error: "Not allowed" }), bare: reply(500, {}) });
    await expect(A.m.get("nope")).rejects.toMatchObject({ status: 403, message: "Not allowed" });
    await expect(A.m.get("bare")).rejects.toMatchObject({ status: 500, message: "Request failed (500)." });
    const err = await A.m.get("nope").catch((e: unknown) => e);
    expect(err).toBeInstanceOf(A.m.ApiError);
    expect(err).toBeInstanceOf(Error);
  });

  test("reports responses that aren't JSON", async () => {
    mockApi({ html: reply(502, "<html>Bad gateway</html>") });
    await expect(A.m.get("html")).rejects.toMatchObject({ status: 502, message: "The server sent an unexpected response (502)." });
  });
});

describe("send", () => {
  test("posts JSON with the CSRF header", async () => {
    const api = mockApi({ "POST queues/a/pause": { ok: true } });
    await expect(A.m.send("POST", "queues/a/pause", { x: 1 })).resolves.toEqual({ ok: true });
    expect(api.fetch).toHaveBeenCalledWith("api/queues/a/pause", {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json", accept: "application/json", "x-robin-request": "1" },
      body: '{"x":1}',
    });
  });

  test("sends no body when there is none", async () => {
    const api = mockApi({ "DELETE queues/a": {} });
    await A.m.send("DELETE", "queues/a");
    expect(api.fetch.mock.calls[0][1]).toMatchObject({ method: "DELETE", body: undefined });
  });

  test("rejects on errors", async () => {
    mockApi();
    await expect(A.m.send("POST", "missing")).rejects.toMatchObject({ status: 404 });
  });
});

describe("enc", () => {
  test("encodes path segments", () => {
    expect(A.m.enc("a b/c")).toBe("a%20b%2Fc");
  });
});
