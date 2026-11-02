import { fireEvent, render, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";

const L = load(() => import("../src/components/link"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  history.replaceState(null, "", "/robin/");
  R.m.routeStore.set({ path: "/", query: new URLSearchParams() });
});

describe("Link", () => {
  test("renders a real link under the mount path", () => {
    const { container } = render(<L.m.Link href="/queues" class="small" aria-current="page">Queues</L.m.Link>);
    expect(container.innerHTML).toBe('<a href="/robin/queues" class="small" aria-current="page">Queues</a>');
  });

  test("navigates in place on a plain click, after the caller's handler", () => {
    const seen: string[] = [];
    const onClick = vi.fn(() => seen.push(R.m.routeStore.get().path));
    render(<L.m.Link href="/busy" onClick={onClick}>Busy</L.m.Link>);
    const notPrevented = fireEvent.click(screen.getByText("Busy"));
    expect(notPrevented).toBe(false);
    expect(onClick).toHaveBeenCalledTimes(1);
    expect(seen).toEqual(["/"]);
    expect(R.m.routeStore.get().path).toBe("/busy");
    expect(location.pathname).toBe("/robin/busy");
  });

  test("leaves modified and non-primary clicks to the browser", () => {
    render(<L.m.Link href="/busy">Busy</L.m.Link>);
    const link = screen.getByText("Busy");
    for (const init of [{ metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }]) {
      expect(fireEvent.click(link, init)).toBe(true);
    }
    expect(R.m.routeStore.get().path).toBe("/");
  });

  test("respects a handler that cancels navigation", () => {
    render(<L.m.Link href="/busy" onClick={(e) => e.preventDefault()}>Busy</L.m.Link>);
    fireEvent.click(screen.getByText("Busy"));
    expect(R.m.routeStore.get().path).toBe("/");
  });
});
