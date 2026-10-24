// @vitest-environment-options {"happyDOM": {"url": "http://localhost/"}}
import { describe, expect, test } from "vitest";
import { load } from "./load";

const R = load(() => import("../src/router"));

describe("mounted at the site root", () => {
  test("uses paths as they are", () => {
    expect(R.m.href("/queues")).toBe("/queues");
    expect(R.m.routeStore.get().path).toBe("/");
    R.m.navigate("/dead");
    expect(location.pathname).toBe("/dead");
    expect(R.m.routeStore.get().path).toBe("/dead");
  });
});
