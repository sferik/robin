import { configDefaults, defineConfig, mergeConfig } from "vitest/config";
import base from "./vitest.config";

// Stryker runs the tests against instrumented sources, where
// scripts/messages.ts can't find the messages; the catalogues it checks
// aren't mutated anyway.
export default mergeConfig(base, defineConfig({ test: { exclude: [...configDefaults.exclude, "test/i18n_catalogues.test.ts"] } }));
