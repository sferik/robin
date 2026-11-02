import { render } from "preact";
import "./styles.css";
import { extensionTitle, Layout } from "./components/layout";
import { ConfirmDialog, Problem, Toasts } from "./components/ui";
import { match, useRoute } from "./router";
import { applyTheme, loadSession, sessionStore, startLive, useStore } from "./state";
import { localeStore, N_, preferredLocale, setLocale, t } from "./i18n";
import { Dashboard } from "./pages/dashboard";
import { Busy } from "./pages/busy";
import { QueueList, QueueDetail } from "./pages/queues";
import { SetPage, SetEntryPage } from "./pages/sets";
import { JobLookup } from "./pages/job";
import { Metrics, MetricsJob } from "./pages/metrics";
import { BatchDetail, Batches } from "./pages/batches";
import { Limiters } from "./pages/limiters";
import { Cron, CronDetail } from "./pages/cron";
import { Settings } from "./pages/settings";
import { Profiles } from "./pages/profiles";
import { Extension } from "./pages/extension";
import { NotFound } from "./pages/not_found";
import { useEffect, useState } from "preact/hooks";

type Route = [string, (p: Record<string, string>) => preact.JSX.Element];

const ROUTES: Route[] = [
  // Stryker disable next-line StringLiteral: match() ignores trailing slashes, so "" and "/" are the same pattern
  ["/", () => <Dashboard />],
  ["/busy", () => <Busy />],
  ["/queues", () => <QueueList />],
  ["/queues/:name", (p) => <QueueDetail name={p.name} />],
  ["/scheduled", () => <SetPage set="scheduled" />],
  ["/retries", () => <SetPage set="retries" />],
  ["/dead", () => <SetPage set="dead" />],
  ["/sets/:set/:id", (p) => <SetEntryPage set={p.set} id={p.id} />],
  ["/jobs/:jid", (p) => <JobLookup jid={p.jid} />],
  ["/metrics", () => <Metrics />],
  ["/metrics/jobs/:klass", (p) => <MetricsJob klass={p.klass} />],
  ["/batches", () => <Batches />],
  ["/batches/:bid", (p) => <BatchDetail bid={p.bid} />],
  ["/limiters", () => <Limiters />],
  ["/cron", () => <Cron />],
  ["/cron/:id", (p) => <CronDetail id={p.id} />],
  ["/profiles", () => <Profiles />],
  ["/ext/:slug", (p) => <Extension slug={p.slug} />],
  ["/settings", () => <Settings />],
];

const TITLES: Record<string, string | undefined> = {
  "/": N_("Dashboard"), "/busy": N_("Busy"), "/queues": N_("Queues"), "/scheduled": N_("Scheduled"), "/retries": N_("Retries"),
  "/dead": N_("Dead"), "/metrics": N_("Metrics"), "/batches": N_("Batches"), "/limiters": N_("Rate limits"), "/cron": N_("Cron"),
  "/profiles": N_("Profiles"), "/settings": N_("Settings"),
};

function App() {
  const { path } = useRoute();
  const session = useStore(sessionStore);
  const { code } = useStore(localeStore); // re-renders everything in a new language
  const [error, setError] = useState<string | null>(null);

  // Stryker disable ArrayDeclaration: any constant dependency list means "run once"
  useEffect(() => {
    loadSession().then(startLive, (e: unknown) => setError((e as Error).message));
  }, []);
  // Stryker restore ArrayDeclaration

  useEffect(() => {
    const base = session?.title ?? "Robin";
    const extension = match("/ext/:slug", path) && session?.extensions?.find((e) => `/ext/${encodeURIComponent(e.slug)}` === path);
    const known = TITLES[path] ?? TITLES[`/${path.split("/")[1]}`];
    const section = known ? t(known) : extension && extensionTitle(extension);
    document.title = section ? `${section} | ${base}` : base;
  }, [path, session, code]);

  if (error) {
    return (
      <div style={{ padding: "40px", maxWidth: "640px" }}>
        <Problem message={t("Robin couldn't load: {error}", { error })} onRetry={() => location.reload()} />
      </div>
    );
  }
  if (!session) return null;

  let page = <NotFound />;
  for (const [pattern, view] of ROUTES) {
    const params = match(pattern, path);
    if (params) {
      page = view(params);
      break;
    }
  }
  return (
    <>
      <Layout>{page}</Layout>
      <Toasts />
      <ConfirmDialog />
    </>
  );
}

applyTheme();
// The first render waits for the language, so English never flashes first.
void setLocale(preferredLocale(), false).finally(() => render(<App />, document.getElementById("app")!));
