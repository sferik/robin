import { Fragment } from "preact";
import { useState } from "preact/hooks";
import type { Job, Progress } from "../api";
import { enc } from "../api";
import { act, post } from "../actions";
import { Link } from "./link";
import { Backtrace, JobClass, Jid, JsonView, Tags, Time } from "./ui";
import { can } from "../state";
import { navigate } from "../router";
import { t } from "../i18n";
import { fixed, num } from "../format";

/**
 * What a running job reported with progress!: a bar and its message, or,
 * when the job can't tell how far along it is, a moving bar and what it
 * has done.
 */
export function JobProgress({ progress }: { progress: Progress }) {
  const { pct, msg } = progress;
  const iterations = progress.meta?.iterations;
  return (
    <>
      {pct === null ? (
        <div class="progress progress-unknown" role="progressbar" aria-valuemin={0} aria-valuemax={100}><span class="p-run" /></div>
      ) : (
        <div class="progress" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}><span class="p-ok" style={{ width: `${pct}%` }} /></div>
      )}
      <div class="progress-label">
        <span>{msg ?? (typeof iterations === "number" ? t("{n} done", { n: num(iterations) }) : "")}</span>
        <span class="num">{pct === null ? "" : t("{pct}%", { pct: fixed(pct, Number.isInteger(pct) ? 0 : 1) })}</span>
      </div>
    </>
  );
}

/** A job's facts. `where` describes where it is; `when` labels its time ("Next retry"; "Runs" by default). */
export function JobFacts({ job, where, when }: { job: Job; where?: string; when?: string }) {
  return (
    <dl class="kv">
      <dt>{t("Job")}</dt><dd><JobClass name={job.class} wrapper={job.wrapper} /></dd>
      <dt>{t("Job ID")}</dt><dd><Jid jid={job.jid} /></dd>
      <dt>{t("Queue")}</dt><dd><Link href={`/queues/${enc(job.queue)}`}>{job.queue}</Link></dd>
      {where && <><dt>{t("Where it is")}</dt><dd>{where}</dd></>}
      {job.at && <><dt>{when ?? t("Runs")}</dt><dd><Time at={job.at} /></dd></>}
      <dt>{t("Created")}</dt><dd><Time at={job.created_at} /></dd>
      {job.enqueued_at && <><dt>{t("Enqueued")}</dt><dd><Time at={job.enqueued_at} /></dd></>}
      {job.failures ? <><dt>{t("Failures")}</dt><dd class="num">{job.failures}</dd></> : null}
      {job.failed_at && <><dt>{t("First failed")}</dt><dd><Time at={job.failed_at} /></dd></>}
      {job.retried_at && <><dt>{t("Last failed")}</dt><dd><Time at={job.retried_at} /></dd></>}
      {job.bid && <><dt>{t("Batch")}</dt><dd><Link href={`/batches/${enc(job.bid)}`} class="mono">{job.bid}</Link></dd></>}
      {job.tags.length > 0 && <><dt>{t("Tags")}</dt><dd><Tags tags={job.tags} /></dd></>}
      {job.info?.map((row) => (
        <Fragment key={row.label}>
          <dt>{row.label}</dt>
          <dd>{row.href ? <a href={row.href} rel="noopener noreferrer">{row.text}</a> : row.text}</dd>
        </Fragment>
      ))}
    </dl>
  );
}

export function JobError({ job }: { job: Job }) {
  if (!job.error_class) return null;
  return (
    <section class="stack mt">
      <div class="error-box">
        <span class="err">{job.error_class}</span>
        <span class="err-msg">{job.error_message}</span>
      </div>
      {job.backtrace && job.backtrace.length > 0 && (
        <div>
          <h2>{t("Backtrace")}</h2>
          <Backtrace lines={job.backtrace} />
        </div>
      )}
    </section>
  );
}

/** Edit the arguments of a failed job and run it again. */
export function EditArgs({ set, job, onDone }: { set: string; job: Job; onDone: () => void }) {
  const [text, setText] = useState(JSON.stringify(job.args, null, 2));
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    let args: unknown;
    try {
      args = JSON.parse(text);
    } catch (e) {
      setError(t("That isn't valid JSON: {error}", { error: (e as Error).message }));
      return;
    }
    if (!Array.isArray(args)) {
      setError(t("Arguments must be a JSON array, like [1, \"two\"]."));
      return;
    }
    setError(null);
    const r = await act(() => post<{ jid: string }>(`sets/${set}/${enc(job.id!)}/edit`, { args }), (r) => t("Enqueued with new arguments as {jid}", { jid: r.jid }));
    if (r) {
      onDone();
      navigate(`/jobs/${enc(r.jid)}`);
    }
  };
  return (
    <div class="panel panel-pad mt">
      <h2>{t("Edit arguments and retry")}</h2>
      <p class="subtitle mb">{t("The job is removed from this set and pushed again with a new job ID and a clean failure count.")}</p>
      <textarea aria-label={t("Job arguments as JSON")} class="input" spellcheck={false} value={text} onInput={(e) => setText((e.target as HTMLTextAreaElement).value)} />
      {error && <p class="err small" role="alert">{error}</p>}
      <div class="btn-group mt">
        <button class="btn btn-primary" onClick={save}>{t("Retry with these arguments")}</button>
        <button class="btn" onClick={onDone}>{t("Cancel")}</button>
      </div>
    </div>
  );
}

export function Payload({ job }: { job: Job }) {
  if (!job.payload) return null;
  return (
    <section class="mt">
      <h2>{t("Payload")}</h2>
      <JsonView value={job.payload} />
    </section>
  );
}

export function CancelButton({ jid }: { jid: string }) {
  if (!can("cancel")) return null;
  return (
    <button class="btn" onClick={() => act(() => post(`jobs/${enc(jid)}/cancel`), t("Cancellation requested"), {
      title: t("Cancel this job?"), body: t("If it hasn't started, it's skipped. If it's running, cancelled? turns true so it can stop early."),
      action: t("Cancel job"), danger: true,
    })}>{t("Cancel job")}</button>
  );
}
