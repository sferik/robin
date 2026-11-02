// Mutation testing: every mutant must be killed (or explicitly disabled
// with a reason where it's provably equivalent).
/** @type {import("@stryker-mutator/api/core").PartialStrykerOptions} */
export default {
  testRunner: "vitest",
  // Tests import source modules dynamically (see test/load.ts), which
  // Vitest's "related files" lookup can't follow; per-test coverage still
  // picks the tests that run for each mutant.
  vitest: { related: false, configFile: "vitest.stryker.config.ts" },
  plugins: ["@stryker-mutator/vitest-runner", "@stryker-mutator/typescript-checker"],
  checkers: ["typescript"],
  tsconfigFile: "tsconfig.json",
  // Catalogues are data; test/i18n_catalogues.test.ts checks them.
  mutate: ["src/**/*.ts", "src/**/*.tsx", "!src/locales/**"],
  coverageAnalysis: "perTest",
  // Bailing on the first failure can race with Vitest recording that
  // failure, which made killed mutants intermittently look like survivors.
  disableBail: true,
  thresholds: { high: 100, low: 100, break: 100 },
  reporters: ["clear-text", "progress", "html"],
  htmlReporter: { fileName: "reports/mutation/index.html" },
  tempDirName: ".stryker-tmp",
  cleanTempDir: "always",
};
