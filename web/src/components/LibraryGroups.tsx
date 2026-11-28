import { CaretRightIcon } from "@phosphor-icons/react";
import type { ReactNode } from "react";

/** One row of the library's category list: icon, label, chevron — plain, no panel. */
export interface LibraryGroupRow {
  id: string;
  label: string;
  icon: ReactNode;
  /** In-page anchor: no new route or invented destination is needed. */
  href: string;
}

export function LibraryGroups({ rows }: { rows: LibraryGroupRow[] }) {
  return (
    <ul className="mx-4 mt-3 md:mx-6">
      {rows.map((row) => (
        <li key={row.id}>
          <a
            href={row.href}
            className="group flex min-h-[52px] items-center gap-3 px-4 transition-colors hover:bg-surface-2 active:bg-surface-3"
          >
            <span className="grid size-7 shrink-0 place-items-center text-fg-2">{row.icon}</span>
            <span className="min-w-0 flex-1 truncate text-[15px] font-medium">{row.label}</span>
            <CaretRightIcon size={15} weight="bold" className="shrink-0 text-fg-3" aria-hidden="true" />
          </a>
        </li>
      ))}
    </ul>
  );
}
