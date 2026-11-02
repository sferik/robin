import { Empty } from "./ui";

export function FeatureMissing({ title, hint }: { title: string; hint: string }) {
  return (
    <section class="panel">
      <Empty title={title} icon="gem">{hint}</Empty>
    </section>
  );
}
