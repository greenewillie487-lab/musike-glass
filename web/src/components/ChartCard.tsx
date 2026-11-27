import { MusicNotesIcon, PlayIcon } from "@phosphor-icons/react";
import { Link } from "react-router";
import { useT } from "../i18n";
import { paths } from "../lib/routes";
import type { Track } from "../lib/types";
import { Artwork } from "./Artwork";

/**
 * Apple-Music-style chart card. There is no chart endpoint in this app: the rows are the
 * listener's own real history, newest first, so nothing on the card is invented.
 */
export function ChartCard({
  tracks,
  title,
  subtitle,
  onPlay,
}: {
  tracks: Track[];
  title: string;
  subtitle: string;
  /** Plays the whole history from the tapped row, using the app's existing player. */
  onPlay: (track: Track, position: number) => void;
}) {
  const t = useT();
  const rows = tracks.slice(0, 10);
  if (!rows.length) return null;

  return (
    <section aria-label={title} className="px-4 pt-7 md:px-6">
      <div
        className="relative isolate overflow-hidden rounded-[22px] p-4 text-white shadow-[0_16px_40px_rgb(244_63_94/0.22)] ring-1 ring-white/20"
        style={{ background: "linear-gradient(135deg,#ff5f7e 0%,#f43f5e 55%,#9f1239 100%)" }}
      >
        <span className="pointer-events-none absolute -top-16 -right-12 size-52 rounded-full bg-white/15 blur-2xl" aria-hidden="true" />
        <header className="relative mb-2 flex items-start justify-between gap-3 px-2">
          <div className="min-w-0">
            <h2 className="text-[21px] leading-tight font-bold tracking-tight">{title}</h2>
            <p className="truncate text-xs text-white/80">{subtitle}</p>
          </div>
          <span className="grid size-8 shrink-0 place-items-center rounded-full bg-white/20 backdrop-blur-sm" aria-hidden="true">
            <MusicNotesIcon size={17} weight="fill" />
          </span>
        </header>

        <ol className="relative flex flex-col gap-0.5">
          {rows.map((track, i) => (
            <li key={track.id}>
              <button
                type="button"
                onClick={() => onPlay(track, i)}
                aria-label={t.common.playX(track.title)}
                title={t.common.playX(track.title)}
                className="flex w-full items-center gap-3 rounded-[14px] px-2 py-1.5 text-left transition-colors hover:bg-white/10 active:bg-white/15"
              >
                <span className="w-4 shrink-0 text-center font-mono text-[13px] font-semibold text-white/75 tabular-nums">{i + 1}</span>
                <Artwork src={track.thumb} fallback={track.art} className="size-9 shrink-0 rounded-[7px]" iconSize={14} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[13px] leading-tight font-semibold">{track.title}</span>
                  <span className="mt-0.5 block truncate text-[11px] text-white/75">{track.artist}</span>
                </span>
                <PlayIcon size={16} weight="fill" className="shrink-0 text-white/90" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ol>

        <Link
          to={paths.history}
          className="relative mt-2 inline-flex min-h-9 items-center rounded-full px-3 text-[13px] font-semibold text-white/90 transition-colors hover:bg-white/10 hover:text-white"
        >
          {t.home.seeAll}
        </Link>
      </div>
    </section>
  );
}
