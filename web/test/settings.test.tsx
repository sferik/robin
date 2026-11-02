import { describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { mockApi, readOnlySession, reply, session } from "./helpers";
import { renderPage } from "./render_page";

const logo = document.createElement("meta");
logo.name = "robin-logo";
logo.content = "assets/robin-1.svg";
document.head.append(logo);

const P = load(() => import("../src/pages/settings"));
const State = load(() => import("../src/state"));
const NF = load(() => import("../src/pages/not_found"));
const I = load(() => import("../src/i18n"));

const INFO = {
  redis_url: "redis://localhost:6379/0",
  processes: 3,
  leader: "web-1:42:aa",
  redis: {
    redis_version: "8.0.1", role: "master", uptime_in_seconds: "90061", used_memory_human: "12M", used_memory_peak_human: "20M",
    maxmemory_human: "1G", maxmemory_policy: "allkeys-lru", connected_clients: "17", instantaneous_ops_per_sec: "523",
    keyspace_hits: "998", keyspace_misses: "2",
  },
  robin: { version: "0.1.0", ruby: "ruby 3.4.11", key_prefix: "robin:", max_retries: 20, dead_max_jobs: 10000, dead_timeout_days: 180, native_resp: true },
};

describe("NotFound", () => {
  test("links home", async () => {
    expect((await renderPage(<NF.m.NotFound />)).container).toMatchSnapshot();
  });
});

describe("Settings", () => {
  test("shows Robin, Redis and access details", async () => {
    State.m.sessionStore.set(session({ permissions: { delete: false, custom_thing: true } as never }));
    mockApi({ info: INFO });
    const { container } = await renderPage(<P.m.Settings />);
    expect(container).toMatchSnapshot();
  });

  test("copes with sparse Redis info", async () => {
    State.m.sessionStore.set(readOnlySession());
    mockApi({
      info: {
        ...INFO, leader: null, redis: { maxmemory_human: "0B", maxmemory_policy: "noeviction", keyspace_hits: "1", keyspace_misses: "1" },
        robin: { ...INFO.robin, native_resp: false },
      },
    });
    const { container } = await renderPage(<P.m.Settings />);
    expect(container).toMatchSnapshot();
  });

  test("shows a dash when Redis reports no memory limit setting", async () => {
    State.m.sessionStore.set(session());
    mockApi({ info: { ...INFO, redis: {} } });
    const { container } = await renderPage(<P.m.Settings />);
    expect(container.querySelector(".notice")).toBeNull();
    expect([...container.querySelectorAll("dd")].slice(9, 17).map((d) => d.textContent)).toEqual(["redis://localhost:6379/0", "– ", "–", "–", "– ", "–", "–", "–"]);
  });

  test("shows loading, then errors with a retry", async () => {
    State.m.sessionStore.set(session());
    const api = mockApi({ info: reply(500, { error: "Redis is down" }) });
    const { container, getByText } = await renderPage(<P.m.Settings />);
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Redis is down");
    api.routes.info = INFO;
    getByText("Try again").click();
    await renderPage(null);
    expect(container.textContent).toContain("Robin 0.1.0");
  });

  test("shows a skeleton while loading", () => {
    State.m.sessionStore.set(session());
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => undefined)));
    return renderPage(<P.m.Settings />).then(({ container }) => {
      expect(container.querySelector('[aria-busy="true"]')).not.toBeNull();
    });
  });
});

describe("Settings without a logo", () => {
  test("leaves the image out", async () => {
    logo.remove();
    vi.resetModules();
    const state = await import("../src/state");
    const settings = await import("../src/pages/settings");
    state.sessionStore.set(session());
    mockApi({ info: INFO });
    const { container } = await renderPage(<settings.Settings />);
    expect(container.querySelector("img")).toBeNull();
  });

  test("switches the dashboard's language", async () => {
    I.m.LOCALES.test = { name: "Testisch", load: () => Promise.resolve({ default: { Language: "Sprache", "Your access": "Ihr Zugriff" } }) };
    mockApi({ info: INFO });
    const { container } = await renderPage(<P.m.Settings />);
    const select = container.querySelector<HTMLSelectElement>("select")!;
    expect(select.value).toBe("en");
    expect([...select.options].find((o) => o.value === "ar")?.textContent).toBe("العربية");
    expect([...select.options].find((o) => o.value === "ar")?.lang).toBe("ar");
    select.value = "test";
    select.dispatchEvent(new Event("change"));
    // The app re-renders everything; the picker follows on its own.
    await vi.waitFor(() => {
      expect(container.querySelector<HTMLSelectElement>("select")!.value).toBe("test");
    });
    expect(I.m.t("Your access")).toBe("Ihr Zugriff");
    expect(localStorage.getItem("robin.locale")).toBe("test");
    await I.m.setLocale("en", false);
    delete I.m.LOCALES.test;
  });
});
