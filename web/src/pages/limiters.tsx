import type { Limiter } from "../api";
import { enc } from "../api";
import { act, del, post } from "../actions";
import { FeatureMissing } from "../components/feature";
import { Empty, Loading, Problem, Time } from "../components/ui";
import { duration, num, pct } from "../format";
import { can, useResource } from "../state";
import { N_, t } from "../i18n";

const PERIODS: Record<number, string> = { 1: N_("per second"), 60: N_("per minute"), 3600: N_("per hour"), 86400: N_("per day") };
const per = (seconds: number) => (Object.hasOwn(PERIODS, seconds) ? t(PERIODS[seconds]) : t("per {time}", { time: duration(seconds) }));

const TYPE_LABEL: Record<string, string> = {
  concurrent: N_("Concurrent"), bucket: N_("Bucket"), window: N_("Sliding window"), leaky: N_("Leaky bucket"), points: N_("Points"),
};

export function Limiters() {
  const res = useResource<{ available: boolean; limiters?: Limiter[] }>("limiters", {}, 5);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;
  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Rate limits")}</h1>
          <p class="subtitle">{t("Shared limits that keep jobs from overwhelming APIs and databases. Jobs over a limit are rescheduled, not failed.")}</p>
        </div>
      </div>
      {!d ? <section class="panel"><Loading /></section> : !d.available ? (
        <FeatureMissing title={t("Rate limits aren't available on this server")} hint={t("This server's Robin version doesn't include rate limiting.")} />
      ) : (d.limiters ?? []).length === 0 ? (
        <section class="panel"><Empty title={t("No rate limiters yet")} icon="limiters">{t("They appear here the first time a job calls one, e.g. Robin::Limiter.concurrent(\"stripe\", 10).")}</Empty></section>
      ) : (
        <section class="panel">
          <div class="table-wrap">
            <table class="table">
              <thead><tr><th>{t("Limiter")}</th><th>{t("Kind")}</th><th style={{ width: "26%" }}>{t("In use")}</th><th class="r">{t("Times over limit")}</th><th>{t("Last used")}</th><th /></tr></thead>
              <tbody>
                {d.limiters!.map((l) => {
                  const used = l.used ?? 0;
                  const full = used >= l.limit;
                  return (
                    <tr key={l.name}>
                      <td class="cls">{l.name}</td>
                      <td>{Object.hasOwn(TYPE_LABEL, l.type) ? t(TYPE_LABEL[l.type]) : l.type}{l.interval ? <span class="dim"> {per(l.interval)}</span> : null}</td>
                      <td>
                        <div class="qbar" aria-hidden="true"><span style={{ width: `${pct(used, l.limit)}%`, background: full ? "var(--ruby)" : "var(--egg)" }} /></div>
                        <div class="small"><span class="num">{t("{used} of {limit}", { used: num(used), limit: num(l.limit) })}</span>{full && <span class="err"> {t("at limit")}</span>}</div>
                      </td>
                      <td class="r">{num(l.over_limit_count ?? 0)}</td>
                      <td><Time at={l.last_used_at} /></td>
                      <td class="r">
                        {can("limiters") && (
                          <div class="btn-group">
                            <button class="btn btn-small" onClick={() => act(() => post(`limiters/${enc(l.name)}/reset`), t("Reset {limiter}", { limiter: l.name }), {
                              title: t("Reset {limiter}?", { limiter: l.name }), body: t("Its current usage is cleared, so waiting jobs may run right away."), action: t("Reset"),
                            }).then(res.reload)}>{t("Reset")}</button>
                            <button class="btn btn-small btn-danger" onClick={() => act(() => del(`limiters/${enc(l.name)}`), t("Deleted {limiter}", { limiter: l.name }), {
                              title: t("Delete {limiter}?", { limiter: l.name }), body: t("Its state and statistics are removed. It's recreated the next time a job uses it."),
                              action: t("Delete"), danger: true,
                            }).then(res.reload)}>{t("Delete")}</button>
                          </div>
                        )}
                      </td>
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
