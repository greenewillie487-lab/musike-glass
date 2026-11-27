import { CaretRightIcon, DotsThreeIcon, PlayIcon, RadioIcon } from "@phosphor-icons/react";
import type { MouseEvent } from "react";
import { Link } from "react-router";
import { useT } from "../i18n";
import { cn } from "../lib/format";
import type { Track } from "../lib/types";
import { usePlayer } from "../player/player";
import { useUi } from "../stores/ui";
import { Artwork } from "./Artwork";
import { LogoMark } from "./Brand";

/**
 * A real thing from the library or the catalog, presented like an Apple Music
 * New-tab story: full-bleed artwork, left-aligned supertitle over the image,
 * large headline and subline, play / radio / more as dedicated controls.
 * Every field comes from existing data — there is no editorial placeholder.
 */
export interface NewFeature {
  id: string;
  /** Real source/category label (e.g. Continue listening, a genre, Your playlist). */
  kicker: string;
  /** Real playlist, collection or track title. */
  title: string;
  subtitle: string;
  art: string;
  thumb: string;
  tracks: Track[];
  start?: number;
  to?: string;
  /** The single tall lead story at the top of the feed. */
  hero?: boolean;
}

export function NewFeatureCard({ feature }: { feature: NewFeature }) {
  const t = useT();
  const playList = usePlayer((s) => s.playList);
  const startRadio = usePlayer((s) => s.startRadio);
  const openMenu = useUi((s) => s.openMenu);
  const first = feature.tracks[feature.start ?? 0] ?? feature.tracks[0];

  const menuAt = (e: MouseEvent<HTMLButtonElement>) => {
    if (!first) return;
    e.preventDefault();
    e.stopPropagation();
    const r = e.currentTarget.getBoundingClientRect();
    openMenu({ track: first, x: r.right - 256, y: r.bottom + 6 });
  };

  const play = () => playList(feature.tracks, feature.start ?? 0);

  return (
    <article
      className={cn("new-feature", feature.hero ? "new-feature--hero" : "new-feature--card")}
      aria-label={feature.title}
    >
      <Artwork src={feature.art} fallback={feature.thumb} className="new-feature__art absolute inset-0 size-full" />
      <div className="new-feature__scrim absolute inset-0" aria-hidden="true" />

      {/* Apple Music's New tab starts playback when the story itself is tapped. */}
      {feature.tracks.length > 0 && (
        <button
          type="button"
          onClick={play}
          aria-label={t.common.playX(feature.title)}
          className="absolute inset-0 z-10 rounded-[22px] focus-visible:outline-offset-[-3px]"
        />
      )}

      <div className="pointer-events-none absolute inset-0 z-20 flex flex-col justify-between gap-10 p-5 md:p-7">
        <div className="flex items-start justify-between gap-3">
          <span className="new-kicker truncate pt-1">{feature.kicker}</span>
          <span className="flex shrink-0 items-center gap-1 rounded-full bg-black/25 px-2 py-1 text-[10px] font-bold tracking-wide text-white/90">
            <LogoMark className="size-3" /> musike
          </span>
        </div>

        <div className="min-w-0">
          <h2 className="line-clamp-2 text-[30px] leading-[1.05] font-bold tracking-tight text-white drop-shadow-[0_2px_12px_rgb(0_0_0/0.45)] md:text-[38px]">
            {feature.title}
          </h2>
          <p className="mt-1.5 truncate text-sm text-white/75 md:text-base">{feature.subtitle}</p>

          <div className="pointer-events-auto mt-5 flex flex-wrap items-center gap-2.5">
            {feature.tracks.length > 0 && (
              <button
                type="button"
                onClick={play}
                aria-label={t.common.playX(feature.title)}
                title={t.common.playX(feature.title)}
                className="grid size-12 place-items-center rounded-full bg-white text-black shadow-[0_8px_24px_rgb(0_0_0/0.35)] transition-transform duration-200 ease-out-expo hover:scale-105 active:scale-95"
              >
                <PlayIcon size={22} weight="fill" />
              </button>
            )}
            {first && (
              <>
                <button
                  type="button"
                  onClick={() => void startRadio(first)}
                  aria-label={t.trackMenu.startRadio}
                  title={t.trackMenu.startRadio}
                  className="glass-chip grid size-12 place-items-center rounded-full text-white"
                >
                  <RadioIcon size={20} />
                </button>
                <button
                  type="button"
                  onClick={menuAt}
                  aria-label={t.trackList.moreFor(first.title)}
                  title={t.trackList.more}
                  className="glass-chip grid size-12 place-items-center rounded-full text-white"
                >
                  <DotsThreeIcon size={22} weight="bold" />
                </button>
              </>
            )}
            {feature.to && (
              <Link
                to={feature.to}
                className="ml-1 flex items-center gap-0.5 text-sm font-semibold text-white/90 hover:text-white"
              >
                {t.home.seeAll} <CaretRightIcon size={14} weight="bold" />
              </Link>
            )}
          </div>
        </div>
      </div>
    </article>
  );
}
