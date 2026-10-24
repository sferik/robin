import { describe, expect, test } from "vitest";
import { load } from "./load";
import { flush, mockApi, reply } from "./helpers";

const Act = load(() => import("../src/actions"));
const State = load(() => import("../src/state"));

function lastToast() {
  return State.m.toastStore.get().at(-1);
}

describe("act", () => {
  test("runs and toasts a fixed message", async () => {
    await expect(Act.m.act(() => Promise.resolve(5), "Done")).resolves.toBe(5);
    expect(lastToast()).toMatchObject({ message: "Done", kind: "ok" });
  });

  test("builds the message from the result", async () => {
    await Act.m.act(() => Promise.resolve({ n: 3 }), (r) => `Got ${r.n}`);
    expect(lastToast()?.message).toBe("Got 3");
  });

  test("toasts failures and resolves to undefined", async () => {
    await expect(Act.m.act(() => Promise.reject(new Error("Nope")), "Done")).resolves.toBeUndefined();
    expect(lastToast()).toMatchObject({ message: "Nope", kind: "error" });
  });

  test("asks first when a confirmation is given", async () => {
    let ran = 0;
    const confirm = { title: "Sure?", action: "Go" };
    const declined = Act.m.act(() => Promise.resolve(++ran), "Done", confirm);
    await flush(1);
    expect(State.m.confirmStore.get()).toMatchObject(confirm);
    State.m.confirmStore.get()!.resolve(false);
    await expect(declined).resolves.toBeUndefined();
    expect(ran).toBe(0);

    const accepted = Act.m.act(() => Promise.resolve(++ran), "Done", confirm);
    await flush(1);
    State.m.confirmStore.get()!.resolve(true);
    await expect(accepted).resolves.toBe(1);
  });
});

describe("post and del", () => {
  test("send mutations", async () => {
    const api = mockApi({ "POST a": { posted: true }, "DELETE b": { deleted: true }, "POST bad": reply(422, { error: "Bad" }) });
    await expect(Act.m.post("a", { x: 1 })).resolves.toEqual({ posted: true });
    await expect(Act.m.del("b", { y: 2 })).resolves.toEqual({ deleted: true });
    await expect(Act.m.post("bad")).rejects.toThrow("Bad");
    expect(api.calls.map((c) => [c.method, c.path, c.body])).toEqual([["POST", "a", { x: 1 }], ["DELETE", "b", { y: 2 }], ["POST", "bad", undefined]]);
  });
});
