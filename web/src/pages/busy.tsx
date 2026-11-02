import { useEffect, useState } from "preact/hooks";
import type { ProcessInfo, Work } from "../api";
import { act, post } from "../actions";
import { N_, t, tj, tn } from "../i18n";
import { JobProgress } from "../components/job_detail";
import { Link } from "../components/link";
import { Empty, JobClass, Jid, Loading, Problem, Tags, Time } from "../components/ui";
import { argsPreview, bytesKb, fixed, num, splitIdentity } from "../format";
import { can, useResource } from "../state";
import { enc } from "../api";
import { setQuery, useRoute } from "../router";

interface BusyData { processes: ProcessInfo[]; work: Work[]; leader: string | null }

/** What the page shows: ?only=processes or ?only=jobs narrows it to one section. */
const SHOW = [[undefined, N_("All")], ["processes", N_("Processes")], ["jobs", N_("Running jobs")]] as const;

function signal(identity: string | null, sig: "quiet" | "stop" | "dump", reload: () => void) {
  const host = identity && splitIdentity(identity).host;
  const path = identity ? `processes/${enc(identity)}/${sig}` : `processes/${sig}`;
  const confirm =
    sig === "stop"
      ? {
        title: host ? t("Stop {host}?", { host }) : t("Stop every process?"),
        body: t("Running jobs get the shutdown timeout to finish; unfinished jobs go back on their queues."), action: t("Stop"), danger: true,
      }
      : sig === "quiet"
        ? {
          title: host ? t("Quiet {host}?", { host }) : t("Quiet every process?"),
          body: t("It finishes the jobs it's running but won't start new ones. This can't be undone without restarting it."), action: t("Quiet"),
        }
        : undefined;
  const done = sig === "dump" ? t("Thread dump requested; check the process logs") : sig === "quiet" ? t("Quiet signal sent") : t("Stop signal sent");
  return act(() => post(path), done, confirm).then(reload);
}

/** The most threads a capsule may be resized to (the API's limit too). */
const MAX_THREADS = 1000;

/** GVL contention (percent) at which the busy page flags a process. */
const GVL_HIGH = 50;

/** A capsule's thread count, which a user with process control can change. */
function Resize({ identity, capsule, concurrency, label, reload }: {
  identity: string; capsule: string; concurrency: number; label: string; reload: () => void;
}) {
  const [value, setValue] = useState(String(concurrency));
  // A new heartbeat's count replaces whatever was typed; polls with the same count leave it be.
  useEffect(() => setValue(String(concurrency)), [concurrency]);
  const n = Number(value);
  const valid = Number.isInteger(n) && n >= 1 && n <= MAX_THREADS;
  return (
    <form
      class="resize"
      onSubmit={(e) => {
        e.preventDefault();
        void act(() => post(`processes/${enc(identity)}/resize`, { concurrency: n, capsule }), t("Resize requested; the new thread count shows at the next heartbeat")).then(reload);
      }}
    >
      <label>
        {label}{" "}
        <input class="input" type="number" min={1} max={MAX_THREADS} step={1} required value={value} onInput={(e) => setValue((e.target as HTMLInputElement).value)} />
      </label>
      <button class="btn btn-small" type="submit" disabled={!valid || n === concurrency}>{t("Apply")}</button>
    </form>
  );
}

/** How much threads waited for Ruby's global VM lock, with a status word when it's high. */
function Gvl({ pct }: { pct: number }) {
  const shown = fixed(pct, 0);
  if (pct >= GVL_HIGH) {
    return <span class="lat-warn" title={t("Threads often wait for the GVL; CPU-heavy jobs may run better with fewer threads or more processes")}>{t("{pct}% high", { pct: shown })}</span>;
  }
  return <>{t("{pct}%", { pct: shown })}</>;
}

function Process({ p, reload }: { p: ProcessInfo; reload: () => void }) {
  const { host, pid } = splitIdentity(p.identity);
  const control = can("process_control");
  const capsules = Object.entries(p.capsules ?? { default: { concurrency: p.concurrency, queues: {} } });
  return (
    <div class="proc">
      <div>
        <div class="proc-name">
          {host}<span class="dim">:{pid}</span> {p.leader && <span class="badge egg" title={t("Runs cron and recovery for the cluster")}>{t("Leader")}</span>}{" "}
          {p.quiet && <span class="badge amber">{t("Quiet")}</span>} {p.embedded && <span class="badge">{t("Embedded")}</span>}
        </div>
        <div class="proc-meta">
          {p.tag && <><strong>{p.tag}</strong>, </>}
          {tj("working {queues}, started {time}", { queues: p.queues.join(", "), time: <Time at={p.started_at} /> })}
        </div>
        <div class="threads" aria-label={tn("{busy} of {n} thread busy", "{busy} of {n} threads busy", p.concurrency, { busy: p.busy })}>
          {Array.from({ length: Math.min(p.concurrency, 64) }, (_, i) => <i class={i < p.busy ? "on" : ""} key={i} />)}
        </div>
        {control && !p.quiet && (
          <div class="resizes">
            {capsules.map(([name, c]) => (
              <Resize identity={p.identity} capsule={name} concurrency={c.concurrency} reload={reload} key={name}
                label={capsules.length === 1 ? t("Threads") : t("{capsule} threads", { capsule: name })} />
            ))}
          </div>
        )}
      </div>
      <div><div class="proc-k">{t("Busy")}</div><div class="proc-v">{p.busy} / {p.concurrency}</div></div>
      <div><div class="proc-k">{t("Memory")}</div><div class="proc-v">{bytesKb(p.rss_kb)}</div></div>
      <div class="proc-hide"><div class="proc-k">{t("Redis RTT")}</div><div class="proc-v">{p.rtt_us ? t("{n} ms", { n: fixed(p.rtt_us / 1000, 1) }) : "–"}</div></div>
      <div class="proc-hide">
        {p.gvl_contention != null && (
          <>
            <div class="proc-k" title={t("Share of the last heartbeat interval threads spent waiting for Ruby's global VM lock (GVL)")}>{t("GVL wait")}</div>
            <div class="proc-v"><Gvl pct={p.gvl_contention} /></div>
          </>
        )}
      </div>
      <div class="proc-hide"><div class="proc-k">{t("Heartbeat")}</div><div class="proc-v"><Time at={p.beat} /></div></div>
      <div class="btn-group">
        {control && <button class="btn btn-small" onClick={() => signal(p.identity, "dump", reload)} title={t("Log every thread's backtrace")}>{t("Dump threads")}</button>}
        {control && !p.quiet && <button class="btn btn-small" onClick={() => signal(p.identity, "quiet", reload)}>{t("Quiet")}</button>}
        {control && <button class="btn btn-small btn-danger" onClick={() => signal(p.identity, "stop", reload)}>{t("Stop")}</button>}
      </div>
    </div>
  );
}

export function Busy() {
  const res = useResource<BusyData>("busy", {}, 3);
  const { query } = useRoute();
  const only = SHOW.find(([key]) => key && key === query.get("only"))?.[0];
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;
  const threads = d?.processes.reduce((s, p) => s + p.concurrency, 0) ?? 0;
  const busy = d?.processes.reduce((s, p) => s + p.busy, 0) ?? 0;
  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Busy")}</h1>
          {d && (
            <p class="subtitle">
              {t("{processes} running {busy} of {threads}.", {
                processes: tn("{n} process", "{n} processes", d.processes.length), busy: num(busy), threads: tn("{n} thread", "{n} threads", threads),
              })}
            </p>
          )}
        </div>
        <span class="spacer" />
        <div class="seg" role="group" aria-label={t("Show")}>
          {SHOW.map(([key, label]) => <button aria-pressed={only === key} onClick={() => setQuery({ only: key })} key={label}>{t(label)}</button>)}
        </div>
        {can("process_control") && d && d.processes.length > 0 && (
          <div class="btn-group">
            <button class="btn" onClick={() => signal(null, "quiet", res.reload)}>{t("Quiet all")}</button>
            <button class="btn btn-danger" onClick={() => signal(null, "stop", res.reload)}>{t("Stop all")}</button>
          </div>
        )}
      </div>

      {only !== "jobs" && <section class="panel mb">
        <div class="panel-head"><h2>{t("Processes")}</h2></div>
        {!d ? <Loading /> : d.processes.length === 0 ? (
          <Empty title={t("No processes are running")} icon="busy">
            {tj("Start one with {command} and it shows up here within a few seconds.", { command: <code>bundle exec robin</code> })}
          </Empty>
        ) : (
          <div class="proc-list">{d.processes.map((p) => <Process p={p} reload={res.reload} key={p.identity} />)}</div>
        )}
      </section>}

      {only !== "processes" && <section class="panel">
        <div class="panel-head"><h2>{t("Running jobs")}</h2></div>
        {!d ? <Loading /> : d.work.length === 0 ? (
          <Empty title={t("All threads are idle")} icon="check">{t("Jobs appear here while they run, with live progress if they report it.")}</Empty>
        ) : (
          <div class="table-wrap">
            <table class="table">
              <thead><tr><th>{t("Job")}</th><th>{t("Arguments")}</th><th>{t("Progress")}</th><th>{t("Process")}</th><th>{t("Started")}</th><th /></tr></thead>
              <tbody>
                {d.work.map((w) => (
                  <tr key={w.job.jid}>
                    <td>
                      <JobClass name={w.job.class} wrapper={w.job.wrapper} /> <Tags tags={w.job.tags} />
                      <div><Jid jid={w.job.jid} /> <span class="dim small">{tj("in {queue}", { queue: <Link href={`/queues/${enc(w.queue)}`}>{w.queue}</Link> })}</span></div>
                    </td>
                    <td class="args">{argsPreview(w.job.args)}</td>
                    <td style={{ minWidth: "160px" }}>
                      {w.progress ? <JobProgress progress={w.progress} /> : <span class="dim">–</span>}
                    </td>
                    <td class="small">{splitIdentity(w.identity).host}<div class="dim">{w.thread}</div></td>
                    <td><Time at={w.run_at} /></td>
                    <td class="r">
                      {can("cancel") && (
                        <button class="btn btn-small" onClick={() => act(() => post(`jobs/${enc(w.job.jid)}/cancel`), t("Cancellation requested"), {
                          title: t("Cancel {job}?", { job: w.job.class }), body: t("The job sees cancelled? turn true and should stop at its next check."),
                          action: t("Cancel job"), danger: true,
                        })}>{t("Cancel")}</button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>}
    </>
  );
}
