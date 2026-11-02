import { fireEvent, render, screen } from "@testing-library/preact";
import { describe, expect, test } from "vitest";
import { load } from "./load";

const S = load(() => import("../src/components/selection"));

function Picker({ ids }: { ids: string[] }) {
  const sel = S.m.useSelection(ids);
  return (
    <div>
      <p data-testid="state">{`${sel.count}|${sel.all}|${[...sel.selected].join(",")}|${ids.map((id) => (sel.has(id) ? 1 : 0)).join("")}`}</p>
      {ids.map((id) => <button key={id} onClick={() => sel.toggle(id)}>{id}</button>)}
      <button onClick={sel.toggleAll}>all</button>
      <button onClick={sel.clear}>clear</button>
    </div>
  );
}

const state = () => screen.getByTestId("state").textContent;

describe("useSelection", () => {
  test("toggles rows one at a time and all together", () => {
    render(<Picker ids={["a", "b", "c"]} />);
    expect(state()).toBe("0|false||000");
    fireEvent.click(screen.getByText("b"));
    expect(state()).toBe("1|false|b|010");
    fireEvent.click(screen.getByText("b"));
    expect(state()).toBe("0|false||000");
    fireEvent.click(screen.getByText("a"));
    fireEvent.click(screen.getByText("all"));
    expect(state()).toBe("3|true|a,b,c|111");
    fireEvent.click(screen.getByText("all"));
    expect(state()).toBe("0|false||000");
    fireEvent.click(screen.getByText("c"));
    fireEvent.click(screen.getByText("clear"));
    expect(state()).toBe("0|false||000");
  });

  test("drops rows that leave the page", () => {
    const { rerender } = render(<Picker ids={["a", "b"]} />);
    fireEvent.click(screen.getByText("all"));
    rerender(<Picker ids={["b", "c"]} />);
    expect(state()).toBe("1|false|b|10");
    rerender(<Picker ids={["b"]} />);
    expect(state()).toBe("1|true|b|1");
  });

  test("is never 'all' with nothing on the page", () => {
    render(<Picker ids={[]} />);
    expect(state()).toBe("0|false||");
  });
});
