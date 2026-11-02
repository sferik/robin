import { useState } from "preact/hooks";

/** Checkbox selection over the rows currently on screen. */
export function useSelection(ids: string[]) {
  const [picked, setPicked] = useState<ReadonlySet<string>>(new Set());
  // Rows that scrolled off (or were deleted) drop out of the selection.
  const selected = new Set(ids.filter((id) => picked.has(id)));
  const all = ids.length > 0 && selected.size === ids.length;
  return {
    selected,
    count: selected.size,
    all,
    has: (id: string) => selected.has(id),
    toggle: (id: string) => {
      setPicked((s) => {
        const next = new Set(s);
        if (!next.delete(id)) next.add(id);
        return next;
      });
    },
    toggleAll: () => {
      setPicked(all ? new Set() : new Set(ids));
    },
    clear: () => {
      setPicked(new Set());
    },
  };
}
