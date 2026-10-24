import { useState } from "preact/hooks";
import type { Point, QueueRow, Stats } from "../api";
import { LineChart, Legend, outcomes, outcomeSeries, StackedBars } from "../components/charts";
import { Link } from "../components/link";
import { Latency, Problem, Loading } from "../components/ui";
import { duration, num, stampToMs } from "../format";
import { liveStore, useResource, useStore } from "../state";
import { locale, N_, t, tj, tn, tnj } from "../i18n";

interface Dashboard {
  stats: Stats; queues: QueueRow[]; history: { processed: Record<string, number>; failed: Record<string, number> };
  realtime: Point[]; leader: string | null;
}

function StatusLine({ stats, perMinute, queues }: { stats: Stats; perMinute: number | null; queues: QueueRow[] }) {
  const slowest = queues.reduce<QueueRow | null>((a, q) => (!a || q.latency > a.latency ? q : a), null);
  const parts = [];
  if (stats.processes === 0) {
    parts.push(
      <>{t("No Robin processes are running.")} </>,
      stats.enqueued > 0 ? (
        tnj("{jobs} is waiting for one to start.", "{jobs} are waiting for one to start.", stats.enqueued, {
          jobs: <Link href="/queues"><b>{tn("{n} job", "{n} jobs", stats.enqueued)}</b></Link>,
        })
      ) : (
        <>{t("Nothing is waiting, either.")}</>
      ),
    );
  } else {
    const processes = <Link href="/busy"><b>{tn("{n} process", "{n} processes", stats.processes)}</b></Link>;
    parts.push(
      <>
        {perMinute
          ? tnj("Robin is working through {rate} job a minute on {processes}", "Robin is working through {rate} jobs a minute on {processes}", perMinute, { rate: <b>{num(perMinute)}</b>, processes })
          : stats.busy > 0 ? tj("Robin is running on {processes}", { processes }) : tj("Robin is standing by on {processes}", { processes })}
        {stats.busy > 0
          ? tnj(", with {threads} thread busy right now.", ", with {threads} threads busy right now.", stats.busy, { threads: <b>{num(stats.busy)}</b> })
          : t(".")}{" "}
      </>,
    );
    if (stats.enqueued > 0 && slowest && slowest.latency >= 1) {
      parts.push(
        <>
          {tj("The oldest of {jobs} has been in {queue} for {time}.", {
            jobs: <b>{tn("{n} waiting job", "{n} waiting jobs", stats.enqueued)}</b>,
            queue: <Link href={`/queues/${encodeURIComponent(slowest.name)}`}>{slowest.name}</Link>,
            time: <b>{duration(slowest.latency)}</b>,
          })}{" "}
        </>,
      );
    }
  }
  parts.push(
    stats.retries > 0 ? (
      <>
        <Link href="/retries" class="warn">
          {tnj("{jobs} is waiting to retry", "{jobs} are waiting to retry", stats.retries, { jobs: <b>{tn("{n} job", "{n} jobs", stats.retries)}</b> })}
        </Link>{t(".")}
      </>
    ) : (
      <span class="calm">{t("Nothing is waiting to retry.")}</span>
    ),
  );
  return <p class="status-line" aria-live="polite">{parts}</p>;
}

function Facts({ stats }: { stats: Stats }) {
  const facts: [string, number, string, boolean?][] = [
    [N_("Processed"), stats.processed, "/metrics"],
    [N_("Failed"), stats.failed, "/metrics"],
    [N_("Enqueued"), stats.enqueued, "/queues"],
    [N_("Scheduled"), stats.scheduled, "/scheduled"],
    [N_("Retries"), stats.retries, "/retries", stats.retries > 0],
    [N_("Dead"), stats.dead, "/dead"],
  ];
  return (
    <div class="facts">
      {facts.map(([label, value, href, alert]) => (
        <Link href={href} class={`fact${alert ? " alert" : ""}`} key={label}>
          <span class="fact-value">{num(value, true)}</span>
          <span class="fact-label">{t(label)}</span>
        </Link>
      ))}
    </div>
  );
}

const minuteLabel = (ms: number) => new Date(ms).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });

export function Dashboard() {
  const [minutes, setMinutes] = useState(60);
  const [days, setDays] = useState(30);
  const res = useResource<Dashboard>("dashboard", { minutes, days }, 20);
  const live = useStore(liveStore);

  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  if (!res.data) return <Loading rows={8} />;
  const d = res.data;
  const stats = live?.stats ?? d.stats;
  const queues = d.queues.map((q) => ({ ...q, size: live?.queues[q.name] ?? q.size }));
  // The newest minute is still filling up; leave it out so the line doesn't dive.
  const pts = d.realtime.slice(0, -1);
  const complete = pts.at(-1);
  const perMinute = complete ? complete.s + complete.f : null;
  const xs = pts.map((p) => stampToMs(p.t));
  const dates = Object.keys(d.history.processed).sort();
  const maxQueue = Math.max(1, ...queues.map((q) => q.size));

  return (
    <>
      <h1 class="sr-only">{t("Dashboard")}</h1>
      <StatusLine stats={stats} perMinute={perMinute} queues={queues} />
      <Facts stats={stats} />

      <section class="panel mb">
        <div class="panel-head">
          <h2>{t("Throughput")}</h2>
          <span class="panel-note">{t("Jobs finished per minute")}</span>
          <span class="spacer" />
          <Legend series={outcomes()} />
          <div class="seg" role="group" aria-label={t("Time window")}>
            {[60, 240, 480].map((m) => (
              <button aria-pressed={minutes === m} onClick={() => setMinutes(m)} key={m}>{t("{n} h", { n: m / 60 })}</button>
            ))}
          </div>
        </div>
        <div class="panel-pad">
          <LineChart
            label={t("Jobs succeeded and failed per minute")}
            xs={xs}
            xLabel={minuteLabel}
            height={240}
            series={outcomeSeries(pts.map((p) => p.s), pts.map((p) => p.f))}
          />
        </div>
      </section>

      <div class="grid-3-1">
        <section class="panel">
          <div class="panel-head">
            <h2>{t("Queues")}</h2>
            <span class="spacer" />
            <Link href="/queues" class="small">{t("All queues")}</Link>
          </div>
          {queues.length === 0 ? (
            <p class="panel-pad dim">{t("No queues yet. They appear as soon as a job is pushed.")}</p>
          ) : (
            <div class="table-wrap">
              <table class="table">
                <thead>
                  <tr><th>{t("Queue")}</th><th class="r">{t("Waiting")}</th><th style={{ width: "28%" }}><span class="sr-only">{t("Relative size")}</span></th><th class="r">{t("Latency")}</th></tr>
                </thead>
                <tbody>
                  {queues.slice(0, 8).map((q) => (
                    <tr key={q.name}>
                      <td class="cls">
                        <Link href={`/queues/${encodeURIComponent(q.name)}`}>{q.name}</Link>{" "}
                        {q.paused && <span class="badge amber">{t("Paused")}</span>}
                      </td>
                      <td class="r">{num(q.size)}</td>
                      <td><div class="qbar" aria-hidden="true"><span style={{ width: `${(q.size / maxQueue) * 100}%` }} /></div></td>
                      <td class="r"><Latency seconds={q.latency} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section class="panel">
          <div class="panel-head">
            <h2>{t("Daily history")}</h2>
            <span class="spacer" />
            <div class="seg" role="group" aria-label={t("History window")}>
              {[7, 30, 90].map((n) => <button aria-pressed={days === n} onClick={() => setDays(n)} key={n}>{t("{n} d", { n })}</button>)}
            </div>
          </div>
          <div class="panel-pad">
            <StackedBars
              label={t("Jobs succeeded and failed per day")}
              labels={dates}
              tickLabel={(l) => l.slice(5).replace("-", "/")}
              titleFor={(l) => new Date(`${l}T00:00:00Z`).toLocaleDateString(locale(), { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" })}
              series={outcomeSeries(
                dates.map((k) => Math.max(0, d.history.processed[k] - (d.history.failed[k] ?? 0))),
                dates.map((k) => d.history.failed[k] ?? 0),
              )}
            />
            <div class="mt"><Legend series={outcomes()} /></div>
          </div>
        </section>
      </div>
    </>
  );
}
