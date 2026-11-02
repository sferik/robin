import { act, render } from "@testing-library/preact";
import type { ComponentChildren } from "preact";
import { flush } from "./helpers";

/** Render a page and let its API requests settle. */
export async function renderPage(ui: ComponentChildren) {
  const result = render(<>{ui}</>);
  await act(flush);
  return result;
}

/** Let in-flight requests and state updates settle. */
export async function settle() {
  await act(flush);
}
