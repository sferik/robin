import type { CronJob } from "../api";
import { enc } from "../api";
import { act, post } from "../actions";
import { FeatureMissing } from "../components/feature";
import { Link } from "../components/link";
import { Empty, JobClass, Jid, Loading, Problem, Time } from "../components/ui";
import { argsPreview, splitIdentity } from "../format";
import { can, useResource } from "../state";
import { t, tj } from "../i18n";

function runNow(j: CronJob, reload: () => void) {
  return act(() => post<{ jid: string }>(`cron/${enc(j.id)}/enqueue`), (r) => t("Enqueued {job} as {jid}", { job: j.class, jid: r.jid })).then(reload);
}

function togglePause(j: CronJob, reload: () => void) {
  return act(() => post(`cron/${enc(j.id)}/${j.paused ? "unpause" : "pause"}`), j.paused ? t("Resumed {job}", { job: j.class }) : t("Paused {job}", { job: j.class })).then(reload);
}

function Actions({ j, reload }: { j: CronJob; reload: () => void }) {
  return (
    <div class="btn-group">
      {can("enqueue") && <button class="btn btn-small" onClick={() => runNow(j, reload)}>{t("Run now")}</button>}
      {can("pause") && <button class="btn btn-small" onClick={() => togglePause(j, reload)}>{j.paused ? t("Resume") : t("Pause")}</button>}
    </div>
  );
}

export function Cron() {
  const res = useResource<{ available: boolean; jobs?: CronJob[]; leader?: string | null }>("cron", {}, 15);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;
  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Cron")}</h1>
          <p class="subtitle">
            {d?.leader
              ? tj("Jobs pushed on a schedule by the cluster leader, currently {leader}.", { leader: <strong>{splitIdentity(d.leader).host}</strong> })
              : t("Jobs pushed on a schedule by the cluster leader.")}
          </p>
        </div>
      </div>
      {!d ? <section class="panel"><Loading /></section> : !d.available ? (
        <FeatureMissing title={t("Cron jobs aren't available on this server")} hint={t("This server's Robin version doesn't include periodic jobs.")} />
      ) : (d.jobs ?? []).length === 0 ? (
        <section class="panel">
          <Empty title={t("No cron jobs registered")} icon="cron">
            {tj("Register them inside {block} with {code}.", {
              block: <code>configure_server</code>, code: <code>{'config.periodic { |cron| cron.register "0 * * * *", "HourlyJob" }'}</code>,
            })}
          </Empty>
        </section>
      ) : (
        <section class="panel">
          <div class="table-wrap">
            <table class="table">
              <thead><tr><th>{t("Schedule")}</th><th>{t("Job")}</th><th>{t("Next run")}</th><th>{t("Last run")}</th><th /></tr></thead>
              <tbody>
                {d.jobs!.map((j) => (
                  <tr key={j.id}>
                    <td>
                      <Link href={`/cron/${enc(j.id)}`} class="mono">{j.cron}</Link>
                      {j.tz && <span class="dim small"> {j.tz}</span>}
                      {j.description && <div class="small dim">{j.description}</div>}
                    </td>
                    <td><JobClass name={j.class} /> <span class="dim small">{t("in {queue}", { queue: j.queue })}</span>{j.args.length ? <div class="args">{argsPreview(j.args, 60)}</div> : null}</td>
                    <td>{j.paused ? <span class="badge amber">{t("Paused")}</span> : <Time at={j.next_at} />}</td>
                    <td><Time at={j.last_at} /></td>
                    <td class="r"><Actions j={j} reload={res.reload} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </>
  );
}

export function CronDetail({ id }: { id: string }) {
  const res = useResource<{ job?: CronJob; history?: { at: number; jid: string }[] }>(`cron/${enc(id)}`, {}, 15);
  if (res.error && !res.data) {
    return (
      <>
        <div class="crumb"><Link href="/cron">{t("Cron")}</Link></div>
        <Problem message={res.error} onRetry={res.reload} />
      </>
    );
  }
  if (!res.data) return <Loading rows={8} />;
  if (!res.data.job) return <FeatureMissing title={t("Cron jobs aren't available on this server")} hint={t("This server's Robin version doesn't include periodic jobs.")} />;
  const j = res.data.job;
  const history = res.data.history ?? [];
  return (
    <>
      <div class="page-head">
        <div>
          <div class="crumb"><Link href="/cron">{t("Cron")}</Link></div>
          <h1>{j.class}</h1>
          <p class="subtitle">
            <span class="mono">{j.cron}</span>{j.tz ? ` ${t("in {zone}", { zone: j.tz })}` : ""}{j.description ? `, ${j.description}` : ""}
          </p>
        </div>
        <span class="spacer" />
        <Actions j={j} reload={res.reload} />
      </div>
      <div class="grid-3-1">
        <section class="panel">
          <div class="panel-head"><h2>{t("Recent runs")}</h2></div>
          {history.length === 0 ? <Empty title={t("Hasn't run yet")} icon="cron">{t("Runs show up here once the leader enqueues this job.")}</Empty> : (
            <div class="table-wrap">
              <table class="table">
                <thead><tr><th>{t("Enqueued")}</th><th>{t("Job ID")}</th></tr></thead>
                <tbody>
                  {history.map((h) => (
                    <tr key={h.jid}>
                      <td><Time at={h.at} /></td>
                      <td><Link href={`/jobs/${enc(h.jid)}`} class="mono small">{h.jid}</Link></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
        <section class="panel panel-pad" style={{ alignSelf: "start" }}>
          <h2>{t("Details")}</h2>
          <dl class="kv">
            <dt>{t("Queue")}</dt><dd><Link href={`/queues/${enc(j.queue)}`}>{j.queue}</Link></dd>
            <dt>{t("Arguments")}</dt><dd class="args">{argsPreview(j.args)}</dd>
            <dt>{t("Next run")}</dt><dd>{j.paused ? t("Paused") : <Time at={j.next_at} />}</dd>
            <dt>{t("Last run")}</dt><dd><Time at={j.last_at} /></dd>
            {j.last_jid && <><dt>{t("Last job")}</dt><dd><Jid jid={j.last_jid} /></dd></>}
          </dl>
        </section>
      </div>
    </>
  );
}
