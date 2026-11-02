import { act } from "@testing-library/preact";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { flush, reply, session } from "./helpers";

/** Preact runs effects on the next animation frame. */
const frame = async () => {
  await flush();
  await new Promise((r) => setTimeout(r, 40));
  await flush();
};

let app: HTMLElement;
let calls: string[];

function api(sessionReply: () => Response) {
  calls = [];
  vi.stubGlobal("fetch", vi.fn((input: string) => {
    const path = new URL(input, "http://localhost/robin/").pathname.replace("/robin/api/", "");
    calls.push(path);
    return path === "session" ? Promise.resolve(sessionReply()) : new Promise(() => undefined);
  }));
}

async function boot() {
  vi.resetModules();
  await act(async () => {
    await import("../src/main");
    // The first render waits for the language to load, which sets <html lang>.
    await vi.waitFor(() => {
      expect(document.documentElement.lang).not.toBe("");
    });
    await frame();
  });
  // Effects scheduled while the first act flushed run in the next one.
  await act(frame);
  return import("../src/router");
}

// index.html sets <base href> to the mount path; relative API URLs rely on it.
const base = document.createElement("base");
base.href = "/robin/";
document.head.append(base);

beforeEach(() => {
  history.replaceState(null, "", "/robin/");
  document.title = "";
  document.documentElement.lang = "";
  delete document.documentElement.dataset.theme;
  app = document.createElement("div");
  app.id = "app";
  document.body.append(app);
});

afterEach(() => {
  render(null, app);
  app.remove();
});

describe("the app", () => {
  test("loads the session, starts live updates and shows the dashboard", async () => {
    api(() => reply(200, session()));
    await boot();
    expect(calls).toEqual(["session", "stats", "dashboard"]);
    expect(localStorage.getItem("robin.locale")).toBeNull(); // only a choice made under Settings is remembered
    expect(document.title).toBe("Dashboard | Robin");
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(app.querySelector(".shell")).not.toBeNull();
    expect(app.querySelector(".toasts")).not.toBeNull();
    expect(app.querySelector("dialog.confirm")).not.toBeNull();
  });

  test("starts in the saved language and re-renders in a new one", async () => {
    localStorage.setItem("robin.locale", "ar");
    api(() => reply(200, session()));
    await boot();
    expect([document.documentElement.lang, document.documentElement.dir]).toEqual(["ar", "rtl"]);
    const i18n = await import("../src/i18n");
    expect(i18n.locale()).toBe("ar");
    await act(async () => {
      i18n.localeStore.set({ code: "de", catalogue: { Dashboard: "Übersicht", Busy: "Beschäftigt" } });
      await frame();
    });
    expect(document.title).toBe("Übersicht | Robin");
    expect(app.querySelector(".nav")?.textContent).toContain("Beschäftigt");
    await i18n.setLocale("en", false);
  });

  test("renders nothing until the session arrives", async () => {
    api(() => reply(200, session()));
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    await boot();
    expect(app.innerHTML).toBe("");
    expect(document.title).toBe("Dashboard | Robin");
  });

  test("routes every page", async () => {
    api(() => reply(200, session({ title: "Acme", extensions: [{ slug: "billing desk", title: "Billing" }] })));
    const router = await boot();
    const visit = async (path: string) => {
      calls.length = 0;
      await act(async () => {
        router.navigate(path);
        await frame();
      });
      await act(frame);
      return [calls.filter((c) => c !== "stats").join(","), document.title];
    };
    expect(await visit("/busy")).toEqual(["busy", "Busy | Acme"]);
    expect(await visit("/queues")).toEqual(["queues", "Queues | Acme"]);
    expect(await visit("/queues/mail%20x")).toEqual(["queues/mail%20x", "Queues | Acme"]);
    expect(await visit("/scheduled")).toEqual(["sets/scheduled", "Scheduled | Acme"]);
    expect(await visit("/retries")).toEqual(["sets/retries", "Retries | Acme"]);
    expect(await visit("/dead")).toEqual(["sets/dead", "Dead | Acme"]);
    expect(await visit("/sets/dead/1-a")).toEqual(["sets/dead/1-a", "Acme"]);
    expect(await visit("/jobs/j%201")).toEqual(["jobs/j%201", "Acme"]);
    expect(await visit("/metrics")).toEqual(["metrics/queues,metrics", "Metrics | Acme"]);
    expect(await visit("/metrics/jobs/Billing%3A%3ACharge")).toEqual(["metrics/jobs/Billing%3A%3ACharge", "Metrics | Acme"]);
    expect(await visit("/batches")).toEqual(["batches", "Batches | Acme"]);
    expect(await visit("/batches/b%201")).toEqual(["batches/b%201", "Batches | Acme"]);
    expect(await visit("/limiters")).toEqual(["limiters", "Rate limits | Acme"]);
    expect(await visit("/cron")).toEqual(["cron", "Cron | Acme"]);
    expect(await visit("/cron/c%201")).toEqual(["cron/c%201", "Cron | Acme"]);
    expect(await visit("/profiles")).toEqual(["profiles", "Profiles | Acme"]);
    expect(await visit("/ext/billing%20desk")).toEqual(["extensions/billing%20desk", "Billing | Acme"]);
    expect(await visit("/ext/other")).toEqual(["extensions/other", "Acme"]);
    expect(await visit("/settings")).toEqual(["info", "Settings | Acme"]);
    expect(await visit("/")).toEqual(["dashboard", "Dashboard | Acme"]);
    expect(await visit("/nowhere/at/all")).toEqual(["", "Acme"]);
    expect(app.textContent).toContain("There's nothing at this address");
  });

  test("explains when it can't load, offering a reload", async () => {
    api(() => reply(500, { error: "Redis is down" }));
    const reload = vi.fn();
    vi.spyOn(window, "location", "get").mockReturnValue({ pathname: "/robin/", search: "", href: "http://localhost/robin/", reload } as unknown as Location);
    await boot();
    expect(app.innerHTML).toMatchSnapshot();
    app.querySelector("button")!.click();
    expect(reload).toHaveBeenCalledTimes(1);
    expect(calls).toEqual(["session"]);
  });
});
