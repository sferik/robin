// Stroke icons drawn on a 20×20 grid with angular joins, to echo the mascot.
import type { SVGAttributes } from "preact";

const paths = {
  dashboard: "M3 11 L10 4 L17 11 M5 9.5 V16 H15 V9.5",
  busy: "M3 10 H6 L8 5 L12 15 L14 10 H17",
  queues: "M4 5 H16 M4 10 H16 M4 15 H11",
  scheduled: "M10 4 A6 6 0 1 0 10.01 4 M10 6.5 V10 L12.5 11.5",
  retries: "M4.5 9 A5.5 5.5 0 0 1 15 7 M15 3.5 V7 H11.5 M15.5 11 A5.5 5.5 0 0 1 5 13 M5 16.5 V13 H8.5",
  dead: "M5 5 L15 15 M15 5 L5 15",
  metrics: "M4 16 V9 M8 16 V5 M12 16 V11 M16 16 V7",
  batches: "M4 6 L10 3 L16 6 L10 9 Z M4 10 L10 13 L16 10 M4 14 L10 17 L16 14",
  limiters: "M3.5 13 A6.5 6.5 0 0 1 16.5 13 M10 13 L13.5 8.5",
  cron: "M4 6 H16 V16 H4 Z M4 9 H16 M7 4 V7 M13 4 V7 M8 12.5 L9.5 14 L12.5 11",
  settings: "M10 7.5 A2.5 2.5 0 1 0 10.01 7.5 M10 2.8 V5 M10 15 V17.2 M2.8 10 H5 M15 10 H17.2 M4.9 4.9 L6.5 6.5 M13.5 13.5 L15.1 15.1 M4.9 15.1 L6.5 13.5 M13.5 6.5 L15.1 4.9",
  search: "M8.5 4 A4.5 4.5 0 1 0 8.51 4 M12 12 L16 16",
  sun: "M10 7 A3 3 0 1 0 10.01 7 M10 2.5 V4 M10 16 V17.5 M2.5 10 H4 M16 10 H17.5 M4.7 4.7 L5.8 5.8 M14.2 14.2 L15.3 15.3 M4.7 15.3 L5.8 14.2 M14.2 5.8 L15.3 4.7",
  moon: "M15.5 12.5 A6 6 0 0 1 7.5 4.5 A6 6 0 1 0 15.5 12.5 Z",
  check: "M4 10.5 L8 14.5 L16 5.5",
  alert: "M10 3 L18 16.5 H2 Z M10 8 V11.5 M10 13.8 V14",
  menu: "M3 6 H17 M3 10 H17 M3 14 H17",
  gem: "M6 4 H14 L17 8 L10 16 L3 8 Z M3 8 H17 M8 4 L10 8 L12 4 M10 8 V16",
  profiles: "M3 16 H17 M4 13 H16 M5 10 H11 M6 7 H9 M12 10 H15 M7 4 H8",
  extension: "M4 4 H9 V7 A1.5 1.5 0 0 0 9 10 V16 H4 Z M11 4 H16 V9 H13 A1.5 1.5 0 0 0 11 9 Z M11 11 H16 V16 H11 Z",
  download: "M10 3 V12 M6 8.5 L10 12.5 L14 8.5 M4 16 H16",
} as const;

export type IconName = keyof typeof paths;

export function Icon({ name, title, ...rest }: { name: IconName; title?: string } & SVGAttributes<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="miter" aria-hidden={title ? undefined : "true"} role={title ? "img" : undefined} {...rest}>
      {title && <title>{title}</title>}
      <path d={paths[name]} />
    </svg>
  );
}
