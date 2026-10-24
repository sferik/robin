// Lists the dashboard's messages: the English text passed to t(), tj(),
// N_(), tn() and tnj() in src/. Translators work from this list, and
// test/i18n_catalogues.test.ts checks every catalogue against it.
//
//   bun run scripts/messages.ts            # every message, as JSON
//   bun run scripts/messages.ts de         # the ones src/locales/de.ts lacks
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const SRC = join(import.meta.dirname, "..", "src");

// A double-quoted string literal, escapes and all.
const STRING = String.raw`"((?:[^"\\]|\\.)*)"`;
const SINGLE = new RegExp(String.raw`\b(?:t|tj|N_)\(\s*${STRING}`, "g");
const PLURAL = new RegExp(String.raw`\b(?:tn|tnj)\(\s*${STRING},\s*${STRING}`, "g");

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "locales" ? [] : sources(path);
    return /\.tsx?$/.test(entry.name) ? [path] : [];
  });
}

const unquote = (literal: string): string => JSON.parse(`"${literal}"`) as string;

/** Messages in the code: plain ones by text, plural ones as "one|other". */
export function messages(dir = SRC): { singular: string[]; plural: string[] } {
  const singular = new Set<string>();
  const plural = new Set<string>();
  for (const file of sources(dir)) {
    const code = readFileSync(file, "utf8");
    for (const [, text] of code.matchAll(SINGLE)) singular.add(unquote(text));
    for (const [, one, other] of code.matchAll(PLURAL)) plural.add(`${unquote(one)}|${unquote(other)}`);
  }
  return { singular: [...singular].sort(), plural: [...plural].sort() };
}

if (import.meta.main) {
  const { singular, plural } = messages();
  const code = process.argv[2];
  const have = code ? Object.keys(((await import(`../src/locales/${code}.ts`)) as { default: object }).default) : [];
  const missing = (list: string[]) => list.filter((m) => !have.includes(m));
  console.log(JSON.stringify({ singular: missing(singular), plural: missing(plural) }, null, 2));
}
