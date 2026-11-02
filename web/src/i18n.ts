// Translations. Messages are written in English in the code and looked up
// by their English text, so the code reads as it renders and a missing
// translation falls back to English:
//
//   t("Retry all")
//   t("{count} jobs in {queue}", { count: num(n), queue })
//   tn("{n} job", "{n} jobs", n)              // plural forms
//   tj("Scrape {path}", { path: <code>{p}</code> })  // placeholders as elements
//   const LABEL = N_("Busy")  ...  t(LABEL)   // marks text translated later
//
// Each language is a catalogue in src/locales/<code>.ts, loaded on demand.
// test/i18n_catalogues.test.ts checks every catalogue against the messages
// in the code (scripts/messages.ts lists them).
import { Fragment, h, type ComponentChildren } from "preact";
import { createStore } from "./store";

/** One form per CLDR plural category the language uses ("other" always). */
export type Plural = Partial<Record<Intl.LDMLPluralRule, string>> & { other: string };

/** English text → translation. Plurals are keyed "one|other". */
export type Catalogue = Record<string, string | Plural>;

export interface Locale {
  /** The language's own name for itself. */
  name: string;
  rtl?: boolean;
  load?: () => Promise<{ default: Catalogue }>;
}

export const LOCALES: Record<string, Locale> = {
  ar: { name: "العربية", rtl: true, load: () => import("./locales/ar") },
  cs: { name: "Čeština", load: () => import("./locales/cs") },
  da: { name: "Dansk", load: () => import("./locales/da") },
  de: { name: "Deutsch", load: () => import("./locales/de") },
  en: { name: "English" },
  es: { name: "Español", load: () => import("./locales/es") },
  fa: { name: "فارسی", rtl: true, load: () => import("./locales/fa") },
  fr: { name: "Français", load: () => import("./locales/fr") },
  he: { name: "עברית", rtl: true, load: () => import("./locales/he") },
  hi: { name: "हिन्दी", load: () => import("./locales/hi") },
  it: { name: "Italiano", load: () => import("./locales/it") },
  ja: { name: "日本語", load: () => import("./locales/ja") },
  ko: { name: "한국어", load: () => import("./locales/ko") },
  nb: { name: "Norsk bokmål", load: () => import("./locales/nb") },
  nl: { name: "Nederlands", load: () => import("./locales/nl") },
  pl: { name: "Polski", load: () => import("./locales/pl") },
  "pt-BR": { name: "Português (Brasil)", load: () => import("./locales/pt-BR") },
  ru: { name: "Русский", load: () => import("./locales/ru") },
  sv: { name: "Svenska", load: () => import("./locales/sv") },
  tr: { name: "Türkçe", load: () => import("./locales/tr") },
  uk: { name: "Українська", load: () => import("./locales/uk") },
  ur: { name: "اردو", rtl: true, load: () => import("./locales/ur") },
  vi: { name: "Tiếng Việt", load: () => import("./locales/vi") },
  "zh-CN": { name: "简体中文", load: () => import("./locales/zh-CN") },
  "zh-TW": { name: "繁體中文", load: () => import("./locales/zh-TW") },
};

export const localeStore = createStore<{ code: string; catalogue: Catalogue }>({ code: "en", catalogue: {} });

const SAVED = "robin.locale";

/** The current language's code, e.g. "en" or "pt-BR". */
export const locale = (): string => localeStore.get().code;

export type Params = Record<string, string | number>;

/** `text` with {name} placeholders filled from `params` (unknown ones are left as they are). */
export const fill = (text: string, params: Params) => text.replace(/\{(\w+)\}/g, (all, name: string) => (name in params ? String(params[name]) : all));

/** Marks `text` for translation without translating it (yet). */
export const N_ = (text: string): string => text;

/** `text` in the current language, with {name} placeholders filled in. */
export function t(text: string, params: Params = {}): string {
  const found = localeStore.get().catalogue[text];
  return fill(typeof found === "string" ? found : text, params);
}

/** The plural form for `count`, untranslated placeholders and all. */
function pluralText(one: string, other: string, count: number): string {
  const forms = localeStore.get().catalogue[`${one}|${other}`];
  if (typeof forms !== "object") return count === 1 ? one : other;
  return forms[new Intl.PluralRules(locale()).select(count)] ?? forms.other;
}

const count = (n: number) => new Intl.NumberFormat(locale()).format(n);

/** The plural form for `count`, with {n} set to the formatted count. */
export function tn(one: string, other: string, n: number, params: Params = {}): string {
  return fill(pluralText(one, other, n), { n: count(n), ...params });
}

/** Fills placeholders with strings or elements. */
function parts(text: string, values: Record<string, ComponentChildren>): ComponentChildren {
  const pieces = text.split(/\{(\w+)\}/);
  // Odd pieces are placeholder names.
  const nodes = pieces.map((piece, i) => (i % 2 ? (piece in values ? values[piece] : `{${piece}}`) : piece));
  return h(Fragment, null, ...nodes.filter((node) => node !== ""));
}

/** Like t(), but placeholders may be filled with elements: tj("Scrape {path}", { path: <code>…</code> }). */
export const tj = (text: string, values: Record<string, ComponentChildren>): ComponentChildren => parts(t(text), values);

/** Like tn(), but placeholders may be filled with elements ({n} is the formatted count unless given). */
export const tnj = (one: string, other: string, n: number, values: Record<string, ComponentChildren>): ComponentChildren =>
  parts(pluralText(one, other, n), { n: count(n), ...values });

/**
 * The best language for someone: their saved choice, else the first of
 * their browser's languages Robin has (by base language), else English.
 */
export function preferredLocale(saved = localStorage.getItem(SAVED), languages: readonly string[] = navigator.languages): string {
  if (saved && Object.hasOwn(LOCALES, saved)) return saved;
  const codes = Object.keys(LOCALES);
  for (const language of languages) {
    // Only Chinese has two variants; every other language has one.
    const [base, ...subtags] = language.toLowerCase().split("-");
    if (base === "zh") return chinese(subtags);
    const match = codes.find((c) => c.split("-")[0] === base);
    if (match) return match;
  }
  return "en";
}

/** Traditional characters for the Hant script, or (without a script) Taiwan, Hong Kong and Macau. */
function chinese(subtags: string[]): string {
  if (subtags.includes("hans")) return "zh-CN";
  if (subtags.includes("hant")) return "zh-TW";
  return ["tw", "hk", "mo"].some((region) => subtags.includes(region)) ? "zh-TW" : "zh-CN";
}

/** Switches the dashboard to `code` (remembering the choice if asked). */
export async function setLocale(code: string, remember = true): Promise<void> {
  const known = Object.hasOwn(LOCALES, code) ? code : "en";
  const info = LOCALES[known];
  const catalogue = info.load ? (await info.load()).default : {};
  if (remember) localStorage.setItem(SAVED, known);
  document.documentElement.lang = known;
  document.documentElement.dir = info.rtl ? "rtl" : "ltr";
  localeStore.set({ code: known, catalogue });
}
