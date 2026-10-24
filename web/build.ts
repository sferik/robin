// Builds the dashboard into ../lib/robin/web/dist:
//   index.html            template with %ROBIN_BASE% / %ROBIN_TITLE% placeholders
//   assets/*-[hash].*     minified JS, CSS, fonts and brand images (+ .gz);
//                         each language's catalogue is a chunk loaded on demand
//
// Usage: bun run build.ts [--watch]
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, watch } from "node:fs";
import { createHash } from "node:crypto";
import { basename, extname, join } from "node:path";
import { gzipSync } from "bun";

const root = import.meta.dir;
const dist = join(root, "..", "lib", "robin", "web", "dist");
const assetsDir = join(dist, "assets");
const brandDir = join(root, "..", "assets");

function hashed(name: string, data: Uint8Array | string): string {
  const hash = createHash("sha256").update(data).digest("hex").slice(0, 10);
  const ext = extname(name);
  return `${basename(name, ext)}-${hash}${ext}`;
}

// Brand art drawn elsewhere in the repo; fall back to a simple mark.
const PLACEHOLDER_MARK = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="M6 34 L40 12 L58 18 L46 26 L52 46 L24 50 Z" fill="#1c2433"/><path d="M24 50 L34 30 L46 36 Z" fill="#c81d3a"/><circle cx="46" cy="19" r="2.5" fill="#fff"/></svg>`;

function brandAsset(file: string): { name: string; data: string } {
  const path = join(brandDir, file);
  const data = existsSync(path) ? readFileSync(path, "utf8") : PLACEHOLDER_MARK;
  return { name: hashed(file, data), data };
}

async function build(): Promise<void> {
  const started = performance.now();
  rmSync(dist, { recursive: true, force: true });
  mkdirSync(assetsDir, { recursive: true });

  const result = await Bun.build({
    entrypoints: [join(root, "src", "main.tsx")],
    outdir: assetsDir,
    minify: true,
    target: "browser",
    splitting: true,
    naming: { entry: "[name]-[hash].[ext]", asset: "[name]-[hash].[ext]", chunk: "[name]-[hash].[ext]" },
    publicPath: "./", // assets sit beside the CSS that references them
    define: { "process.env.NODE_ENV": '"production"' },
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    throw new Error("build failed");
  }

  const outputs = result.outputs.map((o) => basename(o.path));
  const js = result.outputs.filter((o) => o.kind === "entry-point").map((o) => basename(o.path)).find((f) => f.endsWith(".js"));
  const css = outputs.find((f) => f.endsWith(".css"));
  if (!js || !css) throw new Error(`expected a .js and .css output, got ${outputs.join(", ")}`);

  const favicon = brandAsset("favicon.svg");
  const logo = brandAsset("robin.svg");
  const wordmark = brandAsset("robin-wordmark.svg");
  for (const a of [favicon, logo, wordmark]) writeFileSync(join(assetsDir, a.name), a.data);

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<base href="%ROBIN_BASE%">
<title>%ROBIN_TITLE%</title>
<meta name="robin-logo" content="assets/${logo.name}">
<meta name="robin-wordmark" content="assets/${wordmark.name}">
<meta name="color-scheme" content="light dark">
<link rel="icon" type="image/svg+xml" href="assets/${favicon.name}">
<link rel="stylesheet" href="assets/${css}">
<script type="module" src="assets/${js}"></script>
</head>
<body>
<div id="app"></div>
<noscript>Robin's dashboard needs JavaScript.</noscript>
</body>
</html>
`;
  writeFileSync(join(dist, "index.html"), html);

  let total = 0;
  for (const file of readdirSync(assetsDir)) {
    const path = join(assetsDir, file);
    const data = readFileSync(path);
    if (/\.(js|css|svg)$/.test(file)) {
      const gz = gzipSync(data, { level: 9 });
      writeFileSync(`${path}.gz`, gz);
      total += gz.length;
    } else {
      total += data.length;
    }
  }
  console.log(`built ${js}, ${css} and ${outputs.length - 2} chunks (${(total / 1024).toFixed(1)} KiB over the wire) in ${(performance.now() - started).toFixed(0)}ms`);
}

await build();

if (process.argv.includes("--watch")) {
  console.log("watching src/ for changes…");
  let timer: ReturnType<typeof setTimeout> | undefined;
  watch(join(root, "src"), { recursive: true }, () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      build().catch((e: unknown) => {
        console.error(e);
      });
    }, 80);
  });
}
