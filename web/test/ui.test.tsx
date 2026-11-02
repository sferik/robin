import { act, fireEvent, render, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { flush, NOW } from "./helpers";

const UI = load(() => import("../src/components/ui"));
const State = load(() => import("../src/state"));
const Icons = load(() => import("../src/components/icons"));

beforeEach(() => {
  history.replaceState(null, "", "/robin/");
  State.m.toastStore.set([]);
  State.m.confirmStore.set(null);
});

function frozen() {
  vi.useFakeTimers({ now: NOW, toFake: ["Date", "setInterval", "clearInterval"] });
}

describe("Icon", () => {
  test("is decorative unless titled", () => {
    const { container } = render(<Icons.m.Icon name="gem" />);
    expect(container).toMatchSnapshot();
    const titled = render(<Icons.m.Icon name="moon" title="Dark" width={15} />);
    expect(titled.container).toMatchSnapshot();
    expect(screen.getByRole("img", { name: "Dark" })).toBeTruthy();
  });
});

describe("useNow and Time", () => {
  test("shows a dash without a time", () => {
    const { container } = render(<UI.m.Time at={null} />);
    expect(container.innerHTML).toBe('<span class="dim">–</span>');
  });

  test("shows relative time and keeps it fresh", async () => {
    frozen();
    const { container, unmount } = render(<UI.m.Time at={NOW - 10_000} />);
    expect(container.innerHTML).toBe('<time datetime="2026-10-14T09:29:50.000Z" title="2026-10-14 09:29:50">10 seconds ago</time>');
    await act(() => {
      vi.advanceTimersByTime(14_999);
    });
    expect(container.textContent).toBe("10 seconds ago");
    await act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(container.textContent).toBe("25 seconds ago");
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  test("useNow restarts its timer when the period changes", async () => {
    frozen();
    function Clock({ every }: { every: number }) {
      return <p>{UI.m.useNow(every)}</p>;
    }
    const { container, rerender } = render(<Clock every={1} />);
    expect(container.textContent).toBe(String(NOW));
    rerender(<Clock every={60} />);
    await act(() => {
      vi.advanceTimersByTime(59_999);
    });
    expect(container.textContent).toBe(String(NOW));
    await act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(container.textContent).toBe(String(NOW + 60_000));
    expect(vi.getTimerCount()).toBe(1);
  });
});

describe("Jid", () => {
  test("shows a dash without an id", () => {
    expect(render(<UI.m.Jid jid={null} />).container.innerHTML).toBe('<span class="dim">–</span>');
  });

  test("copies the id", async () => {
    const writeText = vi.fn(() => Promise.resolve());
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const { container } = render(<UI.m.Jid jid="abc123" />);
    expect(container.innerHTML).toBe('<button type="button" class="jid" title="Copy job ID">abc123</button>');
    fireEvent.click(screen.getByRole("button"));
    await flush();
    expect(writeText).toHaveBeenCalledWith("abc123");
    expect(State.m.toastStore.get().map((t) => [t.message, t.kind])).toEqual([["Copied abc123", "ok"]]);
  });

  test("reports copy failures", async () => {
    vi.stubGlobal("navigator", { clipboard: { writeText: () => Promise.reject(new Error("denied")) } });
    render(<UI.m.Jid jid="abc123" />);
    fireEvent.click(screen.getByRole("button"));
    await flush();
    expect(State.m.toastStore.get().map((t) => [t.message, t.kind])).toEqual([["Couldn't copy to the clipboard", "error"]]);
  });

  test("explains when the clipboard isn't available", () => {
    vi.stubGlobal("navigator", {});
    render(<UI.m.Jid jid="abc123" />);
    fireEvent.click(screen.getByRole("button"));
    expect(State.m.toastStore.get().map((t) => [t.message, t.kind])).toEqual([["Copying needs HTTPS", "error"]]);
  });
});

describe("Latency", () => {
  test("labels slow queues in words", () => {
    const html = (s: number) => render(<UI.m.Latency seconds={s} />).container.innerHTML;
    expect(html(29.9)).toBe('<span class="lat-ok">30 s</span>');
    expect(html(30)).toBe('<span class="lat-warn" title="Jobs are waiting more than 30 seconds">30 s slow</span>');
    expect(html(299)).toBe('<span class="lat-warn" title="Jobs are waiting more than 30 seconds">4 m 59 s slow</span>');
    expect(html(300)).toBe('<span class="lat-bad" title="Jobs are waiting more than 5 minutes">5 m 0 s behind</span>');
  });
});

describe("Empty, Problem and Loading", () => {
  test("Empty", () => {
    expect(render(<UI.m.Empty title="Nothing here" />).container).toMatchSnapshot();
    expect(render(<UI.m.Empty title="No queues" icon="queues">Push a job.</UI.m.Empty>).container).toMatchSnapshot();
  });

  test("Problem", () => {
    expect(render(<UI.m.Problem message="Broken" />).container).toMatchSnapshot();
    const retry = vi.fn();
    const { container } = render(<UI.m.Problem message="Down" onRetry={retry} />);
    expect(container).toMatchSnapshot();
    fireEvent.click(screen.getByText("Try again"));
    expect(retry).toHaveBeenCalledTimes(1);
  });

  test("Loading", () => {
    expect(render(<UI.m.Loading />).container).toMatchSnapshot();
    expect(render(<UI.m.Loading rows={2} />).container.querySelectorAll(".skeleton")).toHaveLength(2);
  });
});

describe("Pager", () => {
  test("hides when everything fits on one page", () => {
    expect(render(<UI.m.Pager page={1} perPage={25} total={25} />).container.innerHTML).toBe("");
  });

  test("shows the range and moves between pages", () => {
    history.replaceState(null, "", "/robin/dead?page=2");
    const { container } = render(<UI.m.Pager page={2} perPage={25} total={1060} />);
    expect(container).toMatchSnapshot();
    fireEvent.click(screen.getByText("Next"));
    expect(location.search).toBe("?page=3");
    fireEvent.click(screen.getByText("Previous"));
    expect(location.search).toBe("");
  });

  test("disables buttons at the ends", () => {
    const first = render(<UI.m.Pager page={1} perPage={10} total={11} />);
    expect((first.getByText("Previous") as HTMLButtonElement).disabled).toBe(true);
    expect((first.getByText("Next") as HTMLButtonElement).disabled).toBe(false);
    expect(first.container.textContent).toContain("1–10 of 11");
    expect(first.container.textContent).toContain("Page 1 of 2");
    first.unmount();
    const last = render(<UI.m.Pager page={2} perPage={10} total={11} />);
    expect((last.getByText("Previous") as HTMLButtonElement).disabled).toBe(false);
    expect((last.getByText("Next") as HTMLButtonElement).disabled).toBe(true);
    expect(last.container.textContent).toContain("11–11 of 11");
  });

  test("copes with a page past the end", () => {
    const { container } = render(<UI.m.Pager page={3} perPage={10} total={0} />);
    expect(container.textContent).toContain("0–0 of 0");
    expect(container.textContent).toContain("Page 3 of 1");
  });
});

describe("SearchBox", () => {
  test("submits the trimmed query and follows its value", () => {
    const onSearch = vi.fn();
    const { container, rerender } = render(<UI.m.SearchBox value="old" placeholder="Search jobs" onSearch={onSearch} />);
    expect(container).toMatchSnapshot();
    const input = screen.getByRole("searchbox");
    fireEvent.input(input, { target: { value: "  boom  " } });
    expect(fireEvent.submit(screen.getByRole("search"))).toBe(false);
    expect(onSearch).toHaveBeenCalledWith("boom");
    rerender(<UI.m.SearchBox value="new" placeholder="Search jobs" onSearch={onSearch} />);
    expect((input as HTMLInputElement).value).toBe("new");
  });
});

describe("Tags and JobClass", () => {
  test("Tags", () => {
    expect(render(<UI.m.Tags />).container.innerHTML).toBe("");
    expect(render(<UI.m.Tags tags={[]} />).container.innerHTML).toBe("");
    expect(render(<UI.m.Tags tags={["a", "b"]} />).container.innerHTML).toBe('<span class="tag">a</span><span class="tag">b</span>');
  });

  test("JobClass links to metrics and names the wrapper", () => {
    expect(render(<UI.m.JobClass name="Billing::Charge" />).container.innerHTML).toBe(
      '<span class="cls"><a href="/robin/metrics/jobs/Billing%3A%3ACharge">Billing::Charge</a></span>',
    );
    expect(render(<UI.m.JobClass name="Mail" wrapper="ActiveJob::QueueAdapters::RobinAdapter::JobWrapper" />).container.innerHTML).toBe(
      '<span class="cls"><a href="/robin/metrics/jobs/Mail">Mail</a><span class="dim small" style="font-weight: 400;"> via JobWrapper</span></span>',
    );
  });
});

describe("JsonView", () => {
  test("pretty-prints JSON with highlighting", () => {
    const value = { a: 1, b: "x", c: [true, null, { d: [] }], e: {}, f: [[1, 2]] };
    const { container } = render(<UI.m.JsonView value={value} />);
    expect(container.textContent).toBe(JSON.stringify(value, null, 2));
    expect(container).toMatchSnapshot();
  });

  test("handles scalars and empty containers at the top", () => {
    const text = (v: unknown) => render(<UI.m.JsonView value={v} />).container.textContent;
    expect(text([])).toBe("[]");
    expect(text({})).toBe("{}");
    expect(text(false)).toBe("false");
    expect(text("s")).toBe('"s"');
  });
});

describe("Backtrace", () => {
  test("dims library frames", () => {
    const lines = ["app/jobs/x.rb:1", "/usr/lib/ruby/3.4/net.rb:2", "/gems/faraday/c.rb:3", "/rubygems/core.rb:4", "lib/ruby_things.rb:5"];
    const { container } = render(<UI.m.Backtrace lines={lines} />);
    expect([...container.querySelectorAll("div")].map((d) => d.className)).toEqual(["bt-app", "bt-lib", "bt-lib", "bt-lib", "bt-app"]);
    expect(container.querySelector("pre")?.className).toBe("code");
  });
});

describe("Toasts", () => {
  test("lists current toasts", async () => {
    const { container } = render(<UI.m.Toasts />);
    expect(container).toMatchSnapshot();
    await act(() => {
      State.m.toastStore.set([{ id: 1, message: "Saved", kind: "ok" }, { id: 2, message: "Failed", kind: "error" }]);
    });
    expect(container).toMatchSnapshot();
  });
});

describe("ConfirmDialog", () => {
  test("opens for a request and resolves with the answer", async () => {
    const { container } = render(<UI.m.ConfirmDialog />);
    const dialog = container.querySelector("dialog")!;
    expect(dialog.open).toBe(false);
    expect(container).toMatchSnapshot();

    const yes = State.m.confirmAction({ title: "Pause?", body: "It stops.", action: "Pause" });
    await act(flush);
    expect(dialog.open).toBe(true);
    expect(container).toMatchSnapshot();
    expect(screen.getByText("Pause").hasAttribute("autofocus")).toBe(true);
    expect(screen.getByText("Cancel").hasAttribute("autofocus")).toBe(false);
    expect(fireEvent.submit(container.querySelector("form")!)).toBe(false);
    await expect(yes).resolves.toBe(true);
    await act(flush);
    expect(State.m.confirmStore.get()).toBeNull();
    expect(dialog.open).toBe(false);
  });

  test("starts on Cancel for dangerous actions, and can be cancelled", async () => {
    const { container } = render(<UI.m.ConfirmDialog />);
    const no = State.m.confirmAction({ title: "Delete?", action: "Delete", danger: true });
    await act(flush);
    expect(container).toMatchSnapshot();
    expect(screen.getByText("Cancel").hasAttribute("autofocus")).toBe(true);
    expect(screen.getByText("Delete").hasAttribute("autofocus")).toBe(false);
    fireEvent.click(screen.getByText("Cancel"));
    await expect(no).resolves.toBe(false);

    const esc = State.m.confirmAction({ title: "Delete?", action: "Delete" });
    await act(flush);
    const cancel = new Event("cancel", { cancelable: true });
    container.querySelector("dialog")!.dispatchEvent(cancel);
    expect(cancel.defaultPrevented).toBe(true);
    await expect(esc).resolves.toBe(false);
  });

  test("doesn't reopen an open dialog or close a closed one", async () => {
    const { container } = render(<UI.m.ConfirmDialog />);
    const dialog = container.querySelector("dialog")!;
    const show = vi.spyOn(dialog, "showModal");
    const close = vi.spyOn(dialog, "close");
    void State.m.confirmAction({ title: "A", action: "Go" });
    await act(flush);
    await act(() => {
      State.m.confirmStore.set({ title: "B", action: "Go", resolve: () => undefined });
    });
    expect(show).toHaveBeenCalledTimes(1);
    await act(() => {
      State.m.confirmStore.set(null);
    });
    await act(() => {
      State.m.confirmStore.set(null);
    });
    expect(close).toHaveBeenCalledTimes(1);
  });
});
