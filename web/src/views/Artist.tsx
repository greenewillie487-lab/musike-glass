import {
  CaretRightIcon,
  DotsThreeIcon,
  DownloadSimpleIcon,
  GearSixIcon,
  InfoIcon,
  MusicNotesIcon,
  PlayIcon,
  ShareNetworkIcon,
  StarIcon,
  TicketIcon,
  WarningCircleIcon,
} from "@phosphor-icons/react";
import { useState } from "react";
import { Link, useLocation, useParams } from "react-router";
import { AlbumRow } from "../components/AlbumTiles";
import { Artwork } from "../components/Artwork";
import { EmptyState, GlassCircleButton, HeroBackButton, HeroHeader } from "../components/Page";
import { TrackList, TrackListSkeleton } from "../components/TrackList";
import { useRemote } from "../hooks/useRemote";
import { useI18n, useT } from "../i18n";
import { api } from "../lib/api";
import { paths } from "../lib/routes";
import { cn } from "../lib/format";
import type { ArtistPage } from "../lib/types";
import { usePlayer } from "../player/player";
import { useLibrary } from "../stores/library";
import { useUi } from "../stores/ui";

/** An artist's greatest hits, ready to pick from. */
export default function Artist() {
  const { id = "" } = useParams();
  const location = useLocation();
  const lang = useI18n((s) => s.lang);
  const t = useT();
  // The bio comes from YouTube Music in the app language.
  const page = useRemote<ArtistPage>(`artist:${lang}:${id}`, (signal) => api.artist(id, signal));
  const [fullBio, setFullBio] = useState(false);
  const [moreOpen, setMoreOpen] = useState(false);
  const playList = usePlayer((s) => s.playList);
  const favorites = useLibrary((s) => s.favorites);
  const toggleFavorite = useLibrary((s) => s.toggleFavorite);
  const addFavorites = useLibrary((s) => s.addFavorites);
  const setSettingsOpen = useUi((s) => s.setSettingsOpen);
  const name = (page.status === "ok" && page.data.name) || (location.state as { name?: string } | null)?.name || t.artist.fallbackName;

  // Labels come from the target screen; localize here so the app stays bilingual.
  const copy =
    lang === "pt-BR"
      ? { topSongs: "Músicas mais populares", concerts: "Próximos shows", share: "Compartilhar", more: "Mais", about: "Sobre o artista", latest: "Último lançamento" }
      : { topSongs: "Top Songs", concerts: "Upcoming Concerts", share: "Share", more: "More", about: "About the artist", latest: "Latest release" };

  const tracks = page.status === "ok" ? page.data.tracks : [];
  const favoriteIds = new Set(favorites.map((favorite) => favorite.id));
  const allFavorited = tracks.length > 0 && tracks.every((track) => favoriteIds.has(track.id));
  const release = page.status === "ok" ? page.data.singles[0] ?? page.data.albums[0] : undefined;
  const releaseIsSingle = page.status === "ok" && page.data.singles.length > 0;

  const shareArtist = async () => {
    const url = window.location.href;
    const sharePage = navigator as Navigator & { share?: (data: { title: string; text: string; url: string }) => Promise<void> };
    if (sharePage.share) {
      try {
        await sharePage.share({ title: name, text: name, url });
        return;
      } catch {
        return; // Share sheet dismissed; never fall through to a silent copy.
      }
    }
    try {
      await navigator.clipboard?.writeText(url);
    } catch {
      // Clipboard is unavailable in some WebViews; nothing else to do.
    }
  };

  const toggleArtistFavorites = () => {
    if (!tracks.length) return;
    if (allFavorited) void Promise.all(tracks.filter((track) => favoriteIds.has(track.id)).map((track) => toggleFavorite(track)));
    else void addFavorites(tracks.filter((track) => !favoriteIds.has(track.id)));
  };

  const openYouTube = (query: string) =>
    window.open(`https://www.youtube.com/results?search_query=${encodeURIComponent(query)}`, "_blank", "noopener");

  return (
    <div className="pb-8">
      <div className="relative">
        <div className="absolute inset-x-0 top-0 h-[430px] overflow-hidden md:rounded-t-[20px]">
          {page.status === "ok" && page.data.banner ? (
            <Artwork src={page.data.banner} className="size-full" />
          ) : (
            <div className={cn("size-full bg-surface-3", page.status === "loading" && "skeleton")} />
          )}
          <div aria-hidden="true" className="absolute inset-0 bg-linear-to-t from-bg via-bg/60 to-black/35" />
        </div>

        <HeroHeader
          back={<HeroBackButton fallback={paths.search} />}
          actions={
            <>
              <GlassCircleButton label={copy.share} onClick={() => void shareArtist()}>
                <ShareNetworkIcon size={18} weight="bold" />
              </GlassCircleButton>
              <GlassCircleButton label={copy.more} aria-expanded={moreOpen} onClick={() => setMoreOpen((open) => !open)}>
                <DotsThreeIcon size={21} weight="bold" />
              </GlassCircleButton>
            </>
          }
        />

        {moreOpen && (
          <>
            <button type="button" aria-label={copy.more} className="fixed inset-0 z-30" onClick={() => setMoreOpen(false)} />
            <div
              role="menu"
              className="absolute top-[calc(env(safe-area-inset-top)+3.25rem)] right-3 z-40 w-44 rounded-[14px] bg-surface-2/95 p-1 shadow-xl ring-1 ring-line backdrop-blur-xl"
            >
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMoreOpen(false);
                  void shareArtist();
                }}
                className="flex h-10 w-full items-center gap-2 rounded-[10px] px-3 text-left text-sm text-fg hover:bg-surface-3"
              >
                <ShareNetworkIcon size={17} /> {copy.share}
              </button>
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMoreOpen(false);
                  setSettingsOpen(true);
                }}
                className="flex h-10 w-full items-center gap-2 rounded-[10px] px-3 text-left text-sm text-fg hover:bg-surface-3"
              >
                <GearSixIcon size={17} /> {t.nav.settings}
              </button>
            </div>
          </>
        )}

        <div className="relative flex h-[430px] flex-col items-center justify-end px-5 pb-7 text-center md:pb-9">
          <a
            href={`https://www.google.com/search?q=${encodeURIComponent(`${name} concerts tickets`)}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex max-w-full items-center gap-1.5 rounded-full bg-black/35 px-3 py-1.5 text-[11px] font-semibold tracking-wide text-white ring-1 ring-white/20 backdrop-blur-xl active:scale-[0.97]"
          >
            <TicketIcon size={13} weight="fill" />
            <span className="truncate">{copy.concerts}</span>
          </a>
          <h1 className="mt-3 max-w-[22ch] text-[30px] leading-[1.05] font-bold tracking-tight text-balance text-white drop-shadow-lg md:text-5xl">
            {name}
          </h1>
          <div className="mt-5 flex items-center gap-5">
            <GlassCircleButton
              label={copy.about}
              aria-expanded={fullBio}
              onClick={() => setFullBio((open) => !open)}
              className="size-8"
            >
              <InfoIcon size={17} weight="bold" />
            </GlassCircleButton>
            <button
              type="button"
              onClick={() => playList(tracks, 0)}
              disabled={!tracks.length}
              aria-label={t.common.playAll}
              title={t.common.playAll}
              className="grid size-14 place-items-center rounded-full bg-white text-black shadow-lg transition-transform duration-150 hover:scale-[1.04] active:scale-95 disabled:opacity-40"
            >
              <PlayIcon size={27} weight="fill" />
            </button>
            <GlassCircleButton
              label={allFavorited ? t.common.removeFromFavorites : t.common.addToFavorites}
              onClick={toggleArtistFavorites}
              className="size-8"
            >
              <StarIcon size={17} weight={allFavorited ? "fill" : "regular"} />
            </GlassCircleButton>
          </div>
        </div>
      </div>

      {page.status === "ok" && page.data.description && fullBio && (
        <button
          type="button"
          onClick={() => setFullBio(false)}
          aria-expanded={fullBio}
          className="mx-5 mt-5 max-w-[75ch] text-left text-sm leading-relaxed text-fg-2 hover:text-fg"
        >
          {page.data.description}
        </button>
      )}

      {release && (
        <section aria-label={copy.latest} className="mx-4 mt-5 md:mx-6">
          <div className="flex items-center gap-3 rounded-[18px] bg-surface-2/80 p-3 ring-1 ring-line backdrop-blur-xl">
            <Link
              to={paths.album(release.id)}
              state={{ name: release.title }}
              className="flex min-w-0 flex-1 items-center gap-3 rounded-[12px]"
              aria-label={release.title}
            >
              <Artwork src={release.art} fallback={release.thumb} className="size-16 shrink-0 rounded-[10px]" />
              <span className="min-w-0">
                <span className="block truncate text-[11px] font-semibold tracking-wide text-fg-2 uppercase">{release.year}</span>
                <span className="mt-0.5 block truncate text-[15px] font-semibold">{release.title}</span>
                <span className="block truncate text-[12px] text-fg-2">
                  {release.artist || (releaseIsSingle ? t.artist.singles : t.artist.albums)}
                </span>
              </span>
            </Link>
            <button
              type="button"
              onClick={() => openYouTube(`${name} ${release.title}`)}
              aria-label={t.trackMenu.openYoutube}
              title={t.trackMenu.openYoutube}
              className="grid size-9 shrink-0 place-items-center rounded-full text-fg-2 transition-colors hover:bg-surface-3 hover:text-fg"
            >
              <DownloadSimpleIcon size={19} />
            </button>
          </div>
        </section>
      )}

      <section className="mt-6">
        <h2 className="flex items-center gap-1 px-5 text-[19px] font-bold tracking-tight md:px-6">
          {copy.topSongs}
          <CaretRightIcon size={15} weight="bold" className="text-fg-2" aria-hidden="true" />
        </h2>

        {page.status === "loading" && <TrackListSkeleton />}

        {page.status === "error" && (
          <EmptyState
            icon={<WarningCircleIcon size={28} />}
            title={t.artist.openFailed}
            body={page.message}
            action={
              <button
                type="button"
                onClick={page.retry}
                className="mt-2 h-11 rounded-full bg-surface-3 px-6 text-sm font-medium hover:bg-surface-4"
              >
                {t.common.retry}
              </button>
            }
          />
        )}

        {page.status === "ok" &&
          (tracks.length ? (
            <TrackList key={id} tracks={tracks} showAlbum={false} header={false} artistStyle />
          ) : (
            <EmptyState icon={<MusicNotesIcon size={28} />} title={t.artist.noHits} body={t.artist.noHitsBody} />
          ))}
      </section>

      {/* Below the hits: the rest of the real catalog stays reachable. */}
      {page.status === "ok" && page.data.albums.length > 0 && <AlbumRow title={t.artist.albums} albums={page.data.albums} />}
      {page.status === "ok" && page.data.singles.length > 0 && <AlbumRow title={t.artist.singles} albums={page.data.singles} />}
    </div>
  );
}
