import { useState } from "preact/hooks";
import type { Job } from "../api";
import { enc } from "../api";
import { act, post } from "../actions";
import { N_, t, tn } from "../i18n";
import { EditArgs, JobError, JobFacts, Payload } from "../components/job_detail";
import type { IconName } from "../components/icons";
import { Link } from "../components/link";
import { useSelection } from "../components/selection";
import { Empty, JobClass, Jid, JsonView, Loading, Pager, Problem, SearchBox, Tags, Time } from "../components/ui";
import { argsPreview } from "../format";
import { navigate, setQuery, useRoute } from "../router";
import { can, useResource } from "../state";

// Text is marked with N_ and translated where it's shown.
interface SetMeta {
  title: string; path: string; when: string; empty: string; emptyBody: string; noMatch: string; retryLabel: string; kill: boolean; edit: boolean; icon: IconName;
}

export type SetName = "scheduled" | "retries" | "dead";

export const SET_META: Record<SetName, SetMeta> = {
  scheduled: {
    title: N_("Scheduled"), path: "/scheduled", when: N_("Runs"), empty: N_("Nothing is scheduled"),
    emptyBody: N_("Jobs pushed with perform_in or perform_at wait here until their time comes."),
    noMatch: N_("Nothing in scheduled contains “{q}”. Search matches anywhere in the job's JSON."),
    retryLabel: N_("Enqueue now"), kill: true, edit: false, icon: "scheduled",
  },
  retries: {
    title: N_("Retries"), path: "/retries", when: N_("Next retry"), empty: N_("No jobs are waiting to retry"),
    emptyBody: N_("Failed jobs wait here with exponential backoff before they run again."),
    noMatch: N_("Nothing in retries contains “{q}”. Search matches anywhere in the job's JSON."),
    retryLabel: N_("Retry now"), kill: true, edit: true, icon: "check",
  },
  dead: {
    title: N_("Dead"), path: "/dead", when: N_("Died"), empty: N_("No dead jobs"),
    emptyBody: N_("Jobs that run out of retries land here so you can inspect and replay them."),
    noMatch: N_("Nothing in dead contains “{q}”. Search matches anywhere in the job's JSON."),
    retryLabel: N_("Retry now"), kill: false, edit: true, icon: "check",
  },
};

type Action = "retry" | "delete" | "kill";

/** "Retried 3 jobs" and the like, for `count` jobs of a set. */
function doneMessage(set: SetName, action: Action, count: number): string {
  if (action === "delete") return tn("Deleted {n} job", "Deleted {n} jobs", count);
  if (action === "kill") return tn("Killed {n} job", "Killed {n} jobs", count);
  return set === "scheduled" ? tn("Enqueued {n} job", "Enqueued {n} jobs", count) : tn("Retried {n} job", "Retried {n} jobs", count);
}

interface SetData { page: number; per_page: number; total: number; query: string; jobs: Job[] }

/** The set called `name`, if there is one. */
export function setMeta(name: string): SetMeta | undefined {
  return Object.hasOwn(SET_META, name) ? SET_META[name as SetName] : undefined;
}

export function SetPage({ set }: { set: SetName }) {
  const meta = SET_META[set];
  const { query } = useRoute();
  const page = Number(query.get("page") ?? 1) || 1;
  const q = query.get("q") ?? "";
  const res = useResource<SetData>(`sets/${set}`, { page, q }, 10);
  const jobs = res.data?.jobs ?? [];
  const sel = useSelection(jobs.map((j) => j.id!));
  const failures = set !== "scheduled";
  const canAct = can("retry") || can("delete") || (meta.kill && can("kill"));

  const bulk = (action: Action) => {
    const n = sel.count;
    return act(() => post<{ affected: number }>(`sets/${set}/bulk`, { action, ids: [...sel.selected] }), (r) => doneMessage(set, action, r.affected),
      action === "retry" ? undefined : {
        title: action === "delete" ? tn("Delete {n} job?", "Delete {n} jobs?", n) : tn("Kill {n} job?", "Kill {n} jobs?", n),
        body: action === "delete" ? t("They won't run again.") : t("They move to the dead set without running again."),
        action: action === "delete" ? t("Delete") : t("Kill"), danger: true,
      }).then(() => { sel.clear(); res.reload(); });
  };

  const enqueue = set === "scheduled";
  const allLabel = { retry: enqueue ? t("Enqueue all") : t("Retry all"), delete: t("Delete all"), kill: t("Kill all") };

  const all = (action: Action) => {
    const total = res.data!.total; // these buttons only show once the set has loaded
    const title = {
      retry: enqueue ? tn("Enqueue all {n} job?", "Enqueue all {n} jobs?", total) : tn("Retry all {n} job?", "Retry all {n} jobs?", total),
      delete: tn("Delete all {n} job?", "Delete all {n} jobs?", total),
      kill: tn("Kill all {n} job?", "Kill all {n} jobs?", total),
    }[action];
    const body = {
      retry: t("Every job in this set is pushed onto its queue right away."),
      delete: t("Every job in this set is removed for good."),
      kill: t("Every job in this set moves to the dead set."),
    }[action];
    return act(() => post<{ affected: number }>(`sets/${set}/all`, { action }), (r) => doneMessage(set, action, r.affected), {
      title, body, action: allLabel[action], danger: action !== "retry",
    }).then(res.reload);
  };

  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;

  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t(meta.title)}</h1>
          {d && <p class="subtitle">{q ? tn("{n} job matching “{q}”.", "{n} jobs matching “{q}”.", d.total, { q }) : tn("{n} job.", "{n} jobs.", d.total)}</p>}
        </div>
        <span class="spacer" />
        <SearchBox value={q} placeholder={t("Search class, args, error…")} onSearch={(v) => setQuery({ q: v, page: undefined })} />
      </div>
      <section class="panel">
        {canAct && d && d.total > 0 && (
          <div class="bulkbar">
            <span class="sel">{sel.count ? tn("{n} job selected", "{n} jobs selected", sel.count) : t("Select jobs, or act on the whole set")}</span>
            <span class="spacer" />
            {sel.count > 0 ? (
              <>
                {can("retry") && <button class="btn btn-small" onClick={() => bulk("retry")}>{t(meta.retryLabel)}</button>}
                {meta.kill && can("kill") && <button class="btn btn-small" onClick={() => bulk("kill")}>{t("Kill")}</button>}
                {can("delete") && <button class="btn btn-small btn-danger" onClick={() => bulk("delete")}>{t("Delete")}</button>}
              </>
            ) : (
              <>
                {can("retry") && <button class="btn btn-small" onClick={() => all("retry")}>{allLabel.retry}</button>}
                {meta.kill && can("kill") && <button class="btn btn-small" onClick={() => all("kill")}>{allLabel.kill}</button>}
                {can("delete") && <button class="btn btn-small btn-danger" onClick={() => all("delete")}>{allLabel.delete}</button>}
              </>
            )}
          </div>
        )}
        {!d ? <Loading /> : jobs.length === 0 ? (
          q ? <Empty title={t("No matches")} icon="search">{t(meta.noMatch, { q })}</Empty>
            : <Empty title={t(meta.empty)} icon={meta.icon}>{t(meta.emptyBody)}</Empty>
        ) : (
          <div class="table-wrap">
            <table class="table">
              <thead>
                <tr>
                  {canAct && <th class="check"><input type="checkbox" aria-label={t("Select all on this page")} checked={sel.all} onChange={sel.toggleAll} /></th>}
                  <th>{t(meta.when)}</th><th>{t("Job")}</th><th>{t("Arguments")}</th>{failures && <th>{t("Error")}</th>}{failures && <th class="r">{t("Failures")}</th>}
                </tr>
              </thead>
              <tbody>
                {jobs.map((j) => (
                  <tr key={j.id}>
                    {canAct && <td class="check"><input type="checkbox" aria-label={t("Select {jid}", { jid: j.jid })} checked={sel.has(j.id!)} onChange={() => sel.toggle(j.id!)} /></td>}
                    <td><Link href={`/sets/${set}/${enc(j.id!)}`}><Time at={j.at} /></Link></td>
                    <td><JobClass name={j.class} wrapper={j.wrapper} /> <Tags tags={j.tags} /><div><Jid jid={j.jid} /> <span class="dim small">{j.queue}</span></div></td>
                    <td class="args">{j.encrypted ? <span class="badge">{t("Encrypted")}</span> : argsPreview(j.args, 90)}</td>
                    {failures && (
                      <td>
                        <Link href={`/sets/${set}/${enc(j.id!)}`} class="err">{j.error_class}</Link>
                        <div class="err-msg">{(j.error_message ?? "").slice(0, 140)}</div>
                      </td>
                    )}
                    {failures && <td class="r">{j.failures ?? 0}</td>}
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

export function SetEntryPage({ set, id }: { set: string; id: string }) {
  const meta = setMeta(set);
  const res = useResource<{ job: Job }>(`sets/${set}/${enc(id)}`);
  const [editing, setEditing] = useState(false);
  if (!meta) return <Problem message={t("There's no \"{set}\" set.", { set })} />;
  if (res.error) {
    return (
      <>
        <div class="crumb"><Link href={meta.path}>{t(meta.title)}</Link></div>
        <Problem message={res.error} />
      </>
    );
  }
  if (!res.data) return <Loading rows={10} />;
  const job = res.data.job;
  const back = () => navigate(meta.path);
  const done = { retry: set === "scheduled" ? t("Job enqueued") : t("Job retried"), delete: t("Job deleted"), kill: t("Job killed") };
  const run = (action: Action, confirm?: { title: string; action: string }) =>
    act(() => post(`sets/${set}/bulk`, { action, ids: [id] }), done[action], confirm && { ...confirm, danger: true }).then((r) => r && back());

  return (
    <>
      <div class="page-head">
        <div>
          <div class="crumb"><Link href={meta.path}>{t(meta.title)}</Link></div>
          <h1>{job.class}</h1>
          <p class="subtitle"><Jid jid={job.jid} /></p>
        </div>
        <span class="spacer" />
        <div class="btn-group">
          {can("retry") && <button class="btn btn-primary" onClick={() => run("retry")}>{t(meta.retryLabel)}</button>}
          {meta.edit && can("edit") && !job.encrypted && <button class="btn" onClick={() => setEditing(true)}>{t("Edit arguments")}</button>}
          {meta.kill && can("kill") && <button class="btn" onClick={() => run("kill", { title: t("Kill job?"), action: t("Kill job") })}>{t("Kill")}</button>}
          {can("delete") && <button class="btn btn-danger" onClick={() => run("delete", { title: t("Delete job?"), action: t("Delete job") })}>{t("Delete")}</button>}
        </div>
      </div>
      {editing && <EditArgs set={set} job={job} onDone={() => setEditing(false)} />}
      <div class="grid-3-1 mt">
        <div>
          <section class="panel panel-pad">
            <h2>{t("Arguments")}</h2>
            {job.encrypted ? <p class="dim">{t("These arguments are encrypted at rest and can't be shown.")}</p> : <JsonView value={job.args} />}
          </section>
          <JobError job={job} />
          <Payload job={job} />
        </div>
        <section class="panel panel-pad" style={{ alignSelf: "start" }}>
          <h2>{t("Details")}</h2>
          <JobFacts job={job} where={t(meta.title)} when={t(meta.when)} />
        </section>
      </div>
    </>
  );
}
