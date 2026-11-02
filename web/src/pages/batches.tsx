import type { Batch } from "../api";
import { enc } from "../api";
import { act, del, post } from "../actions";
import { t, tj, tn } from "../i18n";
import { FeatureMissing } from "../components/feature";
import { Link } from "../components/link";
import { Empty, Jid, Loading, Problem, Time } from "../components/ui";
import { num, pct } from "../format";
import { navigate, useRoute } from "../router";
import { can, useResource } from "../state";

function state(b: Batch): { label: string; cls: string } {
  if (b.success_at) return { label: t("Succeeded"), cls: "egg" };
  if (b.cancelled_at) return { label: t("Cancelled"), cls: "amber" };
  if (b.complete_at) return { label: t("Complete with failures"), cls: "ruby" };
  if (b.failures > 0) return { label: t("Running, with failures"), cls: "ruby" };
  return { label: t("Running"), cls: "" };
}

export function BatchProgress({ b }: { b: Batch }) {
  const done = Math.max(0, b.total - b.pending);
  const failing = Math.min(b.failures, b.pending);
  const waiting = Math.max(0, b.pending - failing);
  return (
    <div>
      <div class="progress" role="progressbar" aria-valuenow={Math.round(pct(done, b.total))} aria-valuemin={0} aria-valuemax={100} aria-label={t("Batch progress")}>
        {done > 0 && <span class="p-ok" style={{ width: `${pct(done, b.total)}%` }} />}
        {failing > 0 && <span class="p-fail" style={{ width: `${pct(failing, b.total)}%` }} />}
      </div>
      <div class="progress-label">
        <span>
          {failing
            ? t("{done} of {total} done, {failing} failing", { done: num(done), total: num(b.total), failing: num(failing) })
            : t("{done} of {total} done", { done: num(done), total: num(b.total) })}
        </span>
        <span class="num">{waiting ? t("{n} waiting", { n: num(waiting) }) : ""}</span>
      </div>
    </div>
  );
}

/** A batch's tags, each linking to the batches that have it. */
function BatchTags({ tags }: { tags?: string[] }) {
  return <>{tags?.map((tag) => <Link href={`/batches?tag=${encodeURIComponent(tag)}`} class="tag" key={tag}>{tag}</Link>)}</>;
}

export function Batches() {
  const tag = useRoute().query.get("tag") ?? "";
  const res = useResource<{ available: boolean; batches?: Batch[] }>("batches", tag ? { tag } : {}, 5);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;
  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Batches")}</h1>
          <p class="subtitle">
            {tag
              ? tj("Batches tagged {tag}. {all}", { tag: <span class="tag">{tag}</span>, all: <Link href="/batches">{t("Show all batches")}</Link> })
              : t("Groups of jobs tracked together, with callbacks when they complete or succeed.")}
          </p>
        </div>
      </div>
      {!d ? <section class="panel"><Loading /></section> : !d.available ? (
        <FeatureMissing title={t("Batches aren't available on this server")} hint={t("This server's Robin version doesn't include batch support.")} />
      ) : (d.batches ?? []).length === 0 ? (
        <section class="panel">
          {tag ? <Empty title={t("No batches have this tag")} icon="batches">{t("Tagged batches show up here while Robin keeps them (30 days).")}</Empty> : <Empty title={t("No batches yet")} icon="batches">
            {tj("Create one with {new} and push jobs inside {block}.", { new: <code>Robin::Batch.new</code>, block: <code>{"batch.jobs { … }"}</code> })}
          </Empty>}
        </section>
      ) : (
        <section class="panel">
          <div class="table-wrap">
            <table class="table">
              <thead><tr><th>{t("Batch")}</th><th>{t("Status")}</th><th style={{ width: "34%" }}>{t("Progress")}</th><th>{t("Created")}</th></tr></thead>
              <tbody>
                {d.batches!.map((b) => {
                  const s = state(b);
                  return (
                    <tr key={b.bid}>
                      <td>
                        <Link href={`/batches/${enc(b.bid)}`} class="cls">{b.description || t("Untitled batch")}</Link>
                        <div class="dim small mono">{b.bid}</div>
                        {b.tags && b.tags.length > 0 && <div><BatchTags tags={b.tags} /></div>}
                      </td>
                      <td><span class={`badge ${s.cls}`}>{s.label}</span></td>
                      <td><BatchProgress b={b} /></td>
                      <td><Time at={b.created_at} /></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </>
  );
}

export function BatchDetail({ bid }: { bid: string }) {
  const res = useResource<{ batch?: Batch }>(`batches/${enc(bid)}`, {}, 5);
  if (res.error && !res.data) {
    return (
      <>
        <div class="crumb"><Link href="/batches">{t("Batches")}</Link></div>
        <Problem message={res.error} onRetry={res.reload} />
      </>
    );
  }
  if (!res.data) return <Loading rows={8} />;
  if (!res.data.batch) return <FeatureMissing title={t("Batches aren't available on this server")} hint={t("This server's Robin version doesn't include batch support.")} />;
  const b = res.data.batch;
  const s = state(b);
  const children = (b.children ?? []) as (Batch | string)[];
  return (
    <>
      <div class="page-head">
        <div>
          <div class="crumb"><Link href="/batches">{t("Batches")}</Link>{b.parent_bid && <> / <Link href={`/batches/${enc(b.parent_bid)}`}>{t("parent")}</Link></>}</div>
          <h1>{b.description || t("Untitled batch")}</h1>
          <p class="subtitle"><span class={`badge ${s.cls}`}>{s.label}</span> <span class="mono small">{b.bid}</span></p>
        </div>
        <span class="spacer" />
        <div class="btn-group">
          {can("cancel") && !b.cancelled_at && !b.complete_at && (
            <button class="btn" onClick={() => act(() => post(`batches/${enc(bid)}/cancel`), t("Batch cancelled"), {
              title: t("Cancel this batch?"),
              body: t("Its jobs that haven't started are skipped, and running ones see cancelled? turn true. Child batches are cancelled too."),
              action: t("Cancel batch"), danger: true,
            }).then(res.reload)}>{t("Cancel batch")}</button>
          )}
          {can("batches") && (
            <button class="btn btn-danger" onClick={() => act(() => del(`batches/${enc(bid)}`), t("Batch deleted"), {
              title: t("Delete this batch's tracking data?"), body: t("Jobs already pushed still run, but callbacks won't fire."), action: t("Delete batch"), danger: true,
            }).then((r) => r && navigate("/batches"))}>{t("Delete")}</button>
          )}
        </div>
      </div>
      <section class="panel panel-pad mb"><BatchProgress b={b} /></section>
      <div class="grid-3-1">
        <div class="stack">
          <section class="panel">
            <div class="panel-head"><h2>{t("Failed jobs")}</h2></div>
            {(b.failed_jobs ?? []).length === 0 ? (
              <Empty title={t("No failures")} icon="check">{t("Jobs that fail at least once are listed here until they succeed.")}</Empty>
            ) : (
              <div class="table-wrap">
                <table class="table">
                  <thead><tr><th>{t("Job ID")}</th><th>{t("Error")}</th></tr></thead>
                  <tbody>
                    {b.failed_jobs!.map((f) => (
                      <tr key={f.jid}>
                        <td><Link href={`/jobs/${enc(f.jid)}`} class="mono small">{f.jid}</Link></td>
                        <td><span class="err">{f.error_class}</span><div class="err-msg">{f.error_message}</div></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          {children.length > 0 && (
            <section class="panel">
              <div class="panel-head"><h2>{t("Child batches")}</h2></div>
              <div class="table-wrap">
                <table class="table">
                  <tbody>
                    {children.map((c) => {
                      const child = typeof c === "string" ? null : c;
                      const id = typeof c === "string" ? c : c.bid;
                      return (
                        <tr key={id}>
                          <td><Link href={`/batches/${enc(id)}`}>{child?.description || id}</Link></td>
                          <td style={{ width: "50%" }}>{child && typeof child.total === "number" ? <BatchProgress b={child} /> : null}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>
          )}
        </div>
        <section class="panel panel-pad" style={{ alignSelf: "start" }}>
          <h2>{t("Details")}</h2>
          <dl class="kv">
            <dt>{t("Jobs")}</dt><dd class="num">{tn("{n} job", "{n} jobs", b.total)}</dd>
            {b.tags && b.tags.length > 0 ? <><dt>{t("Tags")}</dt><dd><BatchTags tags={b.tags} /></dd></> : null}
            <dt>{t("Pending")}</dt><dd class="num">{num(b.pending)}</dd>
            <dt>{t("Failures")}</dt><dd class="num">{num(b.failures)}</dd>
            <dt>{t("Created")}</dt><dd><Time at={b.created_at} /></dd>
            <dt>{t("Completed")}</dt><dd><Time at={b.complete_at} /></dd>
            <dt>{t("Succeeded")}</dt><dd><Time at={b.success_at} /></dd>
            {b.cancelled_at ? <><dt>{t("Cancelled")}</dt><dd><Time at={b.cancelled_at} /></dd></> : null}
            {b.callbacks && Object.keys(b.callbacks).length > 0 ? <><dt>{t("Callbacks")}</dt><dd><code class="small">{JSON.stringify(b.callbacks)}</code></dd></> : null}
          </dl>
          {b.jids && b.jids.length > 0 && (
            <>
              <h2 class="mt">{t("Pending job IDs")}</h2>
              <div class="stack" style={{ gap: "4px" }}>{b.jids.slice(0, 50).map((j) => <Jid jid={j} key={j} />)}</div>
            </>
          )}
        </section>
      </div>
    </>
  );
}
