// Every catalogue translates every message in the code, and nothing else,
// keeping its placeholders and giving each plural category its language uses.
import { describe, expect, test } from "vitest";
import { messages } from "../scripts/messages";
import { LOCALES, type Catalogue, type Plural } from "../src/i18n";

const { singular, plural } = messages();
const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe("the messages", () => {
  test("are found in the code", () => {
    expect(singular).toContain("Retry all");
    expect(singular).toContain("Search class, args, error…");
    expect(singular).toContain("There's no \"{set}\" set.");
    expect(plural).toContain("{n} job|{n} jobs");
  });
});

const translated = Object.entries(LOCALES).filter(([, l]) => l.load);

describe.each(translated)("%s", (code, locale) => {
  const load = async () => (await locale.load!()).default;
  const categories = new Intl.PluralRules(code).resolvedOptions().pluralCategories;

  test("translates every message, and only those", async () => {
    const catalogue = await load();
    expect(Object.keys(catalogue).sort()).toEqual([...singular, ...plural].sort());
  });

  test("keeps every placeholder", async () => {
    const catalogue: Catalogue = await load();
    for (const text of singular) {
      expect([text, placeholders(catalogue[text] as string)]).toEqual([text, placeholders(text)]);
    }
    for (const key of plural) {
      const forms = catalogue[key] as Plural;
      const english = placeholders(key.split("|")[1]);
      for (const form of Object.values(forms)) {
        // A form for one item may leave the count out ("an hour", "une heure").
        expect([key, placeholders(form).filter((p) => p !== "n")]).toEqual([key, english.filter((p) => p !== "n")]);
      }
    }
  });

  test("gives exactly the plural forms the language uses", async () => {
    const catalogue = await load();
    for (const key of plural) {
      expect([key, Object.keys(catalogue[key]).sort()]).toEqual([key, [...categories].sort()]);
    }
  });

  test("is written right to left only for right-to-left scripts", () => {
    expect(locale.rtl ?? false).toBe(["ar", "fa", "he", "ur"].includes(code));
  });
});
