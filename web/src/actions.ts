import { send, type Params } from "./api";
import { confirmAction, toast } from "./state";

export interface Confirm { title: string; body?: string; action: string; danger?: boolean }

/** Run an API mutation with an optional confirmation, then toast the result. */
export async function act<T>(
  run: () => Promise<T>,
  done: string | ((result: T) => string),
  confirm?: Confirm,
): Promise<T | undefined> {
  if (confirm && !(await confirmAction(confirm))) return undefined;
  try {
    const result = await run();
    toast(typeof done === "function" ? done(result) : done);
    return result;
  } catch (e) {
    toast((e as Error).message, "error");
    return undefined;
  }
}

export const post = <T = unknown>(path: string, body?: unknown, params?: Params) => send<T>("POST", path, body, params);
export const del = <T = unknown>(path: string, body?: unknown) => send<T>("DELETE", path, body);
