// Hand-rolled SVG charts. One y-axis per chart, thin marks, recessive grid,
// a crosshair + tooltip on every plot, a legend for 2+ series.
import { useLayoutEffect, useRef, useState } from "preact/hooks";
import { niceTicks, num } from "../format";
import { N_, t } from "../i18n";

function useWidth<T extends HTMLElement>(): [preact.RefObject<T>, number] {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(0);
  // Stryker disable ArrayDeclaration: any constant dependency list means "run once"
  useLayoutEffect(() => {
    const el = ref.current!; // refs are attached before layout effects run
    setWidth(el.clientWidth);
    const ro = new ResizeObserver(([entry]) => {
      setWidth(Math.round(entry.contentRect.width));
    });
    ro.observe(el);
    return () => {
      ro.disconnect();
    };
  }, []);
  // Stryker restore ArrayDeclaration
  return [ref, width];
}

/** A series' look: `cls` is s-processed or s-failed; `color` names a CSS color variable. */
export interface SeriesStyle {
  label: string;
  cls?: "s-processed" | "s-failed";
  color?: string;
}

export interface Series extends SeriesStyle {
  values: number[];
  area?: boolean;
}

const SUCCEEDED = N_("Succeeded");
const FAILED = N_("Failed");

/** Succeeded and failed, the pair most charts show (labels in the current language). */
export function outcomes(): SeriesStyle[] {
  return [
    { label: t(SUCCEEDED), cls: "s-processed" },
    { label: t(FAILED), cls: "s-failed" },
  ];
}

/** Succeeded (filled) and failed lines or bars. */
export function outcomeSeries(succeeded: number[], failed: number[]): Series[] {
  const [ok, failures] = outcomes();
  return [
    { ...ok, values: succeeded, area: true },
    { ...failures, values: failed },
  ];
}

/** A deploy (or other event) drawn as a vertical line. `at` is epoch ms. */
export interface Mark {
  at: number;
  label: string | null;
}

const M = { top: 12, right: 16, bottom: 26, left: 44 };

function pathFor(values: number[], x: (i: number) => number, y: (v: number) => number): string {
  return values.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");
}

const SWATCH = { "s-processed": "processed", "s-failed": "failed" } as const;

function Swatch({ s }: { s: SeriesStyle }) {
  return <i class={`swatch ${s.cls ? SWATCH[s.cls] : ""}`} style={s.color ? { background: `var(${s.color})` } : undefined} />;
}

export function Legend({ series }: { series: SeriesStyle[] }) {
  if (series.length < 2) return null;
  return (
    <div class="legend" aria-hidden="true">
      {series.map((s) => (
        <span key={s.label}>
          <Swatch s={s} />
          {s.label}
        </span>
      ))}
    </div>
  );
}

function Tooltip({ left, title, series, at, format, marks = [] }: {
  left: number; title: string; series: Series[]; at: number; format: (v: number) => string; marks?: Mark[];
}) {
  return (
    <div class="tooltip" style={{ left: `${left}px`, top: `${M.top}px` }}>
      <div class="tt-title">{title}</div>
      {series.map((s) => (
        <div class="tt-row" key={s.label}>
          <Swatch s={s} />
          <span>{s.label}</span>
          <span>{format(s.values[at] ?? 0)}</span>
        </div>
      ))}
      {marks.map((m) => (
        <div class="tt-row tt-mark" key={m.at}>
          <i class="swatch mark" />
          <span>{markText(m)}</span>
        </div>
      ))}
    </div>
  );
}

const markText = (m: Mark) => (m.label ? t("Deploy: {label}", { label: m.label }) : t("Deploy"));

/** The marks from `at` up to (not including) `until`. */
const marksBetween = (marks: Mark[], at: number, until: number) => marks.filter((m) => m.at >= at && m.at < until);

/**
 * Lines (optionally filled) over time. `xs` are epoch ms, evenly spaced.
 * `marks` (e.g. deploys) are drawn as vertical lines where they fall, and
 * listed in the tooltip of the point whose interval they're in.
 */
export function LineChart({
  xs, series, height = 220, xLabel, yFormat = (v: number) => num(v, true), label, marks = [],
}: {
  xs: number[]; series: Series[]; height?: number; xLabel: (ms: number) => string;
  yFormat?: (v: number) => string; label: string; marks?: Mark[];
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const n = xs.length;
  const max = Math.max(1, ...series.flatMap((s) => s.values));
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1];
  const w = Math.max(0, width - M.left - M.right);
  const h = height - M.top - M.bottom;
  const x = (i: number) => M.left + (n <= 1 ? w / 2 : (i / (n - 1)) * w);
  const y = (v: number) => M.top + h - (v / top) * h;
  const xTickEvery = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(w / 90))));
  // Each point stands for the interval up to the next one. With fewer
  // than two points the step is NaN, and no mark falls in range.
  const step = xs[1] - xs[0];
  const shown = marksBetween(marks, xs[0], xs[n - 1] + step);
  const xAt = (t: number) => M.left + Math.min(1, (t - xs[0]) / (xs[n - 1] - xs[0])) * w;

  const onMove = (e: MouseEvent) => {
    if (n === 0) return;
    const rect = (e.currentTarget as SVGElement).getBoundingClientRect();
    const px = e.clientX - rect.left - M.left;
    setHover(Math.max(0, Math.min(n - 1, Math.round((px / w) * (n - 1)))));
  };

  return (
    <div class="chart" ref={ref}>
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label={label} onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
          <g class="grid">
            {ticks.map((t) => <line x1={M.left} x2={M.left + w} y1={y(t)} y2={y(t)} key={t} />)}
          </g>
          <g class="axis">
            {ticks.map((t) => (
              <text x={M.left - 8} y={y(t) + 4} text-anchor="end" key={t}>{yFormat(t)}</text>
            ))}
            {xs.map((t, i) =>
              i % xTickEvery === 0 ? (
                <text x={x(i)} y={height - 6} text-anchor={i === 0 ? "start" : "middle"} key={t}>{xLabel(t)}</text>
              ) : null,
            )}
          </g>
          <line class="baseline" x1={M.left} x2={M.left + w} y1={y(0)} y2={y(0)} />
          {series.map((s) => (
            <g class={s.cls} style={s.color ? { stroke: `var(${s.color})`, fill: `var(${s.color})` } : undefined} key={s.label}>
              {s.area && n > 1 && <path class="area" d={`${pathFor(s.values, x, y)}L${x(n - 1)},${y(0)}L${x(0)},${y(0)}Z`} />}
              <path class="line" d={pathFor(s.values, x, y)} />
            </g>
          ))}
          {shown.map((m) => (
            <g class="mark" key={m.at}>
              <line x1={xAt(m.at)} x2={xAt(m.at)} y1={M.top} y2={M.top + h} />
              <title>{markText(m)}</title>
            </g>
          ))}
          {hover !== null && (
            <g>
              <line class="crosshair" x1={x(hover)} x2={x(hover)} y1={M.top} y2={M.top + h} />
              {series.map((s) => (
                <circle class={`dot ${s.cls ?? ""}`} style={s.color ? { fill: `var(${s.color})` } : undefined} cx={x(hover)} cy={y(s.values[hover] ?? 0)} r={4.5} key={s.label} />
              ))}
            </g>
          )}
          <rect x={M.left} y={M.top} width={w} height={h} fill="transparent" />
        </svg>
      )}
      {hover !== null && width > 0 && (
        <Tooltip
          left={Math.min(x(hover) + 12, width - 170)} title={xLabel(xs[hover])} series={series} at={hover} format={yFormat}
          marks={marksBetween(shown, xs[hover], xs[hover] + step)}
        />
      )}
    </div>
  );
}

/** Stacked bars (bottom-up in series order) with a 2px gap between segments. */
export function StackedBars({
  labels, series, height = 200, label, tickLabel = (l: string) => l, titleFor = (l: string) => l,
}: {
  labels: string[]; series: Series[]; height?: number; label: string;
  tickLabel?: (l: string) => string; titleFor?: (l: string) => string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const n = labels.length;
  const totals = labels.map((_, i) => series.reduce((sum, s) => sum + (s.values[i] ?? 0), 0));
  const ticks = niceTicks(Math.max(1, ...totals));
  const top = ticks[ticks.length - 1];
  const w = Math.max(0, width - M.left - M.right);
  const h = height - M.top - M.bottom;
  const slot = n ? w / n : 0;
  const bw = Math.max(2, Math.min(28, slot * 0.62));
  const y = (v: number) => M.top + h - (v / top) * h;
  const tickEvery = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(w / 70))));

  return (
    <div class="chart" ref={ref}>
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label={label} onMouseLeave={() => setHover(null)}>
          <g class="grid">{ticks.map((t) => <line x1={M.left} x2={M.left + w} y1={y(t)} y2={y(t)} key={t} />)}</g>
          <g class="axis">
            {ticks.map((t) => <text x={M.left - 8} y={y(t) + 4} text-anchor="end" key={t}>{num(t, true)}</text>)}
            {labels.map((l, i) => (i % tickEvery === 0 ? <text x={M.left + slot * i + slot / 2} y={height - 6} text-anchor="middle" key={l}>{tickLabel(l)}</text> : null))}
          </g>
          {labels.map((l, i) => {
            let base = 0;
            const cx = M.left + slot * i + slot / 2;
            return (
              <g key={l} onMouseEnter={() => setHover(i)}>
                <rect x={M.left + slot * i} y={M.top} width={slot} height={h} fill="transparent" />
                {series.map((s, si) => {
                  const v = s.values[i] ?? 0;
                  if (v <= 0) return null;
                  const y0 = y(base);
                  base += v;
                  const y1 = y(base);
                  const gap = si > 0 ? 2 : 0;
                  return (
                    <rect
                      key={s.label}
                      class={`${s.cls === "s-failed" ? "bar bar-failed" : "bar"}${hover === i ? " on" : ""}`}
                      x={cx - bw / 2}
                      y={y1}
                      width={bw}
                      height={Math.max(1, y0 - y1 - gap)}
                      rx={Math.min(3, bw / 3)}
                    />
                  );
                })}
              </g>
            );
          })}
          <line class="baseline" x1={M.left} x2={M.left + w} y1={y(0)} y2={y(0)} />
        </svg>
      )}
      {hover !== null && width > 0 && (
        <Tooltip left={Math.min(M.left + slot * hover + slot / 2 + 12, width - 170)} title={titleFor(labels[hover])} series={series} at={hover} format={(v) => num(v)} />
      )}
    </div>
  );
}

/** Latency histogram: one sequential hue, bucket labels on the x-axis. */
export function Histogram({ buckets, height = 200 }: { buckets: { le: number | null; count: number }[]; height?: number }) {
  const labels = buckets.map((b, i) => (b.le === null ? `> ${fmtMs(buckets[i - 1]?.le ?? 0)}` : `≤ ${fmtMs(b.le)}`));
  const first = buckets.findIndex((b) => b.count > 0);
  if (first < 0) return <div class="chart-empty" style={{ height: `${height}px` }}>{t("No executions in this window")}</div>;
  // Trim empty tails so the shape is readable, keeping one bucket of context
  // on each side (slice clamps the end for us).
  const last = buckets.findLastIndex((b) => b.count > 0);
  const from = Math.max(0, first - 1);
  const to = last + 2;
  return (
    <StackedBars
      label={t("Execution time histogram")}
      labels={labels.slice(from, to)}
      series={[{ label: t("Jobs"), cls: "s-processed", values: buckets.slice(from, to).map((b) => b.count) }]}
      height={height}
      tickLabel={(l) => l.replace("≤ ", "")}
      titleFor={(l) => t("Took {time}", { time: l })}
    />
  );
}

function fmtMs(v: number): string {
  return v >= 1000 ? `${v / 1000}s` : `${v}ms`;
}
