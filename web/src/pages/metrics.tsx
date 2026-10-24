import { useState } from "preact/hooks";
import type { Point } from "../api";
import type { Mark } from "../components/charts";
import { Histogram, LineChart, Legend, outcomes, outcomeSeries } from "../components/charts";
import { Link } from "../components/link";
import { Empty, Loading, Problem } from "../components/ui";
import { fixed, ms, num, stampToMs } from "../format";
import { useResource } from "../state";
import { locale, N_, t, tn } from "../i18n";

interface MetricsData { classes: Record<string, { s: number; f: number; ms: number; avg_ms: number }>; series: Point[]; deploys?: Mark[] }
interface QueueHistory { points: { t: string; queues: Record<string, { size: number; latency: number }> }[] }

// `summary` is filled with the execution count and the failure phrase.
const WINDOWS = [
  { key: "1h", label: N_("1 hour"), summary: N_("{count} executions in the last hour, {failed}."), path: "metrics", params: { minutes: 60 }, hourly: false },
  { key: "8h", label: N_("8 hours"), summary: N_("{count} executions in the last 8 hours, {failed}."), path: "metrics", params: { minutes: 480 }, hourly: false },
  { key: "7d", label: N_("7 days"), summary: N_("{count} executions in the last 7 days, {failed}."), path: "metrics/history", params: { hours: 168 }, hourly: true },
  { key: "30d", label: N_("30 days"), summary: N_("{count} executions in the last 30 days, {failed}."), path: "metrics/history", params: { hours: 720 }, hourly: true },
] as const;

const total = (c: { s: number; f: number }) => c.s + c.f;

/** "2.0% failed", "0.10% failed" or "none failed". */
function failedPhrase(counts: { s: number; f: number }): string {
  if (!counts.f) return t("none failed");
  const rate = counts.f / total(counts);
  return t("{pct}% failed", { pct: fixed(rate * 100, rate < 0.01 ? 2 : 1) });
}

const SERIES_VARS = ["--series-1", "--series-2", "--series-3", "--series-4", "--series-5"];

function timeLabel(hourly: boolean) {
  return (t: number) =>
    hourly
      ? new Date(t).toLocaleString(locale(), { month: "short", day: "numeric", hour: "2-digit" })
      : new Date(t).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
}

function QueueSizes({ hourly }: { hourly: boolean }) {
  const res = useResource<QueueHistory>("metrics/queues", { granularity: hourly ? "hour" : "minute", points: hourly ? 168 : 60 }, 60);
  if (!res.data) return <Loading rows={3} />;
  const pts = res.data.points;
  const peak: Record<string, number> = {};
  for (const p of pts) for (const [q, v] of Object.entries(p.queues)) peak[q] = Math.max(peak[q] ?? 0, v.size);
  // Fixed order by name keeps a queue's color stable across refreshes.
  const top = Object.entries(peak).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([q]) => q).sort();
  if (Object.values(peak).every((v) => v === 0)) {
    return <div class="chart-empty" style={{ height: "180px" }}>{t("Queue sizes are sampled once a minute by the leader process.")}</div>;
  }
  const series = top.map((q, i) => ({ label: q, color: SERIES_VARS[i], values: pts.map((p) => (q in p.queues ? p.queues[q].size : 0)) }));
  return (
    <>
      <div class="mb"><Legend series={series} /></div>
      <LineChart label={t("Queue size over time")} xs={pts.map((p) => stampToMs(p.t))} xLabel={timeLabel(hourly)} series={series} height={200} />
      {Object.keys(peak).length > 5 && <p class="small dim mt">{t("Showing the five queues with the largest peaks.")}</p>}
    </>
  );
}

export function Metrics() {
  const [win, setWin] = useState<(typeof WINDOWS)[number]["key"]>("1h");
  const [filter, setFilter] = useState("");
  const w = WINDOWS.find((x) => x.key === win)!;
  const res = useResource<MetricsData>(w.path, w.params, w.hourly ? 300 : 30);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data && !w.hourly ? { ...res.data, series: res.data.series.slice(0, -1) } : res.data;
  const classes = d
    ? Object.entries(d.classes).filter(([k]) => k.toLowerCase().includes(filter.toLowerCase())).sort((a, b) => total(b[1]) - total(a[1]))
    : [];
  const totals = d ? Object.values(d.classes).reduce((t, c) => ({ s: t.s + c.s, f: t.f + c.f }), { s: 0, f: 0 }) : { s: 0, f: 0 };

  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Metrics")}</h1>
          {d && <p class="subtitle">{t(w.summary, { count: num(total(totals)), failed: failedPhrase(totals) })}</p>}
        </div>
        <span class="spacer" />
        <div class="seg" role="group" aria-label={t("Time window")}>
          {WINDOWS.map((x) => <button aria-pressed={x.key === win} onClick={() => setWin(x.key)} key={x.key}>{t(x.label)}</button>)}
        </div>
      </div>

      <section class="panel mb">
        <div class="panel-head">
          <h2>{t("Executions")}</h2>
          <span class="panel-note">{w.hourly ? t("per hour") : t("per minute")}</span>
          <span class="spacer" />
          <Legend series={outcomes()} />
        </div>
        <div class="panel-pad">
          {!d ? <Loading rows={4} /> : (
            <LineChart
              label={t("Executions over time")}
              xs={d.series.map((p) => stampToMs(p.t))}
              xLabel={timeLabel(w.hourly)}
              series={outcomeSeries(d.series.map((p) => p.s), d.series.map((p) => p.f))}
              marks={d.deploys}
            />
          )}
        </div>
      </section>

      <div class="grid-3-1">
        <section class="panel">
          <div class="panel-head">
            <h2>{t("Jobs")}</h2>
            <span class="spacer" />
            <input class="input" type="search" placeholder={t("Filter by class")} aria-label={t("Filter by class")} value={filter} onInput={(e) => setFilter((e.target as HTMLInputElement).value)} />
          </div>
          <div class="mt" />
          {!d ? <Loading /> : classes.length === 0 ? (
            <Empty title={filter ? t("No classes match") : t("No jobs ran in this window")} icon="metrics">{t("Metrics are flushed by each process every few seconds.")}</Empty>
          ) : (
            <div class="table-wrap">
              <table class="table">
                <thead>
                  <tr>
                    <th>{t("Job")}</th><th class="r">{t("Succeeded")}</th><th class="r">{t("Failed")}</th><th class="r">{t("Avg time")}</th><th class="r">{t("Total time")}</th>
                  </tr>
                </thead>
                <tbody>
                  {classes.map(([k, c]) => (
                    <tr key={k}>
                      <td class="cls"><Link href={`/metrics/jobs/${encodeURIComponent(k)}`}>{k}</Link></td>
                      <td class="r">{num(c.s)}</td>
                      <td class={`r${c.f ? "" : " muted"}`}>{num(c.f)}</td>
                      <td class="r">{ms(c.avg_ms)}</td>
                      <td class="r">{ms(c.ms)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
        <section class="panel">
          <div class="panel-head"><h2>{t("Queue sizes")}</h2></div>
          <div class="panel-pad"><QueueSizes hourly={w.hourly} /></div>
        </section>
      </div>
    </>
  );
}

interface JobMetrics { class: string; minutes: number; series: Point[]; deploys?: Mark[]; totals: { s: number; f: number; ms: number; avg_ms: number }; histogram: { le: number | null; count: number }[] }

export function MetricsJob({ klass }: { klass: string }) {
  const [minutes, setMinutes] = useState(60);
  const res = useResource<JobMetrics>(`metrics/jobs/${encodeURIComponent(klass)}`, { minutes }, 30);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data && { ...res.data, series: res.data.series.slice(0, -1) };
  const runs = d ? total(d.totals) : 0;
  return (
    <>
      <div class="page-head">
        <div>
          <div class="crumb"><Link href="/metrics">{t("Metrics")}</Link></div>
          <h1>{klass}</h1>
          {d && (
            <p class="subtitle">
              {tn("{count} executions in the last hour, averaging {time}", "{count} executions in the last {n} hours, averaging {time}", minutes / 60, {
                count: num(runs), time: ms(d.totals.avg_ms),
              })}
              {d.totals.f ? t(", {n} failed", { n: num(d.totals.f) }) : ""}{t(".")}
            </p>
          )}
        </div>
        <span class="spacer" />
        <div class="seg" role="group" aria-label={t("Time window")}>
          {[60, 240, 480].map((m) => <button aria-pressed={minutes === m} onClick={() => setMinutes(m)} key={m}>{t("{n} h", { n: m / 60 })}</button>)}
        </div>
      </div>
      {!d ? <Loading rows={8} /> : (
        <div class="grid-2">
          <section class="panel">
            <div class="panel-head">
              <h2>{t("Executions")}</h2><span class="spacer" />
              <Legend series={outcomes()} />
            </div>
            <div class="panel-pad">
              <LineChart
                label={t("{job} executions per minute", { job: klass })}
                xs={d.series.map((p) => stampToMs(p.t))}
                xLabel={timeLabel(false)}
                series={outcomeSeries(d.series.map((p) => p.s), d.series.map((p) => p.f))}
                marks={d.deploys}
              />
            </div>
          </section>
          <section class="panel">
            <div class="panel-head"><h2>{t("Execution time")}</h2><span class="panel-note">{t("How long each run took")}</span></div>
            <div class="panel-pad"><Histogram buckets={d.histogram} height={220} /></div>
          </section>
          <section class="panel">
            <div class="panel-head"><h2>{t("Average time")}</h2><span class="panel-note">{t("per minute")}</span></div>
            <div class="panel-pad">
              <LineChart
                label={t("{job} average execution time per minute", { job: klass })}
                xs={d.series.map((p) => stampToMs(p.t))}
                xLabel={timeLabel(false)}
                yFormat={(v) => ms(v)}
                series={[{ label: t("Average"), cls: "s-processed", values: d.series.map((p) => (total(p) ? p.ms / total(p) : 0)) }]}
                marks={d.deploys}
              />
            </div>
          </section>
        </div>
      )}
    </>
  );
}
