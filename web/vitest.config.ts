import { defineConfig } from "vitest/config";

// Dates render in UTC so snapshots are identical on every machine.
process.env.TZ = "UTC";

export default defineConfig({
  test: {
    environment: "happy-dom",
    environmentOptions: {
      // Stylesheets that extensions add are never fetched.
      happyDOM: { url: "http://localhost/robin/", settings: { disableCSSFileLoading: true, handleDisabledFileLoadingAsSuccess: true } },
    },
    include: ["test/**/*.test.{ts,tsx}"],
    setupFiles: ["test/setup.ts"],
    restoreMocks: true,
    coverage: {
      provider: "istanbul",
      // build.ts drives Bun.build and can't run under Vitest; CI checks its
      // output instead by rebuilding and diffing lib/robin/web/dist.
      include: ["src/**/*.{ts,tsx}"],
      reporter: ["text", "html", "json-summary"],
      thresholds: { lines: 100, functions: 100, branches: 100, statements: 100 },
    },
  },
});
