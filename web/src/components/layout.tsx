import type { ComponentChildren } from "preact";
import { useEffect, useState } from "preact/hooks";
import { setCluster, type ExtensionInfo, type Stats } from "../api";
import { num } from "../format";
import { locale, N_, t } from "../i18n";
import { navigate, useRoute } from "../router";
import { connectionStore, liveStore, pausedStore, sessionStore, setPaused, setTheme, themeStore, useStore } from "../state";
import { Icon, type IconName } from "./icons";
import { Link } from "./link";

export const logoSrc = document.querySelector<HTMLMetaElement>('meta[name="robin-logo"]')?.content ?? "";
const wordmarkSrc = document.querySelector<HTMLMetaElement>('meta[name="robin-wordmark"]')?.content ?? "";

interface NavItem { href: string; label: string; icon: IconName; count?: (s: Stats) => number; alert?: boolean }

const NAV: { group?: string; items: NavItem[] }[] = [
  {
    items: [
      { href: "/", label: N_("Dashboard"), icon: "dashboard" },
      { href: "/busy", label: N_("Busy"), icon: "busy", count: (s) => s.busy },
      { href: "/queues", label: N_("Queues"), icon: "queues", count: (s) => s.enqueued },
      { href: "/scheduled", label: N_("Scheduled"), icon: "scheduled", count: (s) => s.scheduled },
      { href: "/retries", label: N_("Retries"), icon: "retries", count: (s) => s.retries, alert: true },
      { href: "/dead", label: N_("Dead"), icon: "dead", count: (s) => s.dead },
    ],
  },
  {
    group: N_("Insight"),
    items: [
      { href: "/metrics", label: N_("Metrics"), icon: "metrics" },
      { href: "/batches", label: N_("Batches"), icon: "batches" },
      { href: "/limiters", label: N_("Rate limits"), icon: "limiters" },
      { href: "/cron", label: N_("Cron"), icon: "cron" },
      { href: "/profiles", label: N_("Profiles"), icon: "profiles" },
    ],
  },
];

/** An extension's title in the current language. */
export const extensionTitle = (e: ExtensionInfo): string => e.titles?.[locale()] ?? e.title;

/** The nav groups, plus a group for pages added by extensions. Labels are translated when shown. */
export function navGroups(extensions: ExtensionInfo[] = []): typeof NAV {
  if (extensions.length === 0) return NAV;
  const items = extensions.map((e) => ({ href: `/ext/${encodeURIComponent(e.slug)}`, label: extensionTitle(e), icon: "extension" as const }));
  return [...NAV, { group: N_("Extensions"), items }];
}

/** A section is current on its own page, its sub-pages, and (for job sets) its entries under /sets. */
function isCurrent(href: string, path: string): boolean {
  return path === href || path.startsWith(`${href}/`) || path.startsWith(`/sets${href}/`);
}

function Sidebar({ onNavigate }: { onNavigate: () => void }) {
  const { path } = useRoute();
  const live = useStore(liveStore);
  const session = useStore(sessionStore);
  const stats = live?.stats;
  const title = session?.title ?? "Robin";
  return (
    <aside class="side" aria-label={t("Main navigation")}>
      <Link href="/" class="brand" onClick={onNavigate}>
        {logoSrc && <img src={logoSrc} alt="" />}
        <span class="brand-name">
          {wordmarkSrc && title === "Robin" ? <img class="brand-wordmark" src={wordmarkSrc} alt="Robin" /> : title}
          <span class="brand-version">v{session?.version}</span>
        </span>
      </Link>
      <nav class="nav">
        {navGroups(session?.extensions).map((g) => (
          <>
            {g.group && <div class="nav-group">{t(g.group)}</div>}
            {g.items.map((item) => {
              const count = stats && item.count?.(stats);
              return (
                <Link href={item.href} aria-current={isCurrent(item.href, path) ? "page" : undefined} onClick={onNavigate} key={item.href}>
                  <Icon name={item.icon} />
                  {item.icon === "extension" ? item.label : t(item.label)}
                  {count !== undefined && <span class={`count${item.alert && count > 0 ? " alert" : ""}`}>{num(count, true)}</span>}
                </Link>
              );
            })}
          </>
        ))}
      </nav>
      <div class="side-foot">
        <Link href="/settings" class="row" onClick={onNavigate} aria-current={path === "/settings" ? "page" : undefined}>
          <Icon name="settings" width={15} height={15} /> {t("Settings & about")}
        </Link>
      </div>
    </aside>
  );
}

function LiveToggle() {
  const state = useStore(connectionStore);
  const paused = useStore(pausedStore);
  const label = paused ? t("Paused") : state === "live" ? t("Live") : state === "polling" ? t("Polling") : t("Offline");
  return (
    <button
      class="live"
      data-state={paused ? "paused" : state}
      aria-pressed={!paused}
      title={paused ? t("Resume live updates") : t("Pause live updates")}
      onClick={() => setPaused(!paused)}
    >
      <span class="dot" />
      {label}
    </button>
  );
}

const THEME_TITLES = { light: N_("Light theme"), system: N_("System theme"), dark: N_("Dark theme") };

function ThemeToggle() {
  const theme = useStore(themeStore);
  return (
    <div class="seg" role="group" aria-label={t("Color theme")}>
      {(["light", "system", "dark"] as const).map((name) => (
        <button aria-pressed={theme === name} onClick={() => setTheme(name)} title={t(THEME_TITLES[name])} key={name}>
          {name === "light" ? <Icon name="sun" width={15} height={15} title={t("Light")} /> : name === "dark" ? <Icon name="moon" width={15} height={15} title={t("Dark")} /> : t("Auto")}
        </button>
      ))}
    </div>
  );
}

function JobFinder() {
  const [q, setQ] = useState("");
  return (
    <form
      class="search"
      role="search"
      onSubmit={(e) => {
        e.preventDefault();
        const jid = q.trim();
        if (jid) navigate(`/jobs/${encodeURIComponent(jid)}`);
        setQ("");
      }}
    >
      <Icon name="search" />
      <input class="input" placeholder={t("Find a job by ID")} aria-label={t("Find a job by ID")} value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
    </form>
  );
}

function ClusterPicker() {
  const session = useStore(sessionStore);
  if (!session || session.clusters.length < 2) return null;
  return (
    <label class="row small">
      <span class="dim">{t("Cluster")}</span>
      <select class="select" value={session.cluster} onChange={(e) => setCluster((e.target as HTMLSelectElement).value)}>
        {session.clusters.map((c) => <option value={c} key={c}>{c}</option>)}
      </select>
    </label>
  );
}

export function Layout({ children }: { children: ComponentChildren }) {
  const { path } = useRoute();
  // The mobile menu stays open only on the page it was opened on.
  const [openOn, setOpenOn] = useState<string | null>(null);
  const open = openOn === path;
  const close = () => setOpenOn(null);
  // Stryker disable ArrayDeclaration: any constant dependency list means "run once"
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "/" && !(e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement)) {
        e.preventDefault();
        document.querySelector<HTMLInputElement>(".topbar .search input")?.focus();
      }
      if (e.key === "Escape") close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  // Stryker restore ArrayDeclaration
  return (
    <div class={`shell${open ? " nav-open" : ""}`}>
      <Sidebar onNavigate={close} />
      <main class="main" id="main">
        <div class="mobile-bar">
          <button class="btn btn-ghost" aria-label={t("Open navigation")} onClick={() => setOpenOn(path)}><Icon name="menu" /></button>
          {logoSrc && <img src={logoSrc} alt="" />}
          <strong>Robin</strong>
        </div>
        <div class="content">
          <div class="topbar">
            <JobFinder />
            <span class="spacer" />
            <ClusterPicker />
            <LiveToggle />
            <ThemeToggle />
          </div>
          {children}
        </div>
      </main>
    </div>
  );
}
