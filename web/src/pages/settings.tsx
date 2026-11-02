import { Loading, Problem } from "../components/ui";
import { logoSrc } from "../components/layout";
import { duration, fixed, num, splitIdentity } from "../format";
import { sessionStore, useResource, useStore } from "../state";
import { LOCALES, localeStore, N_, setLocale, t, tj } from "../i18n";

interface Info {
  redis: Partial<Record<string, string>>; redis_url: string; processes: number; leader: string | null;
  robin: { version: string; ruby: string; key_prefix: string; max_retries: number; dead_max_jobs: number; dead_timeout_days: number; native_resp: boolean };
}

const PERMISSION_LABELS: Record<string, string> = {
  read: N_("View the dashboard"), retry: N_("Retry and enqueue jobs"), edit: N_("Edit job arguments"), delete: N_("Delete jobs and clear queues"),
  kill: N_("Kill jobs"), pause: N_("Pause queues and cron jobs"), cancel: N_("Cancel jobs"), process_control: N_("Quiet and stop processes"),
  enqueue: N_("Run cron jobs now"), limiters: N_("Reset rate limiters"), batches: N_("Delete batches"),
  profiles: N_("Delete job profiles"), extensions: N_("Use actions on extension pages"),
};

function LanguagePicker() {
  const { code } = useStore(localeStore);
  return (
    <label class="row">
      <span class="sr-only">{t("Language")}</span>
      <select class="select" value={code} onChange={(e) => void setLocale((e.target as HTMLSelectElement).value)}>
        {Object.entries(LOCALES).map(([c, l]) => <option value={c} lang={c} key={c}>{l.name}</option>)}
      </select>
    </label>
  );
}

export function Settings() {
  const session = useStore(sessionStore)!;
  const res = useResource<Info>("info");
  if (res.error && !res.data) return <Problem message={res.error} onRetry={res.reload} />;
  const d = res.data;
  const r = d?.redis ?? {};
  const hits = Number(r.keyspace_hits ?? 0), misses = Number(r.keyspace_misses ?? 0);
  return (
    <>
      <div class="page-head">
        <div class="row" style={{ gap: "18px", alignItems: "center" }}>
          {logoSrc && <img src={logoSrc} alt={t("Robin, a red-bellied bird in a mask")} width={84} height={84} />}
          <div>
            <h1>Robin {session.version}</h1>
            <p class="subtitle">{t("Fast, reliable background jobs for Ruby. Free and open source under the LGPL.")}</p>
          </div>
        </div>
      </div>
      {!d ? <Loading rows={8} /> : (
        <div class="grid-2">
          <section class="panel panel-pad">
            <h2>Robin</h2>
            <dl class="kv">
              <dt>{t("Version")}</dt><dd>{d.robin.version}</dd>
              <dt>Ruby</dt><dd class="small">{d.robin.ruby}</dd>
              <dt>{t("Cluster")}</dt><dd>{session.cluster}</dd>
              <dt>{t("Processes")}</dt><dd>{num(d.processes)}</dd>
              <dt>{t("Leader")}</dt><dd>{d.leader ? splitIdentity(d.leader).host : t("None elected")}</dd>
              <dt>{t("Key prefix")}</dt><dd><code>{d.robin.key_prefix}</code></dd>
              <dt>{t("Default retries")}</dt><dd>{d.robin.max_retries}</dd>
              <dt>{t("Dead set")}</dt><dd>{t("{jobs} jobs, kept {days} days", { jobs: num(d.robin.dead_max_jobs), days: d.robin.dead_timeout_days })}</dd>
              <dt>{t("Protocol parser")}</dt><dd>{d.robin.native_resp ? t("Native extension") : t("Pure Ruby")}</dd>
            </dl>
          </section>
          <section class="panel panel-pad">
            <h2>Redis</h2>
            <dl class="kv">
              <dt>{t("Server")}</dt><dd><code>{d.redis_url}</code></dd>
              <dt>{t("Version")}</dt><dd>{r.redis_version ?? "–"} {r.role && <span class="dim">({r.role})</span>}</dd>
              <dt>{t("Uptime")}</dt><dd>{r.uptime_in_seconds ? duration(Number(r.uptime_in_seconds)) : "–"}</dd>
              <dt>{t("Memory")}</dt>
              <dd>{r.used_memory_human ?? "–"}{r.used_memory_peak_human && <span class="dim"> {t("(peak {memory})", { memory: r.used_memory_peak_human })}</span>}</dd>
              <dt>{t("Max memory")}</dt>
              <dd>{r.maxmemory_human === "0B" ? t("Unlimited") : r.maxmemory_human ?? "–"} {r.maxmemory_policy && <span class="dim">{r.maxmemory_policy}</span>}</dd>
              <dt>{t("Clients")}</dt><dd>{r.connected_clients ?? "–"}</dd>
              <dt>{t("Ops per second")}</dt><dd>{r.instantaneous_ops_per_sec ?? "–"}</dd>
              <dt>{t("Hit rate")}</dt><dd>{hits + misses ? t("{pct}%", { pct: fixed((hits / (hits + misses)) * 100, 1) }) : "–"}</dd>
            </dl>
            {r.maxmemory_policy && r.maxmemory_policy !== "noeviction" && (
              <p class="notice mt">
                {t("Redis may evict keys under memory pressure ({policy}). Set maxmemory-policy to noeviction so jobs are never silently dropped.", { policy: r.maxmemory_policy })}
              </p>
            )}
          </section>
          <section class="panel panel-pad">
            <h2>{t("Your access")}</h2>
            {session.read_only && <p class="notice mb">{t("This dashboard is read-only.")}</p>}
            <dl class="kv">
              {Object.entries(session.permissions).map(([k, v]) => (
                <>
                  <dt>{Object.hasOwn(PERMISSION_LABELS, k) ? t(PERMISSION_LABELS[k]) : k}</dt>
                  <dd>{v ? t("Allowed") : <span class="dim">{t("Not allowed")}</span>}</dd>
                </>
              ))}
            </dl>
          </section>
          <section class="panel panel-pad">
            <h2>{t("Language")}</h2>
            <LanguagePicker />
            <h2 class="mt">{t("Keyboard")}</h2>
            <dl class="kv">
              <dt><kbd>/</kbd></dt><dd>{t("Find a job by ID")}</dd>
              <dt><kbd>Esc</kbd></dt><dd>{t("Close dialogs and the menu")}</dd>
            </dl>
            <h2 class="mt">Prometheus</h2>
            <p class="small">
              {tj("Scrape {path} for queue sizes, latency and job counters.", { path: <code>{new URL("metrics", document.baseURI).pathname}</code> })}
            </p>
          </section>
        </div>
      )}
    </>
  );
}
