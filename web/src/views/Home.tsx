import {
  CaretRightIcon,
  GearSixIcon,
  HeartIcon,
  PlayIcon,
  RadioIcon,
} from "@phosphor-icons/react";
import type { ReactNode } from "react";
import { Link, useNavigate } from "react-router";
import { Artwork } from "../components/Artwork";
import { LogoMark } from "../components/Brand";
import { Section } from "../components/Page";
import { TrackList, TrackListSkeleton } from "../components/TrackList";
import { useRemote } from "../hooks/useRemote";
import { useI18n, useT } from "../i18n";
import { api } from "../lib/api";
import { loadCharts, playChartSong, chartTrack, type ChartItem, type Charts } from "../lib/charts";
import { paths } from "../lib/routes";
import type { Genre, GenrePage, Playlist, Track } from "../lib/types";
import { usePlayer } from "../player/player";
import { useAppearance } from "../stores/appearance";
import { useLibrary } from "../stores/library";
import { needsAttention, openSettings, useSystem } from "../stores/system";

/** Deterministic card colour derived from a real id/name — no random or invented artwork. */
function cardGradient(key: string) {
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) % 360;
  return `linear-gradient(135deg, hsl(${h} 84% 54%), hsl(${(h + 42) % 360} 72% 30%) 60%, hsl(${(h + 74) % 360} 60% 17%))`;
}

/** The badge on editorial cards: our own mark, not a fake Apple Music badge. */
function CardBadge() {
  return (
    <span className="flex h-6 items-center gap-1 rounded-full bg-black/25 px-2 text-[10px] font-bold tracking-wide text-white/90 backdrop-blur-sm">
      <LogoMark className="size-3" /> zidon
    </span>
  );
}

/**
 * Whole-card widths for the Home rails. Each rail uses `gap-4` (1rem), so N
 * cards fill the visible width exactly when each is (100% - (N-1) * 1rem) / N.
 * Percentages (not vw or fixed px) mean an integer number of cards is visible at
 * every breakpoint, so no partial card peeks in at the right edge.
 */
const railCardWidth =
  "w-[calc((100%_-_1rem)/2)] sm:w-[calc((100%_-_2rem)/3)] md:w-[calc((100%_-_3rem)/4)] lg:w-[calc((100%_-_4rem)/5)] xl:w-[calc((100%_-_5rem)/6)]";

function HomeHeader() {
  const t = useT();
  const info = useSystem((s) => s.info);
  const attention = needsAttention(info);
  // Keep this bar fully opaque while sticky: a translucent header lets
  // scrolling section labels bleed through as ghost letters behind the title.
  return (
    <header className="safe-top sticky top-0 z-10 flex items-center justify-between gap-3 bg-bg px-4 pt-3 pb-4 backdrop-blur-xl md:bg-surface-1 md:px-6 md:pt-6">
      <h1 className="text-[34px] leading-none font-bold tracking-tight md:text-[40px]">{t.nav.home}</h1>
      <div className="flex items-center gap-1.5">
        <button
          type="button"
          onClick={openSettings}
          aria-label={attention ? t.nav.settingsAttention : t.nav.settings}
          title={t.nav.settings}
          className="relative grid size-10 place-items-center rounded-full text-fg-2 transition-colors hover:bg-surface-3 hover:text-fg"
        >
          <GearSixIcon size={20} />
          {attention && <span className="absolute top-1.5 right-1.5 size-2 rounded-full bg-accent ring-2 ring-bg" />}
        </button>
        <Link
          to={paths.favorites}
          aria-label={t.nav.favorites}
          title={t.nav.favorites}
          className="grid size-11 place-items-center rounded-full bg-gradient-to-br from-[#c9a7ff] to-[#7b52e0] shadow-[0_6px_18px_rgb(0_0_0/0.25)] ring-1 ring-white/30 transition-transform active:scale-95"
        >
          <HeartIcon size={24} weight="fill" className="text-[#ff2d55]" />
        </Link>
      </div>
    </header>
  );
}

interface Feature {
  label: string;
  title: string;
  subtitle: string;
  art: string;
  thumb: string;
  to: string;
  tracks: Track[];
  start: number;
}

/** One large editorial card, built only from something the library actually contains. */
function FeatureCard({ feature }: { feature: Feature }) {
  const t = useT();
  const playList = usePlayer((s) => s.playList);
  return (
    <section className="px-4 pt-2 md:px-6" aria-label={feature.label}>
      <div className="relative isolate overflow-hidden rounded-[26px] bg-surface-2 ring-1 ring-line">
        <Artwork src={feature.art} fallback={feature.thumb} className="absolute inset-0 size-full" />
        <div className="absolute inset-0 bg-gradient-to-t from-black via-black/70 to-black/25" />
        <div className="relative flex min-h-[300px] flex-col justify-between gap-10 p-6 md:min-h-[340px] md:p-8">
          <span className="text-[11px] font-semibold tracking-[0.18em] text-white/70 uppercase">{feature.label}</span>
          <div className="min-w-0">
            <h2 className="line-clamp-2 text-[30px] leading-[1.05] font-bold tracking-tight text-white md:text-4xl">{feature.title}</h2>
            <p className="mt-2 truncate text-sm text-white/70">{feature.subtitle}</p>
          </div>
          <div className="flex items-center gap-4">
            <button
              type="button"
              onClick={() => playList(feature.tracks, feature.start)}
              aria-label={t.common.playX(feature.title)}
              className="grid size-14 place-items-center rounded-full bg-white text-black shadow-[0_8px_24px_rgb(0_0_0/0.35)] transition-transform hover:scale-105 active:scale-95"
            >
              <PlayIcon size={26} weight="fill" />
            </button>
            <Link to={feature.to} className="flex items-center gap-0.5 text-sm font-semibold text-white/90 hover:text-white">
              {t.home.seeAll} <CaretRightIcon size={14} weight="bold" />
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}

function PlaylistCard({ playlist }: { playlist: Playlist }) {
  const t = useT();
  const playList = usePlayer((s) => s.playList);
  return (
    <div
      className={`group relative ${railCardWidth} shrink-0 snap-start overflow-hidden rounded-[18px]`}
      style={{ background: cardGradient(playlist.id) }}
    >
      <div className="pointer-events-none relative flex aspect-[4/5] flex-col justify-between p-4">
        <div className="flex justify-between gap-2">
          {playlist.tracks.length > 0 && (
            <span className="grid size-7 place-items-center rounded-full bg-black/25 text-white/90 backdrop-blur-sm">
              <PlayIcon size={14} weight="fill" />
            </span>
          )}
          <span className="ml-auto"><CardBadge /></span>
        </div>
        <div className="min-w-0">
          <p className="line-clamp-3 text-[26px] leading-[1.06] font-bold tracking-tight text-white drop-shadow-sm">{playlist.name}</p>
          <p className="mt-2 text-xs text-white/70">{t.common.tracks(playlist.tracks.length)}</p>
        </div>
      </div>
      <Link to={paths.playlist(playlist.id)} className="absolute inset-0 z-10" aria-label={playlist.name} />
      {playlist.tracks.length > 0 && (
        <button
          type="button"
          onClick={() => playList(playlist.tracks, 0)}
          aria-label={t.common.playX(playlist.name)}
          className="absolute bottom-3 right-3 z-20 grid size-11 place-items-center rounded-full bg-white text-black opacity-0 shadow-[0_8px_20px_rgb(0_0_0/0.4)] transition-[opacity,transform] duration-200 ease-out-expo hover:scale-105 group-hover:opacity-100 group-focus-within:opacity-100"
        >
          <PlayIcon size={20} weight="fill" />
        </button>
      )}
    </div>
  );
}

function StationCard({ genre }: { genre: Genre }) {
  const t = useT();
  const page = useRemote<GenrePage>(`station-covers:${genre.id}`, (signal) => api.genre(genre.id, signal));
  // Real artwork from the genre's own tracks, reshuffled once a day — not on every visit.
  const bucket = Math.floor(Date.now() / 86_400_000);
  const tracks = page.status === "ok" ? page.data.tracks : [];
  const picks: Track[] = [];
  if (tracks.length > 0) {
    const start = bucket % tracks.length;
    for (let i = 0; i < tracks.length && picks.length < 4; i++) {
      const candidate = tracks[(start + i * 7) % tracks.length];
      if (!picks.some((p) => p.id === candidate.id)) picks.push(candidate);
    }
  }
  return (
    <Link
      to={paths.genre(genre.id)}
      state={{ name: genre.name }}
      className={`group flex ${railCardWidth} shrink-0 snap-start flex-col gap-2`}
    >
      <span className="relative block aspect-square overflow-hidden rounded-[14px]" style={{ background: cardGradient(genre.id) }}>
        {picks.length >= 4 && (
          <span className="absolute inset-0 grid grid-cols-2 grid-rows-2">
            {picks.map((p) => (
              <img key={p.id} src={p.thumb || p.art} alt="" className="size-full object-cover" />
            ))}
          </span>
        )}
        <span className="absolute inset-0 grid place-items-center">
          <RadioIcon size={40} weight="fill" className="text-white/90 drop-shadow-[0_2px_8px_rgb(0_0_0/0.35)] transition-transform duration-300 ease-out-expo group-hover:scale-110" />
        </span>
        <span className="absolute top-2 right-2"><CardBadge /></span>
      </span>
      <span className="min-w-0">
        <span className="block truncate text-[13px] font-medium">{genre.name}</span>
        <span className="block truncate text-xs text-fg-2">{t.home.station}</span>
      </span>
    </Link>
  );
}

function RecentCard({ track, onPlay }: { track: Track; onPlay: () => void }) {
  return (
    <button
      type="button"
      onClick={onPlay}
      className={`group flex ${railCardWidth} shrink-0 snap-start flex-col gap-2 text-left`}
    >
      <span className="relative block">
        <Artwork src={track.art} fallback={track.thumb} className="aspect-square w-full rounded-[16px]" />
        <span className="absolute right-3 bottom-3 grid size-12 translate-y-1 place-items-center rounded-full bg-accent text-accent-ink opacity-0 shadow-[0_8px_20px_rgb(0_0_0/0.4)] transition-[opacity,transform] duration-200 ease-out-expo group-hover:translate-y-0 group-hover:opacity-100 group-focus-visible:translate-y-0 group-focus-visible:opacity-100">
          <PlayIcon size={22} weight="fill" />
        </span>
      </span>
      <span className="min-w-0">
        <span className="block truncate text-sm font-semibold">{track.title}</span>
        <span className="block truncate text-xs text-fg-2">{track.artist}</span>
      </span>
    </button>
  );
}

function Rail({ children }: { children: ReactNode }) {
  return (
    <div className="no-scrollbar flex max-w-full min-w-0 snap-x snap-mandatory scroll-px-4 gap-4 overflow-x-auto px-4 pb-1 md:scroll-px-6 md:px-6">
      {children}
    </div>
  );
}

function SeeAll({ to }: { to: string }) {
  const t = useT();
  return (
    <Link to={to} className="flex items-center gap-0.5 text-sm font-medium text-fg-2 hover:text-fg">
      {t.home.seeAll} <CaretRightIcon size={14} weight="bold" />
    </Link>
  );
}

export default function Home() {
  const lib = useLibrary();
  // A partial/error API response must not crash the page.
  const favorites = lib.favorites ?? [];
  const playlists = lib.playlists ?? [];
  const history = lib.history ?? [];
  const status = lib.status;
  const playList = usePlayer((s) => s.playList);
  const t = useT();
  const show = useAppearance();
  const lang = useI18n((s) => s.lang);
  const genres = useRemote<Genre[]>(`home-genres:${lang}`, () => api.genres());
  const charts = useRemote<Charts | null>("home-charts", () => loadCharts());
  const navigate = useNavigate();

  const playChart = (item: ChartItem) => {
    void playChartSong(item).then((played) => {
      if (!played) navigate(`${paths.search}?q=${encodeURIComponent(`${item.name} ${item.artistName}`.trim())}`);
    });
  };

  const feature: Feature | null = history[0]
    ? {
        label: t.home.continueListening,
        title: history[0].title,
        subtitle: history[0].artist,
        art: history[0].art,
        thumb: history[0].thumb,
        to: paths.history,
        tracks: history,
        start: 0,
      }
    : playlists[0]
      ? {
          label: t.home.yourPlaylist,
          title: playlists[0].name,
          subtitle: t.common.tracks(playlists[0].tracks.length),
          art: playlists[0].tracks[0]?.art ?? "",
          thumb: playlists[0].tracks[0]?.thumb ?? "",
          to: paths.playlist(playlists[0].id),
          tracks: playlists[0].tracks,
          start: 0,
        }
      : favorites[0]
        ? {
            label: t.home.featured,
            title: t.nav.favorites,
            subtitle: t.common.tracks(favorites.length),
            art: favorites[0].art,
            thumb: favorites[0].thumb,
            to: paths.favorites,
            tracks: favorites,
            start: 0,
          }
        : null;

  // Clip at the page edge so no card gradient or decorative shadow can escape
  // past the right side of a rail. Top padding clears the status bar on the
  // edge-to-edge web view so the sticky "Home" title never ghosts behind it.
  return (
    <div className="overflow-x-clip pt-[env(safe-area-inset-top)] pb-8">
      <HomeHeader />

      {status === "loading" && <TrackListSkeleton rows={6} />}

      {status !== "loading" && (
        <div className="flex flex-col gap-10">
          {feature ? <FeatureCard feature={feature} /> : null}

          {charts.status === "ok" && charts.data?.topSongs.length ? (
            <Section title={t.home.topSongs}>
              <Rail>
                {charts.data.topSongs.slice(0, 16).map((item, i) => (
                  <RecentCard key={`top-${item.name}-${i}`} track={chartTrack(item, i)} onPlay={() => playChart(item)} />
                ))}
              </Rail>
            </Section>
          ) : null}

          {charts.status === "ok" && charts.data?.ghanaSongs.length ? (
            <Section title={t.home.topSongsGh}>
              <Rail>
                {charts.data.ghanaSongs.slice(0, 16).map((item, i) => (
                  <RecentCard key={`gh-${item.name}-${i}`} track={chartTrack(item, i)} onPlay={() => playChart(item)} />
                ))}
              </Rail>
            </Section>
          ) : null}

          {charts.status === "ok" && charts.data?.nigeriaSongs.length ? (
            <Section title={t.home.topSongsNg}>
              <Rail>
                {charts.data.nigeriaSongs.slice(0, 16).map((item, i) => (
                  <RecentCard key={`ng-${item.name}-${i}`} track={chartTrack(item, i)} onPlay={() => playChart(item)} />
                ))}
              </Rail>
            </Section>
          ) : null}

          {charts.status === "ok" && charts.data?.topAlbums.length ? (
            <Section title={t.home.topAlbums}>
              <Rail>
                {charts.data.topAlbums.slice(0, 16).map((item, i) => (
                  <RecentCard
                    key={`alb-${item.name}-${i}`}
                    track={chartTrack(item, i)}
                    onPlay={() =>
                      navigate(`${paths.search}?q=${encodeURIComponent(`${item.name} ${item.artistName}`.trim())}&type=albums`)
                    }
                  />
                ))}
              </Rail>
            </Section>
          ) : null}

          {playlists.length > 0 && (
            <Section title={t.home.playlistsForYou}>
              <Rail>
                {playlists.slice(0, 12).map((p) => (
                  <PlaylistCard key={p.id} playlist={p} />
                ))}
              </Rail>
            </Section>
          )}

          {genres.status === "ok" && genres.data.length > 0 && (
            <Section title={t.home.stationsForYou}>
              <Rail>
                {genres.data.slice(0, 16).map((g) => (
                  <StationCard key={g.id} genre={g} />
                ))}
              </Rail>
            </Section>
          )}

          {show.homeRecent && history.length > 0 && (
            <Section title={t.nav.recentlyPlayed} action={<SeeAll to={paths.history} />}>
              <Rail>
                {history.slice(0, 16).map((track, i) => (
                  <RecentCard key={track.id} track={track} onPlay={() => playList(history, i)} />
                ))}
              </Rail>
            </Section>
          )}

          {show.homeFavorites && favorites.length > 0 && (
            <Section title={t.home.yourFavorites} action={<SeeAll to={paths.favorites} />}>
              <div className="px-2 md:px-3">
                <TrackList tracks={favorites.slice(0, 5)} context={favorites} header={false} showAlbum={false} />
              </div>
            </Section>
          )}
        </div>
      )}
    </div>
  );
}
