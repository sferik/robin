import { act, fireEvent, render } from "@testing-library/preact";
import { describe, expect, test, vi } from "vitest";
import { load } from "./load";
import { stubLayout } from "./helpers";
import type { Series } from "../src/components/charts";

const C = load(() => import("../src/components/charts"));

const label = (ms: number) => `t${ms}`;
const tooltip = (c: Element) => c.querySelector<HTMLElement>(".tooltip");

describe("outcomes", () => {
  test("describe succeeded and failed series", () => {
    expect(C.m.outcomes()).toEqual([{ label: "Succeeded", cls: "s-processed" }, { label: "Failed", cls: "s-failed" }]);
    expect(C.m.outcomeSeries([1], [2])).toEqual([
      { label: "Succeeded", cls: "s-processed", values: [1], area: true },
      { label: "Failed", cls: "s-failed", values: [2] },
    ]);
  });
});

describe("Legend", () => {
  test("needs at least two series", () => {
    expect(render(<C.m.Legend series={[{ label: "A" }]} />).container.innerHTML).toBe("");
  });

  test("shows a swatch per series", () => {
    expect(render(<C.m.Legend series={C.m.outcomes()} />).container).toMatchSnapshot();
    expect(render(<C.m.Legend series={[{ label: "mail", color: "--series-3" }, { label: "plain" }]} />).container).toMatchSnapshot();
  });
});

describe("LineChart", () => {
  const series: Series[] = [
    { label: "Succeeded", cls: "s-processed", values: [10, 40, 25, 0], area: true },
    { label: "Failed", cls: "s-failed", values: [0, 2, 1] },
    { label: "Colored", color: "--series-2", values: [1, 1, 1, 1] },
  ];
  const xs = [1000, 2000, 3000, 4000];

  test("draws nothing until it knows its width", () => {
    stubLayout(0);
    const { container } = render(<C.m.LineChart label="Jobs" xs={xs} series={series} xLabel={label} />);
    expect(container.innerHTML).toBe('<div class="chart"></div>');
  });

  test("draws axes, lines and areas", () => {
    stubLayout(400);
    const { container } = render(<C.m.LineChart label="Jobs per minute" xs={xs} series={series} xLabel={label} height={200} />);
    expect(container).toMatchSnapshot();
  });

  test("abbreviates big numbers on the y-axis by default", () => {
    stubLayout(400);
    const { container } = render(<C.m.LineChart label="Big" xs={[1, 2]} series={[{ label: "A", values: [0, 42_000] }]} xLabel={label} />);
    expect([...container.querySelectorAll(".axis text[text-anchor='end']")].map((t) => t.textContent)).toEqual(["0", "20K", "40K", "60K"]);
  });

  test("thins out x labels on narrow charts and keeps tiny charts sane", () => {
    stubLayout(150);
    const many = Array.from({ length: 12 }, (_, i) => i * 1000);
    const { container } = render(<C.m.LineChart label="Narrow" xs={many} series={[{ label: "A", values: many.map((_, i) => i) }]} xLabel={label} />);
    expect([...container.querySelectorAll(".axis text")].map((t) => t.textContent)).toMatchSnapshot();
    const tiny = render(<C.m.LineChart label="Tiny" xs={[1, 2]} series={[{ label: "A", values: [0, 0] }]} xLabel={label} />);
    stubLayout(40);
    const tiniest = render(<C.m.LineChart label="Tiniest" xs={[1, 2]} series={[{ label: "A", values: [0, 0] }]} xLabel={label} />);
    expect(tiny.container.querySelector(".baseline")?.getAttribute("x2")).toBe("134");
    expect(tiniest.container.querySelector(".baseline")?.getAttribute("x2")).toBe("44");
  });

  test("puts a single point in the middle and draws no area", () => {
    stubLayout(300);
    const { container } = render(<C.m.LineChart label="One" xs={[5]} series={[{ label: "A", values: [3], area: true, color: "--series-1" }]} xLabel={label} />);
    expect(container).toMatchSnapshot();
  });

  test("follows the pointer with a crosshair and tooltip", async () => {
    stubLayout(400);
    vi.spyOn(Element.prototype, "getBoundingClientRect").mockReturnValue({ left: 100 } as DOMRect);
    const { container } = render(<C.m.LineChart label="Jobs" xs={xs} series={series} xLabel={label} yFormat={(v) => `${v}!`} />);
    const svg = container.querySelector("svg")!;
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 100 + 44 + 340 / 3 + 10 });
    });
    expect(container).toMatchSnapshot();
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 100 + 44 + 340 });
    });
    expect(container.querySelector(".tt-title")?.textContent).toBe("t4000");
    expect(tooltip(container)?.textContent).toContain("Failed0!");
    expect(container.querySelector(".dot.s-failed")?.getAttribute("cy")).toBe("194");
    expect(tooltip(container)?.style.left).toBe("230px");
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 99999 });
    });
    expect(container.querySelector(".tt-title")?.textContent).toBe("t4000");
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 100 });
    });
    expect(container.querySelector(".tt-title")?.textContent).toBe("t1000");
    expect(tooltip(container)?.style.left).toBe("56px");
    await act(() => {
      fireEvent.mouseLeave(svg);
    });
    expect(tooltip(container)).toBeNull();
    expect(container.querySelector(".crosshair")).toBeNull();
  });

  test("draws marks where they fall and lists them in the tooltip", async () => {
    stubLayout(400);
    vi.spyOn(Element.prototype, "getBoundingClientRect").mockReturnValue({ left: 100 } as DOMRect);
    const marks = [
      { at: 999, label: "before" }, { at: 1000, label: "v1" }, { at: 2500, label: null },
      { at: 4500, label: "v3" }, { at: 5000, label: "after" },
    ];
    const { container } = render(<C.m.LineChart label="Jobs" xs={xs} series={series} xLabel={label} marks={marks} />);
    const drawn = [...container.querySelectorAll(".mark")];
    expect(drawn.map((m) => [m.querySelector("line")?.getAttribute("x1"), m.querySelector("line")?.getAttribute("x2"), m.querySelector("title")?.textContent]))
      .toEqual([["44", "44", "Deploy: v1"], ["214", "214", "Deploy"], ["384", "384", "Deploy: v3"]]);
    expect(drawn.map((m) => [m.querySelector("line")?.getAttribute("y1"), m.querySelector("line")?.getAttribute("y2")])).toEqual([["12", "194"], ["12", "194"], ["12", "194"]]);
    const svg = container.querySelector("svg")!;
    const rows = () => [...container.querySelectorAll(".tt-mark")].map((r) => r.textContent);
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 100 + 44 + 340 / 3 });
    });
    expect(rows()).toEqual(["Deploy"]);
    expect(container.querySelector(".tt-mark .swatch.mark")).not.toBeNull();
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 100 + 44 + 340 });
    });
    expect(rows()).toEqual(["Deploy: v3"]);
    await act(() => {
      fireEvent.mouseMove(svg, { clientX: 100 + 44 + 340 * 2 / 3 });
    });
    expect(rows()).toEqual([]);
  });

  test("draws no marks without at least two points", () => {
    stubLayout(400);
    const { container } = render(<C.m.LineChart label="One" xs={[1000]} series={[{ label: "A", values: [1] }]} xLabel={label} marks={[{ at: 1000, label: "v1" }]} />);
    expect(container.querySelector(".mark")).toBeNull();
  });

  test("hides the tooltip if it shrinks away while hovered", async () => {
    const layout = stubLayout(400);
    const { container } = render(<C.m.LineChart label="Jobs" xs={xs} series={series} xLabel={label} />);
    await act(() => {
      fireEvent.mouseMove(container.querySelector("svg")!, { clientX: 200 });
    });
    expect(tooltip(container)).not.toBeNull();
    await act(() => {
      layout.resize(0);
    });
    expect(container.innerHTML).toBe('<div class="chart"></div>');
  });

  test("ignores the pointer when there's no data", async () => {
    stubLayout(400);
    const { container } = render(<C.m.LineChart label="Empty" xs={[]} series={[]} xLabel={label} />);
    await act(() => {
      fireEvent.mouseMove(container.querySelector("svg")!, { clientX: 100 });
    });
    expect(tooltip(container)).toBeNull();
  });

  test("tracks its container's width", async () => {
    const layout = stubLayout(400);
    const { container, unmount } = render(<C.m.LineChart label="Jobs" xs={xs} series={series} xLabel={label} />);
    await act(() => {
      layout.resize(500.4);
    });
    expect(container.querySelector("svg")?.getAttribute("width")).toBe("500");
    expect(layout.observers).toHaveLength(1);
    expect(layout.observers[0].el).toBe(container.querySelector(".chart"));
    unmount();
    expect(layout.observers[0].disconnected).toBe(true);
  });
});

describe("StackedBars", () => {
  const series: Series[] = [
    { label: "Succeeded", cls: "s-processed", values: [5, 0, 8] },
    { label: "Failed", cls: "s-failed", values: [1, 2, 0] },
    { label: "Other", values: [1, 0, 0] },
  ];

  test("draws stacked bars with a gap between segments", () => {
    stubLayout(400);
    const { container } = render(<C.m.StackedBars label="Per day" labels={["a", "b", "c"]} series={series} height={180} />);
    expect(container).toMatchSnapshot();
  });

  test("treats missing values as zero", async () => {
    stubLayout(400);
    const { container } = render(<C.m.StackedBars label="Short" labels={["a", "b"]} series={[{ label: "A", values: [3] }, { label: "B", values: [1, 2] }]} />);
    expect([...container.querySelectorAll(".bar")].map((b) => b.getAttribute("height"))).toEqual(["121.5", "38.5", "79"]);
    await act(() => {
      fireEvent.mouseEnter(container.querySelectorAll("svg > g:not(.grid):not(.axis)")[1]);
    });
    expect(tooltip(container)?.textContent).toBe("bA0B2");
  });

  test("abbreviates big totals on the y-axis", () => {
    stubLayout(400);
    const { container } = render(<C.m.StackedBars label="Big" labels={["a"]} series={[{ label: "A", values: [42_000] }]} />);
    expect([...container.querySelectorAll(".axis text[text-anchor='end']")].map((t) => t.textContent)).toEqual(["0", "20K", "40K", "60K"]);
  });

  test("draws nothing without a width", () => {
    stubLayout(0);
    expect(render(<C.m.StackedBars label="Per day" labels={["a"]} series={series} />).container.innerHTML).toBe('<div class="chart"></div>');
  });

  test("keeps bars between 2 and 28 pixels wide and thins labels", () => {
    stubLayout(400);
    const labels = Array.from({ length: 200 }, (_, i) => `d${i}`);
    const thin = render(<C.m.StackedBars label="Many" labels={labels} series={[{ label: "N", values: labels.map(() => 1) }]} />);
    const bar = thin.container.querySelector(".bar")!;
    expect(bar.getAttribute("width")).toBe("2");
    expect(Number(bar.getAttribute("rx"))).toBeCloseTo(2 / 3);
    expect(thin.container.querySelectorAll(".axis text[text-anchor='middle']")).toHaveLength(4);
    const wide = render(<C.m.StackedBars label="Few" labels={["x"]} series={[{ label: "N", values: [1] }]} />);
    expect(wide.container.querySelector(".bar")?.getAttribute("width")).toBe("28");
    expect(wide.container.querySelector(".bar")?.getAttribute("rx")).toBe("3");
    const none = render(<C.m.StackedBars label="None" labels={[]} series={[]} />);
    expect(none.container.querySelectorAll(".bar")).toHaveLength(0);
    stubLayout(30);
    const cramped = render(<C.m.StackedBars label="Cramped" labels={["x"]} series={[{ label: "N", values: [1] }]} />);
    expect(cramped.container.querySelector(".baseline")?.getAttribute("x2")).toBe("44");
  });

  test("highlights the hovered day and explains it", async () => {
    const layout = stubLayout(400);
    const { container } = render(
      <C.m.StackedBars label="Per day" labels={["2026-10-01", "2026-10-02", "2026-10-03"]} series={series} tickLabel={(l) => l.slice(5)} titleFor={(l) => `On ${l}`} />,
    );
    const groups = container.querySelectorAll("svg > g:not(.grid):not(.axis)");
    await act(() => {
      fireEvent.mouseEnter(groups[1]);
    });
    expect(tooltip(container)).toMatchSnapshot();
    expect([...container.querySelectorAll(".bar")].map((b) => b.getAttribute("class"))).toEqual(["bar", "bar bar-failed", "bar", "bar bar-failed on", "bar"]);
    await act(() => {
      fireEvent.mouseEnter(groups[2]);
    });
    expect(tooltip(container)?.style.left).toBe("230px");
    await act(() => {
      layout.resize(0);
    });
    expect(tooltip(container)).toBeNull();
    await act(() => {
      layout.resize(400);
    });
    expect(tooltip(container)).not.toBeNull();
    await act(() => {
      fireEvent.mouseLeave(container.querySelector("svg")!);
    });
    expect(tooltip(container)).toBeNull();
  });
});

describe("Histogram", () => {
  test("says so when nothing ran", () => {
    const { container } = render(<C.m.Histogram buckets={[{ le: 5, count: 0 }, { le: null, count: 0 }]} height={150} />);
    expect(container.innerHTML).toBe('<div class="chart-empty" style="height: 150px;">No executions in this window</div>');
  });

  test("trims empty tails but keeps one bucket of context", () => {
    stubLayout(800);
    const buckets = [
      { le: 5, count: 0 }, { le: 10, count: 0 }, { le: 20, count: 3 }, { le: 1000, count: 0 }, { le: 1500, count: 4 },
      { le: 2500, count: 0 }, { le: 4000, count: 0 }, { le: null, count: 0 },
    ];
    const { container } = render(<C.m.Histogram buckets={buckets} />);
    expect([...container.querySelectorAll(".axis text[text-anchor='middle']")].map((t) => t.textContent)).toEqual(["10ms", "20ms", "1s", "1.5s", "2.5s"]);
    expect(container).toMatchSnapshot();
  });

  test("labels the open-ended bucket and keeps edges in range", async () => {
    stubLayout(400);
    const { container } = render(<C.m.Histogram buckets={[{ le: 5, count: 1 }, { le: null, count: 2 }]} />);
    expect([...container.querySelectorAll(".axis text[text-anchor='middle']")].map((t) => t.textContent)).toEqual(["5ms", "> 5ms"]);
    await act(() => {
      fireEvent.mouseEnter(container.querySelectorAll("svg > g:not(.grid):not(.axis)")[0]);
    });
    expect(tooltip(container)).toMatchSnapshot();
    const solo = render(<C.m.Histogram buckets={[{ le: null, count: 1 }]} />);
    expect(solo.container.querySelector(".axis text[text-anchor='middle']")?.textContent).toBe("> 0ms");
  });
});
