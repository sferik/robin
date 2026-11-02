import type { Profile } from "../api";
import { apiUrl, enc } from "../api";
import { act, del } from "../actions";
import { Icon } from "../components/icons";
import { Link } from "../components/link";
import { Empty, Loading, Problem, Time } from "../components/ui";
import { fixed, ms } from "../format";
import { t, tj } from "../i18n";
import { can, useResource } from "../state";

export function size(bytes: number): string {
  if (bytes < 1024) return t("{n} B", { n: bytes });
  if (bytes < 1024 * 1024) return t("{n} KB", { n: fixed(bytes / 1024, 1) });
  return t("{n} MB", { n: fixed(bytes / 1024 / 1024, 1) });
}

export function Profiles() {
  const res = useResource<{ profiles: Profile[] }>("profiles", {}, 15);
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const profiles = res.data?.profiles;
  return (
    <>
      <div class="page-head">
        <div>
          <h1>{t("Profiles")}</h1>
          <p class="subtitle">
            {tj("Where single job runs spent their time. Download one and drop it onto the {profiler} to explore it.", {
              profiler: <a href="https://profiler.firefox.com" target="_blank" rel="noreferrer">Firefox Profiler</a>,
            })}
          </p>
        </div>
      </div>
      <section class="panel">
        {!profiles ? <Loading /> : profiles.length === 0 ? (
          <Empty title={t("No profiles yet")} icon="profiles">
            {tj("Push a job with {code} (servers need the vernier gem) and its run shows up here for a week.", { code: <code>{"set(profile: true)"}</code> })}
          </Empty>
        ) : (
          <div class="table-wrap">
            <table class="table">
              <thead>
                <tr>
                  <th>{t("Job")}</th><th>{t("Label")}</th><th class="r">{t("Took")}</th><th>{t("Result")}</th><th>{t("Recorded")}</th><th class="r">{t("Size")}</th><th />
                </tr>
              </thead>
              <tbody>
                {profiles.map((p) => (
                  <tr key={p.jid}>
                    <td>
                      <Link href={`/metrics/jobs/${enc(p.class)}`} class="cls">{p.class}</Link>
                      <div class="dim small mono">{p.jid}{p.queue && <> · {p.queue}</>}</div>
                    </td>
                    <td>{p.label ?? <span class="dim">–</span>}</td>
                    <td class="r num">{ms(p.duration_ms)}</td>
                    <td>{p.ok ? <span class="badge egg">{t("Succeeded")}</span> : <span class="badge ruby">{t("Failed")}</span>}</td>
                    <td><Time at={p.started_at} /></td>
                    <td class="r num">{size(p.bytes)}</td>
                    <td class="r">
                      <div class="btn-group">
                        <a class="btn btn-small" href={apiUrl(`profiles/${enc(p.jid)}`)} download={`robin-${p.jid}.json`}>
                          <Icon name="download" width={14} height={14} /> {t("Download")}
                        </a>
                        {can("profiles") && (
                          <button class="btn btn-small btn-danger" onClick={() => act(() => del(`profiles/${enc(p.jid)}`), t("Profile deleted"), {
                            title: t("Delete this profile?"), body: t("The profile of {job} ({jid}) is removed.", { job: p.class, jid: p.jid }),
                            action: t("Delete"), danger: true,
                          }).then(res.reload)}>{t("Delete")}</button>
                        )}
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
