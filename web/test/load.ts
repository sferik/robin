import { beforeAll, beforeEach } from "vitest";

/**
 * Import a source module for a test file.
 *
 * The import runs once in `beforeAll`, so code at module level counts as
 * shared by every test. If importing throws, every test in the file fails
 * (instead of the file silently collecting zero tests, which mutation
 * testing would read as "nothing failed").
 */
export function load<T>(importer: () => Promise<T>): { readonly m: T } {
  const box: { m?: T; error?: unknown; failed: boolean } = { failed: false };
  beforeAll(async () => {
    try {
      box.m = await importer();
    } catch (error) {
      box.failed = true;
      box.error = error;
    }
  });
  beforeEach(() => {
    if (box.failed) throw box.error;
  });
  return box as { readonly m: T };
}
