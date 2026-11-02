import { act, render } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";

const R = load(() => import("../src/router"));

beforeEach(() => {
  history.replaceState(null, "", "/robin/");
});

describe("href", () => {
  test("prefixes the mount path", () => {
    expect(R.m.href("/queues")).toBe("/robin/queues");
  });
});

describe("navigate", () => {
  test("pushes history, updates the route and scrolls to the top", () => {
    const scroll = vi.spyOn(window, "scrollTo");
    R.m.navigate("/queues/mail?page=2");
    expect(location.pathname).toBe("/robin/queues/mail");
    expect(R.m.routeStore.get().path).toBe("/queues/mail");
    expect(R.m.routeStore.get().query.get("page")).toBe("2");
    expect(history.length).toBeGreaterThan(1);
    expect(scroll).toHaveBeenCalledWith({ top: 0 });
  });

  test("replaces history without scrolling", () => {
    const scroll = vi.spyOn(window, "scrollTo");
    const before = history.length;
    R.m.navigate("/dead", { replace: true });
    expect(history.length).toBe(before);
    expect(R.m.routeStore.get().path).toBe("/dead");
    expect(scroll).not.toHaveBeenCalled();
  });

  test("treats the mount point itself as the root", () => {
    history.replaceState(null, "", "/robin");
    window.dispatchEvent(new PopStateEvent("popstate"));
    expect(R.m.routeStore.get().path).toBe("/");
    history.replaceState(null, "", "/elsewhere");
    window.dispatchEvent(new PopStateEvent("popstate"));
    expect(R.m.routeStore.get().path).toBe("/");
  });
});

describe("popstate", () => {
  test("syncs the route with the location", () => {
    history.replaceState(null, "", "/robin/retries?q=boom");
    window.dispatchEvent(new PopStateEvent("popstate"));
    expect(R.m.routeStore.get().path).toBe("/retries");
    expect(R.m.routeStore.get().query.get("q")).toBe("boom");
  });
});

describe("setQuery", () => {
  test("sets, replaces and removes parameters in place", () => {
    R.m.navigate("/retries?q=old&page=3");
    const before = history.length;
    R.m.setQuery({ q: "new", page: 4 });
    expect(location.search).toBe("?q=new&page=4");
    R.m.setQuery({ q: "", page: 1 });
    expect(location.search).toBe("");
    expect(location.pathname).toBe("/robin/retries");
    R.m.setQuery({ q: "x", page: undefined });
    expect(location.search).toBe("?q=x");
    R.m.setQuery({ size: 1 });
    expect(location.search).toBe("?q=x&size=1");
    expect(history.length).toBe(before);
    expect(R.m.routeStore.get().query.get("size")).toBe("1");
  });
});

describe("useRoute", () => {
  test("re-renders on navigation", async () => {
    function Where() {
      return <p>{R.m.useRoute().path}</p>;
    }
    const { container } = render(<Where />);
    await act(() => R.m.navigate("/busy"));
    expect(container.textContent).toBe("/busy");
  });
});

describe("match", () => {
  test("matches literal and parameter segments", () => {
    expect(R.m.match("/", "/")).toEqual({});
    expect(R.m.match("/busy", "/busy")).toEqual({});
    expect(R.m.match("/busy", "/busy/")).toEqual({});
    expect(R.m.match("/queues/:name", "/queues/mail%20ers")).toEqual({ name: "mail ers" });
    expect(R.m.match("/sets/:set/:id", "/sets/dead/1-abc")).toEqual({ set: "dead", id: "1-abc" });
  });

  test("rejects other paths", () => {
    expect(R.m.match("/", "/busy")).toBeNull();
    expect(R.m.match("/busy", "/")).toBeNull();
    expect(R.m.match("/queues/:name", "/queues")).toBeNull();
    expect(R.m.match("/queues/:name", "/queues/a/b")).toBeNull();
    expect(R.m.match("/queues/:name", "/dead/a")).toBeNull();
  });
});
