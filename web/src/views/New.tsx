import { CaretRightIcon, DotsThreeIcon, MagnifyingGlassIcon, PlayIcon } from "@phosphor-icons/react";
import type { MouseEvent } from "react";
import { Link, useNavigate } from "react-router";
import { Artwork } from "../components/Artwork";
import { LogoMark } from "../components/Brand";
import { NewFeatureCard, type NewFeature } from "../components/NewFeatureCard";
import { Section } from "../components/Page";
import { useRemote } from "../hooks/useRemote";
import { useI18n, useT } from "../i18n";
import { api } from "../lib/api";
import { loadCharts, playChartSong, chartTrack, type Charts } from "../lib/charts";
import { paths } from "../lib/routes";
import type { Genre, GenrePage, Track } from "../lib/types";
import { usePlayer } from "../player/player";
import { useLibrary } from "../stores/library";
import { useUi } from "../stores/ui";
import "../new.css";

function SeeAll({ to }: { to: string }) {
  const t = useT();
  return (
    <Link to={to} className="flex items-center gap-0.5 text-sm font-medium text-fg-2 hover:text-fg">
      {t.home.seeAll} <CaretRightIcon size={14} weight="bold" />
    </Link>
  );
}

/** Large Recently Played tile. Play and the track menu stay the same as everywhere else in the app. */
function RecentCard({ track, onPlay }: { track: Track; onPlay: () => void }) {
  const t = useT();
  const openMenu = useUi((s) => s.openMenu);
  const menuAt = (e: MouseEvent<HTMLButtonElement>) => {
    e.preventDefault();
    e.stopPropagation();
    const r = e.currentTarget.getBoundingClientRect();
    openMenu({ track, x: r.right - 256, y: r.bottom + 6 });
  };
  return (
    <div className="group relative flex w-[46vw] max-w-[260px] shrink-0 snap-start flex-col gap-2 md:w-[240px] lg:w-[280px]">
      <button type="button" onClick={onPlay} aria-label={t.common.playX(track.title)} className="relative block w-full text-left">
        <Artwork src={track.art} fallback={track.thumb} className="aspect-square w-full rounded-[16px]" />
        <span className="absolute right-3 bottom-3 grid size-12 translate-y-1 place-items-center rounded-full bg-accent text-accent-ink opacity-0 shadow-[0_8px_20px_rgb(0_0_0/0.4)] transition-[opacity,transform] duration-200 ease-out-expo group-hover:translate-y-0 group-hover:opacity-100 group-focus-visible:translate-y-0 group-focus-visible:opacity-100">
          <PlayIcon size={22} weight="fill" />
        </span>
      </button>
      <button
        type="button"
        onClick={menuAt}
        aria-label={t.trackList.moreFor(track.title)}
        title={t.trackList.more}
        className="absolute top-2 right-2 z-20 grid size-10 place-items-center rounded-full bg-black/35 text-white ring-1 ring-white/20 transition-colors hover:bg-black/55"
      >
        <DotsThreeIcon size={20} weight="bold" />
      </button>
      <div className="min-w-0">
        <p className="truncate text-sm font-semibold">{track.title}</p>
        <p className="truncate text-xs text-fg-2">{track.artist}</p>
      </div>
    </div>
  );
}

/** A real genre page supplies real tracks and artwork for one editorial story. */
function GenreSpotlight({ genre }: { genre: Genre }) {
  const lang = useI18n((s) => s.lang);
  const page = useRemote<GenrePage>(`new-genre:${lang}:${genre.id}`, (signal) => api.genre(genre.id, signal));
  if (page.status !== "ok") return null;
  const lead = page.data.tracks[0];
  if (!lead) return null;
  return (
    <NewFeatureCard
      feature={{
        id: `genre-${genre.id}`,
        kicker: genre.name,
        title: lead.title,
        subtitle: lead.artist,
        art: lead.art,
        thumb: lead.thumb,
        tracks: page.data.tracks,
        to: paths.genre(genre.id),
      }}
    />
  );
}

export default function New() {
  const lib = useLibrary();
  const t = useT();
  const lang = useI18n((s) => s.lang);
  const navigate = useNavigate();
  const playList = usePlayer((s) => s.playList);
  const genres = useRemote<Genre[]>(`new-genres:${lang}`, () => api.genres());
  const charts = useRemote<Charts | null>("home-charts", () => loadCharts());

  const playChart = (item: Parameters<typeof playChartSong>[0]) => {
    void playChartSong(item).then((played) => {
      if (!played) navigate(`${paths.search}?q=${encodeURIComponent(`${item.name} ${item.artistName}`.trim())}`);
    });
  };

  // A partial or failed library response must never crash the page.
  const favorites = lib.favorites ?? [];
  const playlists = lib.playlists ?? [];
  const history = lib.history ?? [];
  const status = lib.status;

  // Only real library items become stories, in the same priority order as the feed on Home.
  const features: NewFeature[] = [];
  const recent = history[0];
  if (recent) {
    features.push({
      id: `continue-${recent.id}`,
      kicker: t.home.continueListening,
      title: recent.title,
      subtitle: recent.artist,
      art: recent.art,
      thumb: recent.thumb,
      tracks: history,
      to: paths.history,
    });
  }
  for (const playlist of playlists.filter((p) => p.tracks.length > 0).slice(0, 3)) {
    const lead = playlist.tracks[0];
    if (!lead) continue; // an empty playlist is not a story
    features.push({
      id: `playlist-${playlist.id}`,
      kicker: t.home.yourPlaylist,
      title: playlist.name,
      subtitle: t.common.tracks(playlist.tracks.length),
      art: lead.art,
      thumb: lead.thumb,
      tracks: playlist.tracks,
      to: paths.playlist(playlist.id),
    });
  }
  const firstFavorite = favorites[0];
  if (firstFavorite) {
    features.push({
      id: "favorites",
      kicker: t.home.featured,
      title: t.nav.favorites,
      subtitle: t.common.tracks(favorites.length),
      art: firstFavorite.art,
      thumb: firstFavorite.thumb,
      tracks: favorites,
      to: paths.favorites,
    });
  }

  const [hero, ...rest] = features;
  const noGenres = genres.status === "error" || (genres.status === "ok" && genres.data.length === 0);
  const empty = status === "ready" && features.length === 0 && noGenres;

  return (
    <div className="pt-[env(safe-area-inset-top)] pb-8">
      <header className="safe-top sticky top-0 z-10 flex items-center justify-between gap-3 bg-bg px-4 pt-3 pb-4 backdrop-blur-xl md:bg-surface-1 md:px-6 md:pt-6">
        {/* Fully opaque like HomeHeader: a translucent sticky bar lets scrolled content ghost through under the status bar. */}
        <div className="flex min-w-0 items-center gap-2.5">
          <LogoMark className="size-7 shrink-0 text-accent" />
          {/* No dedicated nav key exists yet; library.newShort is the shipped "New" string. */}
          <h1 className="truncate text-[34px] leading-none font-bold tracking-tight md:text-[42px]">{t.library.newShort}</h1>
        </div>
        <Link
          to={paths.search}
          aria-label={t.common.searchMusic}
          title={t.common.searchMusic}
          className="grid size-11 shrink-0 place-items-center rounded-full text-fg-2 transition-colors hover:bg-surface-3 hover:text-fg"
        >
          <MagnifyingGlassIcon size={22} />
        </Link>
      </header>

      {status === "loading" || (features.length === 0 && genres.status === "loading") ? (
        <div className="new-feed px-4 pt-2 md:px-6" aria-busy="true">
          <div className="new-feature new-feature--hero skeleton" />
          <div className="new-feature new-feature--card skeleton" />
        </div>
      ) : (
        <main className="new-feed">
          {hero && <NewFeatureCard feature={{ ...hero, hero: true }} />}

          {charts.status === "ok" && charts.data?.newMusic.length ? (
            <Section title={t.home.newMusic}>
              <div className="no-scrollbar flex snap-x snap-mandatory scroll-px-4 gap-4 overflow-x-auto px-4 pb-1 md:scroll-px-6 md:px-6">
                {charts.data.newMusic.slice(0, 16).map((item, i) => (
                  <RecentCard key={`new-${item.name}-${i}`} track={chartTrack(item, i)} onPlay={() => playChart(item)} />
                ))}
              </div>
            </Section>
          ) : null}

          {rest.length > 0 && (
            <Section title={t.home.featured}>
              <div className="new-feed">
                {rest.map((feature) => (
                  <NewFeatureCard key={feature.id} feature={feature} />
                ))}
              </div>
            </Section>
          )}

          {genres.status === "ok" && genres.data.length > 0 && (
            <Section title={t.search.genres}>
              <div className="new-feed">
                {genres.data.slice(0, 2).map((genre) => (
                  <GenreSpotlight key={genre.id} genre={genre} />
                ))}
              </div>
            </Section>
          )}

          {history.length > 0 && (
            <Section title={t.nav.recentlyPlayed} action={<SeeAll to={paths.history} />}>
              <div className="no-scrollbar flex snap-x snap-mandatory scroll-px-4 gap-4 overflow-x-auto px-4 pb-1 md:scroll-px-6 md:px-6">
                {history.slice(0, 16).map((track, i) => (
                  <RecentCard key={track.id} track={track} onPlay={() => playList(history, i)} />
                ))}
              </div>
            </Section>
          )}

          {empty && (
            <div className="mx-4 flex flex-col items-start gap-5 rounded-[20px] bg-surface-2 p-6 ring-1 ring-line md:mx-6 md:flex-row md:items-center md:p-8">
              <span className="grid size-16 shrink-0 place-items-center rounded-[18px] bg-accent text-accent-ink">
                <LogoMark className="size-10" />
              </span>
              <div className="flex-1">
                <p className="text-xl font-semibold tracking-tight">{t.home.startTitle}</p>
                <p className="mt-1 max-w-[52ch] text-sm text-fg-2">{t.home.startBody}</p>
              </div>
              <button
                type="button"
                onClick={() => navigate(paths.search)}
                className="flex h-12 items-center gap-2 rounded-full bg-accent pr-6 pl-5 font-semibold text-accent-ink transition-transform active:scale-[0.97]"
              >
                <MagnifyingGlassIcon size={20} weight="bold" /> {t.common.searchMusic}
              </button>
            </div>
          )}
        </main>
      )}
    </div>
  );
}
