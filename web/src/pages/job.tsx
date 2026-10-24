import type { Job, Progress } from "../api";
import { enc } from "../api";
import { CancelButton, JobError, JobFacts, JobProgress, Payload } from "../components/job_detail";
import { Link } from "../components/link";
import { Empty, Loading, Problem } from "../components/ui";
import { useResource } from "../state";
import { setMeta } from "./sets";
import { t } from "../i18n";

interface Lookup {
  jid: string;
  results: { where: string; queue?: string; identity?: string; thread?: string; job: Job }[];
  progress: Progress | null;
  cancelled: boolean;
}

export function JobLookup({ jid }: { jid: string }) {
  const res = useResource<Lookup>(`jobs/${enc(jid)}`, {}, 5);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  if (!res.data) return <Loading rows={8} />;
  const d = res.data;
  const hit = d.results.at(0);
  return (
    <>
      <div class="page-head">
        <div>
          <div class="crumb">{t("Job lookup")}</div>
          <h1>{hit ? hit.job.class : t("Job not found")}</h1>
          <p class="subtitle mono">{jid}</p>
        </div>
        <span class="spacer" />
        {hit && hit.where !== "dead" && <CancelButton jid={jid} />}
      </div>
      {d.cancelled && <p class="notice mb">{t("Cancellation was requested for this job.")}</p>}
      {!hit ? (
        <section class="panel">
          <Empty title={t("No job with that ID right now")} icon="search">
            {t("It may have finished (finished jobs aren't kept), or it lives in a queue too large to search. Check the ID and try again.")}
          </Empty>
        </section>
      ) : (
        d.results.map((r) => {
          const set = setMeta(r.where);
          const where =
            r.where === "busy" ? t("Running on {process}", { process: r.identity! }) : r.where === "queue" ? t("Waiting in {queue}", { queue: r.queue! })
              : set ? t(set.title) : r.where;
          return (
            <div class="grid-3-1 mb" key={r.where}>
              <div>
                {d.progress && r.where === "busy" && (
                  <section class="panel panel-pad mb">
                    <h2>{t("Progress")}</h2>
                    <JobProgress progress={d.progress} />
                  </section>
                )}
                {r.job.id && set && (
                  <p class="mb"><Link href={`/sets/${r.where}/${enc(r.job.id)}`}>{t("Open in {set} to retry, edit or delete it", { set: t(set.title) })}</Link></p>
                )}
                <JobError job={r.job} />
                <Payload job={r.job} />
              </div>
              <section class="panel panel-pad" style={{ alignSelf: "start" }}>
                <h2>{t("Details")}</h2>
                <JobFacts job={r.job} where={where} when={set && t(set.when)} />
              </section>
            </div>
          );
        })
      )}
    </>
  );
}
