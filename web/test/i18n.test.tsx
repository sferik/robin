import { render } from "@testing-library/preact";
import { afterEach, describe, expect, test } from "vitest";
import { load } from "./load";
import type { Catalogue } from "../src/i18n";

const I = load(() => import("../src/i18n"));

const CATALOGUE: Catalogue = {
  "Retry all": "Alle wiederholen",
  "{count} jobs in {queue}": "{queue}: {count} Jobs",
  "{n} job|{n} jobs": { one: "ein Job", other: "{n} Jobs" },
  "{jobs} is waiting|{jobs} are waiting": { one: "{jobs} wartet", other: "{jobs} warten" },
  "{n} file|{n} files": { other: "{n} Dateien" },
};

/** Switches to a made-up language with CATALOGUE. */
async function useTest(code = "de", rtl = false) {
  I.m.LOCALES.test = { name: "Test", rtl, load: () => Promise.resolve({ default: CATALOGUE }) };
  await I.m.setLocale("test");
  // Number and plural formats follow `code`.
  I.m.localeStore.set({ code, catalogue: CATALOGUE });
}

afterEach(() => {
  I.m.localeStore.set({ code: "en", catalogue: {} });
  delete I.m.LOCALES.test;
});

const html = (node: preact.ComponentChildren) => render(<p>{node}</p>).container.innerHTML;

describe("t", () => {
  test("is English, with placeholders filled, without a catalogue", () => {
    expect(I.m.t("Retry all")).toBe("Retry all");
    expect(I.m.t("{count} jobs in {queue}", { count: 3, queue: "mail" })).toBe("3 jobs in mail");
    expect(I.m.t("{a}{a} {b}", { a: "x" })).toBe("xx {b}");
    expect(I.m.t("{a} and {not-a-name}", { a: 1 })).toBe("1 and {not-a-name}");
  });

  test("translates, falling back to English", async () => {
    await useTest();
    expect(I.m.t("Retry all")).toBe("Alle wiederholen");
    expect(I.m.t("{count} jobs in {queue}", { count: 3, queue: "mail" })).toBe("mail: 3 Jobs");
    expect(I.m.t("Untranslated {x}", { x: 1 })).toBe("Untranslated 1");
    // A plural entry isn't a plain message.
    expect(I.m.t("{n} job|{n} jobs")).toBe("{n} job|{n} jobs");
  });

  test("N_ marks text without translating it", async () => {
    await useTest();
    expect(I.m.N_("Retry all")).toBe("Retry all");
  });
});

describe("tn", () => {
  test("picks the English form and formats the count", () => {
    expect(I.m.tn("{n} job", "{n} jobs", 1)).toBe("1 job");
    expect(I.m.tn("{n} job", "{n} jobs", 0)).toBe("0 jobs");
    expect(I.m.tn("{n} job", "{n} jobs", 1234)).toBe("1,234 jobs");
    expect(I.m.tn("{n} job in {q}", "{n} jobs in {q}", 2, { q: "mail" })).toBe("2 jobs in mail");
    expect(I.m.tn("{n} job", "{n} jobs", 2, { n: "two" })).toBe("two jobs");
  });

  test("uses the language's plural rules and number format", async () => {
    await useTest();
    expect(I.m.tn("{n} job", "{n} jobs", 1)).toBe("ein Job");
    expect(I.m.tn("{n} job", "{n} jobs", 1234)).toBe("1.234 Jobs");
    expect(I.m.tn("{n} thing", "{n} things", 2)).toBe("2 things");
  });

  test("falls back to the other form when a category is missing", async () => {
    await useTest();
    expect(I.m.tn("{n} file", "{n} files", 1)).toBe("1 Dateien");
  });
});

describe("tj and tnj", () => {
  test("fill placeholders with elements", async () => {
    expect(html(I.m.tj("Scrape {path} now", { path: <code>/m</code> }))).toBe("<p>Scrape <code>/m</code> now</p>");
    expect(html(I.m.tj("{path}", { path: <code>/m</code> }))).toBe("<p><code>/m</code></p>");
    expect(html(I.m.tj("{a} and {b}", { a: "x" }))).toBe("<p>x and {b}</p>");
    expect(html(I.m.tj("{a}", { a: 0 }))).toBe("<p>0</p>");
    expect(render(<p>{I.m.tj("{a}{b}", { a: "x", b: "y" })}</p>).container.firstChild!.childNodes).toHaveLength(2);
    expect(html(I.m.tnj("{jobs} is waiting", "{jobs} are waiting", 2, { jobs: <b>2 jobs</b> }))).toBe("<p><b>2 jobs</b> are waiting</p>");
    expect(html(I.m.tnj("{n} is waiting", "{n} are waiting", 1234, {}))).toBe("<p>1,234 are waiting</p>");
    expect(html(I.m.tnj("{n} is waiting", "{n} are waiting", 2, { n: <i>two</i> }))).toBe("<p><i>two</i> are waiting</p>");
    await useTest();
    expect(html(I.m.tnj("{jobs} is waiting", "{jobs} are waiting", 1, { jobs: <b>1</b> }))).toBe("<p><b>1</b> wartet</p>");
  });
});

describe("preferredLocale", () => {
  test("is the saved choice when there is one", () => {
    expect(I.m.preferredLocale("fr", ["de"])).toBe("fr");
    expect(I.m.preferredLocale("xx", ["de"])).toBe("de");
    expect(I.m.preferredLocale("toString", [])).toBe("en");
  });

  test("matches the browser's languages exactly, then by base language", () => {
    expect(I.m.preferredLocale(null, ["pt-BR"])).toBe("pt-BR");
    expect(I.m.preferredLocale(null, ["PT-br"])).toBe("pt-BR");
    expect(I.m.preferredLocale(null, ["pt-PT"])).toBe("pt-BR");
    expect(I.m.preferredLocale(null, ["de-AT", "fr"])).toBe("de");
    expect(I.m.preferredLocale(null, ["xx", "fr-CA"])).toBe("fr");
    expect(I.m.preferredLocale(null, ["xx"])).toBe("en");
    expect(I.m.preferredLocale(null, [])).toBe("en");
  });

  test("tells Chinese scripts apart", () => {
    expect(I.m.preferredLocale(null, ["zh"])).toBe("zh-CN");
    expect(I.m.preferredLocale(null, ["zh-SG"])).toBe("zh-CN");
    expect(I.m.preferredLocale(null, ["zh-Hans-HK"])).toBe("zh-CN");
    expect(I.m.preferredLocale(null, ["zh-HK"])).toBe("zh-TW");
    expect(I.m.preferredLocale(null, ["zh-mo"])).toBe("zh-TW");
    expect(I.m.preferredLocale(null, ["zh-Hant"])).toBe("zh-TW");
    expect(I.m.preferredLocale(null, ["zh-Hant-CN"])).toBe("zh-TW");
    expect(I.m.preferredLocale(null, ["zh-TW"])).toBe("zh-TW");
    expect(I.m.preferredLocale(null, ["zh-twx"])).toBe("zh-CN");
  });

  test("defaults to the saved choice and the browser's languages", () => {
    localStorage.setItem("robin.locale", "ja");
    expect(I.m.preferredLocale()).toBe("ja");
    localStorage.clear();
    expect(I.m.preferredLocale()).toBe(I.m.preferredLocale(null, navigator.languages));
  });
});

describe("setLocale", () => {
  test("loads the catalogue, remembers the choice and sets the page's language and direction", async () => {
    await useTest("he", true);
    expect(I.m.locale()).toBe("he");
    expect(localStorage.getItem("robin.locale")).toBe("test");
    expect([document.documentElement.lang, document.documentElement.dir]).toEqual(["test", "rtl"]);
    expect(I.m.t("Retry all")).toBe("Alle wiederholen");
    await I.m.setLocale("en", false);
    expect([I.m.locale(), document.documentElement.lang, document.documentElement.dir]).toEqual(["en", "en", "ltr"]);
    expect(I.m.t("Retry all")).toBe("Retry all");
    expect(localStorage.getItem("robin.locale")).toBe("test");
  });

  test("falls back to English for unknown languages", async () => {
    await I.m.setLocale("xx");
    expect(I.m.locale()).toBe("en");
    expect(localStorage.getItem("robin.locale")).toBe("en");
    await I.m.setLocale("constructor");
    expect(I.m.locale()).toBe("en");
  });

  test("right-to-left scripts are marked so", () => {
    const rtl = Object.entries(I.m.LOCALES).filter(([, l]) => l.rtl).map(([c]) => c);
    expect(rtl).toEqual(["ar", "fa", "he", "ur"]);
  });

  test("every language but English has a catalogue to load", () => {
    const missing = Object.entries(I.m.LOCALES).filter(([, l]) => !l.load).map(([c]) => c);
    expect(missing).toEqual(["en"]);
    expect(Object.keys(I.m.LOCALES)).toEqual([...Object.keys(I.m.LOCALES)].sort());
  });
});
