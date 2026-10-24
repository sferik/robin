import type { Job, QueueRow } from "../api";
import { enc } from "../api";
import { act, del, post } from "../actions";
import { t, tn, tnj } from "../i18n";
import { Link } from "../components/link";
import { useSelection } from "../components/selection";
import { Empty, JobClass, Jid, Latency, Loading, Pager, Problem, Tags, Time } from "../components/ui";
import { argsPreview, num } from "../format";
import { navigate, useRoute } from "../router";
import { can, liveStore, useResource, useStore } from "../state";

function pause(q: { name: string; paused: boolean }, reload: () => void) {
  return act(
    () => post(`queues/${enc(q.name)}/${q.paused ? "unpause" : "pause"}`),
    q.paused ? t("Resumed {queue}", { queue: q.name }) : t("Paused {queue}", { queue: q.name }),
    q.paused ? undefined : {
      title: t("Pause {queue}?", { queue: q.name }), body: t("Processes stop taking jobs from this queue until you resume it. Jobs can still be pushed."),
      action: t("Pause queue"),
    },
  ).then(reload);
}

function clear(name: string, size: number, after: () => void) {
  return act(() => del(`queues/${enc(name)}`), t("Cleared {queue}", { queue: name }), {
    title: t("Delete every job in {queue}?", { queue: name }),
    body: tn("{n} job will be removed for good.", "{n} jobs will be removed for good.", size), action: t("Delete all jobs"), danger: true,
  }).then((r) => r && after());
}

export function QueueList() {
  const res = useResource<{ queues: QueueRow[] }>("queues", {}, 5);
  const live = useStore(liveStore);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const queues = res.data?.queues.map((q) => ({ ...q, size: live?.queues[q.name] ?? q.size }));
  const total = queues?.reduce((s, q) => s + q.size, 0) ?? 0;
  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Queues")}</h1>
          {queues && (
            <p class="subtitle">
              {t("{jobs} waiting across {queues}.", { jobs: tn("{n} job", "{n} jobs", total), queues: tn("{n} queue", "{n} queues", queues.length) })}
            </p>
          )}
        </div>
      </div>
      <section class="panel">
        {!queues ? <Loading /> : queues.length === 0 ? (
          <Empty title={t("No queues yet")} icon="queues">{t("A queue appears as soon as a job is pushed to it.")}</Empty>
        ) : (
          <div class="table-wrap">
            <table class="table">
              <thead><tr><th>{t("Queue")}</th><th class="r">{t("Waiting")}</th><th class="r">{t("Latency")}</th><th>{t("Status")}</th><th /></tr></thead>
              <tbody>
                {queues.map((q) => (
                  <tr key={q.name}>
                    <td class="cls"><Link href={`/queues/${enc(q.name)}`}>{q.name}</Link></td>
                    <td class="r">{num(q.size)}</td>
                    <td class="r"><Latency seconds={q.latency} /></td>
                    <td>{q.paused ? <span class="badge amber">{t("Paused")}</span> : <span class="dim">{t("Running")}</span>}</td>
                    <td class="r">
                      <div class="btn-group">
                        {can("pause") && <button class="btn btn-small" onClick={() => pause(q, res.reload)}>{q.paused ? t("Resume") : t("Pause")}</button>}
                        {can("delete") && <button class="btn btn-small btn-danger" onClick={() => clear(q.name, q.size, res.reload)}>{t("Clear")}</button>}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}

interface QueuePage { queue: { name: string; size: number; latency: number; paused: boolean }; page: number; per_page: number; total: number; jobs: Job[] }

export function QueueDetail({ name }: { name: string }) {
  const { query } = useRoute();
  const page = Number(query.get("page") ?? 1) || 1;
  const res = useResource<QueuePage>(`queues/${enc(name)}`, { page }, 5);
  const jobs = res.data?.jobs ?? [];
  const sel = useSelection(jobs.map((j) => j.jid));
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;

  const deleteSelected = () =>
    act(() => post<{ deleted: number }>(`queues/${enc(name)}/delete_jobs`, { jids: [...sel.selected] }), (r) => tn("Deleted {n} job", "Deleted {n} jobs", r.deleted), {
      title: tn("Delete {n} job?", "Delete {n} jobs?", sel.count), body: t("They won't run."), action: t("Delete"), danger: true,
    }).then(() => { sel.clear(); res.reload(); });

  // When the selected jobs share a class, every job of it can go at once.
  const classes = new Set(jobs.filter((j) => sel.has(j.jid)).map((j) => j.class));
  const only = classes.size === 1 ? [...classes][0] : null;
  const deleteClass = (cls: string) =>
    act(() => post<{ deleted: number }>(`queues/${enc(name)}/delete_class`, { class: cls }), (r) => tn("Deleted {n} job", "Deleted {n} jobs", r.deleted), {
      title: t("Delete every {class} job in {queue}?", { class: cls, queue: name }),
      body: t("This takes every one in the queue, not only those on this page. They won't run."), action: t("Delete all"), danger: true,
    }).then(() => { sel.clear(); res.reload(); });

  return (
    <>
      <div class="page-head">
        <div>
          <div class="crumb"><Link href="/queues">{t("Queues")}</Link></div>
          <h1>{name}</h1>
          {d && (
            <p class="subtitle">
              {tnj("{n} job waiting. Oldest has waited {latency}.", "{n} jobs waiting. Oldest has waited {latency}.", d.queue.size, {
                latency: <Latency seconds={d.queue.latency} />,
              })}{" "}
              {d.queue.paused && <span class="badge amber">{t("Paused")}</span>}
            </p>
          )}
        </div>
        <span class="spacer" />
        {d && (
          <div class="btn-group">
            {can("pause") && <button class="btn" onClick={() => pause({ name, paused: d.queue.paused }, res.reload)}>{d.queue.paused ? t("Resume queue") : t("Pause queue")}</button>}
            {can("delete") && <button class="btn btn-danger" onClick={() => clear(name, d.queue.size, () => navigate("/queues"))}>{t("Clear queue")}</button>}
          </div>
        )}
      </div>
      <section class="panel">
        {can("delete") && jobs.length > 0 && (
          <div class="bulkbar">
            <span class="sel">{sel.count ? tn("{n} job selected", "{n} jobs selected", sel.count) : t("Select jobs to act on them")}</span>
            <span class="spacer" />
            <button class="btn btn-small btn-danger" disabled={!sel.count} onClick={deleteSelected}>{t("Delete")}</button>
            {only && <button class="btn btn-small btn-danger" onClick={() => deleteClass(only)}>{t("Delete every {class}", { class: only })}</button>}
          </div>
        )}
        {!d ? <Loading /> : jobs.length === 0 ? (
          <Empty title={t("{queue} is empty", { queue: name })} icon="check">{t("Every job pushed here has been picked up.")}</Empty>
        ) : (
          <div class="table-wrap">
            <table class="table">
              <thead>
                <tr>
                  {can("delete") && <th class="check"><input type="checkbox" aria-label={t("Select all on this page")} checked={sel.all} onChange={sel.toggleAll} /></th>}
                  <th>{t("Job")}</th><th>{t("Arguments")}</th><th>{t("Enqueued")}</th>
                </tr>
              </thead>
              <tbody>
                {jobs.map((j) => (
                  <tr key={j.jid}>
                    {can("delete") && <td class="check"><input type="checkbox" aria-label={t("Select {jid}", { jid: j.jid })} checked={sel.has(j.jid)} onChange={() => sel.toggle(j.jid)} /></td>}
                    <td><JobClass name={j.class} wrapper={j.wrapper} /> <Tags tags={j.tags} /><div><Jid jid={j.jid} /></div></td>
                    <td class="args">{j.encrypted ? <span class="badge">{t("Encrypted")}</span> : argsPreview(j.args)}</td>
                    <td><Time at={j.enqueued_at ?? j.created_at} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {d && <Pager page={d.page} perPage={d.per_page} total={d.total} />}
      </section>
    </>
  );
}
