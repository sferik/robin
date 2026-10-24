import { Link } from "../components/link";
import { Empty } from "../components/ui";
import { t, tj } from "../i18n";

export function NotFound() {
  return (
    <section class="panel">
      <Empty title={t("There's nothing at this address")} icon="search">
        {tj("The page may have moved. {link}.", { link: <Link href="/">{t("Go to the dashboard")}</Link> })}
      </Empty>
    </section>
  );
}
