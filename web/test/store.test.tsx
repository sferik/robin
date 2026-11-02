import { act, render } from "@testing-library/preact";
import { describe, expect, test, vi } from "vitest";
import { load } from "./load";

const S = load(() => import("../src/store"));

describe("createStore", () => {
  test("gets, sets and updates", () => {
    const store = S.m.createStore(1);
    expect(store.get()).toBe(1);
    store.set(2);
    expect(store.get()).toBe(2);
    store.update((v) => v * 10);
    expect(store.get()).toBe(20);
  });

  test("notifies subscribers until they unsubscribe", () => {
    const store = S.m.createStore("a");
    const a = vi.fn();
    const b = vi.fn();
    const stopA = store.subscribe(a);
    store.subscribe(b);
    store.set("b");
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
    stopA();
    store.update((v) => `${v}!`);
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(2);
  });
});

describe("useStore", () => {
  function Show({ store }: { store: { get(): string; subscribe(fn: () => void): () => void } }) {
    return <p>{S.m.useStore(store as never)}</p>;
  }

  test("re-renders when the store changes", async () => {
    const store = S.m.createStore("first");
    const { container } = render(<Show store={store} />);
    expect(container.textContent).toBe("first");
    await act(() => store.set("second"));
    expect(container.textContent).toBe("second");
  });

  test("follows a different store and stops listening on unmount", async () => {
    const a = S.m.createStore("a");
    const b = S.m.createStore("b");
    const { container, rerender, unmount } = render(<Show store={a} />);
    rerender(<Show store={b} />);
    expect(container.textContent).toBe("b");
    await act(() => b.set("b2"));
    expect(container.textContent).toBe("b2");
    const spy = vi.spyOn(b, "get");
    unmount();
    await act(() => b.set("b3"));
    expect(spy).not.toHaveBeenCalled();
  });
});
