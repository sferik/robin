import type { ComponentChildren, HTMLAttributes, TargetedMouseEvent } from "preact";
import { href as fullHref, navigate } from "../router";

type Props = { href: string; children: ComponentChildren; onClick?: (e: TargetedMouseEvent<HTMLAnchorElement>) => void } &
  Omit<HTMLAttributes<HTMLAnchorElement>, "href" | "onClick">;

/** An in-app link: plain clicks navigate without reloading; modified clicks open as usual. */
export function Link({ href, children, onClick, ...rest }: Props) {
  return (
    <a
      href={fullHref(href)}
      {...rest}
      onClick={(e) => {
        onClick?.(e);
        if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        e.preventDefault();
        navigate(href);
      }}
    >
      {children}
    </a>
  );
}
