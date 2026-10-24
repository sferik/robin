import { act, fireEvent, render, screen } from "@testing-library/preact";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { flush, freezeTime, job, mockApi, NOW, readOnlySession, reply, session } from "./helpers";
import type { Job } from "../src/api";

const J = load(() => import("../src/components/job_detail"));
const State = load(() => import("../src/state"));
const R = load(() => import("../src/router"));

beforeEach(() => {
  freezeTime();
  R.m.navigate("/", { replace: true });
  State.m.sessionStore.set(session());
  State.m.toastStore.set([]);
  State.m.confirmStore.set(null);
});

const asJob = (overrides: Record<string, unknown> = {}) => job(overrides) as unknown as Job;

describe("JobProgress", () => {
  const shown = (progress: Record<string, unknown>) => {
    const { container } = render(<J.m.JobProgress progress={{ at: NOW, ...progress } as never} />);
    return container.innerHTML;
  };

  test("shows a bar, the message and the percentage", () => {
    expect(shown({ pct: 42.5, msg: "Row 425" })).toBe(
      '<div class="progress" role="progressbar" aria-valuenow="42.5" aria-valuemin="0" aria-valuemax="100"><span class="p-ok" style="width: 42.5%;"></span></div>' +
        '<div class="progress-label"><span>Row 425</span><span class="num">42.5%</span></div>',
    );
    expect(shown({ pct: 100, msg: null })).toContain('<span></span><span class="num">100%</span>');
  });

  test("shows a moving bar and the count of iterations when the percentage is unknown", () => {
    expect(shown({ pct: null, meta: { iterations: 12_340 } })).toBe(
      '<div class="progress progress-unknown" role="progressbar" aria-valuemin="0" aria-valuemax="100"><span class="p-run"></span></div>' +
        '<div class="progress-label"><span>12,340 done</span><span class="num"></span></div>',
    );
    expect(shown({ pct: null, meta: { iterations: 0 } })).toContain("<span>0 done</span>");
  });

  test("prefers the job's own message, and shows nothing without either", () => {
    expect(shown({ pct: null, msg: "Importing", meta: { iterations: 3 } })).toContain("<span>Importing</span>");
    expect(shown({ pct: null, meta: { other: 1 } })).toContain('<div class="progress-label"><span></span><span class="num"></span></div>');
    expect(shown({ pct: null, meta: { iterations: "3" } })).toContain("<span></span>");
  });
});

describe("JobFacts", () => {
  test("lists the basics", () => {
    expect(render(<J.m.JobFacts job={asJob()} />).container).toMatchSnapshot();
  });

  test("lists everything a failed job in a batch has", () => {
    const failed = asJob({
      at: NOW + 60_000, failures: 3, failed_at: NOW - 3_600_000, retried_at: NOW - 60_000, bid: "b1",
      tags: ["billing", "eu"], wrapper: "ActiveJob::Wrapper", queue: "mail ers",
    });
    expect(render(<J.m.JobFacts job={failed} where="Retries" when="Next retry" />).container).toMatchSnapshot();
  });

  test("adds the server's job_info rows, as links when they have one", () => {
    const job = asJob({ info: [{ label: "Customer", text: "#7", href: "/admin/customers/7" }, { label: "Plan", text: "Gold" }] });
    const { container } = render(<J.m.JobFacts job={job} />);
    const terms = [...container.querySelectorAll("dt")].slice(-2).map((dt) => [dt.textContent, dt.nextElementSibling!.innerHTML]);
    expect(terms).toEqual([
      ["Customer", '<a href="/admin/customers/7" rel="noopener noreferrer">#7</a>'],
      ["Plan", "Gold"],
    ]);
  });

  test("labels the time as asked, or as when it runs", () => {
    const at = asJob({ at: NOW - 5000, enqueued_at: null });
    const term = (where?: string, when?: string) => render(<J.m.JobFacts job={at} where={where} when={when} />).container.querySelectorAll("dt")[where ? 4 : 3].textContent;
    expect(term("Retries", "Next retry")).toBe("Next retry");
    expect(term("Scheduled")).toBe("Runs");
    expect(term()).toBe("Runs");
  });

  test("leaves out zero failures", () => {
    const { container } = render(<J.m.JobFacts job={asJob({ failures: 0 })} />);
    expect(container.textContent).not.toContain("Failures");
  });
});

describe("JobError", () => {
  test("renders nothing for a job that didn't fail", () => {
    expect(render(<J.m.JobError job={asJob()} />).container.innerHTML).toBe("");
  });

  test("shows the error and backtrace", () => {
    const failed = asJob({ error_class: "Boom", error_message: "It broke", backtrace: ["app/x.rb:1", "/gems/y.rb:2"] });
    expect(render(<J.m.JobError job={failed} />).container).toMatchSnapshot();
  });

  test("leaves out an empty or missing backtrace", () => {
    expect(render(<J.m.JobError job={asJob({ error_class: "Boom", error_message: "m", backtrace: [] })} />).container.textContent).toBe("Boomm");
    expect(render(<J.m.JobError job={asJob({ error_class: "Boom", error_message: "m", backtrace: null })} />).container.textContent).toBe("Boomm");
  });
});

describe("Payload", () => {
  test("shows the raw payload when there is one", () => {
    expect(render(<J.m.Payload job={asJob()} />).container.innerHTML).toBe("");
    expect(render(<J.m.Payload job={asJob({ payload: { class: "HardJob" } })} />).container).toMatchSnapshot();
  });
});

describe("EditArgs", () => {
  const dead = asJob({ id: "100-abc", args: [1, { a: "b" }] });

  test("starts from the current arguments", () => {
    const { container } = render(<J.m.EditArgs set="dead" job={dead} onDone={() => undefined} />);
    expect(container).toMatchSnapshot();
    expect(screen.getByRole<HTMLTextAreaElement>("textbox").value).toBe(JSON.stringify([1, { a: "b" }], null, 2));
  });

  /** The message JSON.parse gives for `text`. */
  const parseError = (text: string): string => {
    try {
      JSON.parse(text);
    } catch (e) {
      return (e as Error).message;
    }
    return "";
  };

  test("rejects invalid JSON and non-arrays", async () => {
    const api = mockApi();
    render(<J.m.EditArgs set="dead" job={dead} onDone={() => undefined} />);
    const box = screen.getByRole("textbox");
    fireEvent.input(box, { target: { value: "[1," } });
    fireEvent.click(screen.getByText("Retry with these arguments"));
    await act(flush);
    expect(screen.getByRole("alert").textContent).toBe(`That isn't valid JSON: ${parseError("[1,")}`);
    fireEvent.input(box, { target: { value: '{"a": 1}' } });
    fireEvent.click(screen.getByText("Retry with these arguments"));
    await act(flush);
    expect(screen.getByRole("alert").textContent).toBe('Arguments must be a JSON array, like [1, "two"].');
    expect(api.calls).toHaveLength(0);
  });

  test("retries with the new arguments and opens the new job", async () => {
    const api = mockApi({ "POST sets/dead/100-abc/edit": { jid: "new jid" } });
    const onDone = vi.fn();
    render(<J.m.EditArgs set="dead" job={asJob({ id: "100-abc" })} onDone={onDone} />);
    fireEvent.input(screen.getByRole("textbox"), { target: { value: "[2" } });
    fireEvent.click(screen.getByText("Retry with these arguments"));
    await act(flush);
    fireEvent.input(screen.getByRole("textbox"), { target: { value: "[2, 3]" } });
    fireEvent.click(screen.getByText("Retry with these arguments"));
    await act(flush);
    expect(screen.queryByRole("alert")).toBeNull();
    expect(api.to("sets/dead/100-abc/edit", "POST")[0]?.body).toEqual({ args: [2, 3] });
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Enqueued with new arguments as new jid");
    expect(onDone).toHaveBeenCalledTimes(1);
    expect(R.m.routeStore.get().path).toBe("/jobs/new%20jid");
  });

  test("encodes the entry id", async () => {
    const api = mockApi({ "POST sets/retries/1%2F2/edit": { jid: "j" } });
    render(<J.m.EditArgs set="retries" job={asJob({ id: "1/2" })} onDone={() => undefined} />);
    fireEvent.click(screen.getByText("Retry with these arguments"));
    await act(flush);
    expect(api.calls.map((c) => c.path)).toEqual(["sets/retries/1%2F2/edit"]);
  });

  test("stays open when the retry fails", async () => {
    mockApi({ "POST sets/dead/100-abc/edit": reply(409, { error: "Gone" }) });
    const onDone = vi.fn();
    render(<J.m.EditArgs set="dead" job={dead} onDone={onDone} />);
    fireEvent.click(screen.getByText("Retry with these arguments"));
    await act(flush);
    expect(onDone).not.toHaveBeenCalled();
    expect(R.m.routeStore.get().path).toBe("/");
    expect(State.m.toastStore.get().at(-1)).toMatchObject({ message: "Gone", kind: "error" });
  });

  test("can be cancelled", () => {
    const onDone = vi.fn();
    render(<J.m.EditArgs set="dead" job={dead} onDone={onDone} />);
    fireEvent.click(screen.getByText("Cancel"));
    expect(onDone).toHaveBeenCalledTimes(1);
  });
});

describe("CancelButton", () => {
  test("needs the cancel permission", () => {
    State.m.sessionStore.set(readOnlySession());
    expect(render(<J.m.CancelButton jid="x" />).container.innerHTML).toBe("");
  });

  test("asks, then requests cancellation", async () => {
    const api = mockApi({ "POST jobs/a%20b/cancel": { ok: true } });
    const { container } = render(<J.m.CancelButton jid="a b" />);
    expect(container.innerHTML).toBe('<button class="btn">Cancel job</button>');
    fireEvent.click(screen.getByText("Cancel job"));
    await act(flush);
    expect(State.m.confirmStore.get()).toMatchObject({
      title: "Cancel this job?",
      body: "If it hasn't started, it's skipped. If it's running, cancelled? turns true so it can stop early.",
      action: "Cancel job",
      danger: true,
    });
    State.m.confirmStore.get()!.resolve(true);
    await act(flush);
    expect(api.to("jobs/a%20b/cancel", "POST")).toHaveLength(1);
    expect(State.m.toastStore.get().at(-1)?.message).toBe("Cancellation requested");
  });
});
