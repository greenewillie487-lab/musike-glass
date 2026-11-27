import {
  CaretRightIcon,
  DatabaseIcon,
  DownloadSimpleIcon,
  GearSixIcon,
  HeartIcon,
  ListBulletsIcon,
  MicrophoneIcon,
  MusicNotesIcon,
  PlayIcon,
  PlusIcon,
  StackIcon,
} from "@phosphor-icons/react";
import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";
import { Artwork } from "../components/Artwork";
import { ChartCard } from "../components/ChartCard";
import { Cover, type CoverKind } from "../components/Cover";
import { NamePlaylistDialog } from "../components/Dialogs";
import { IconButton } from "../components/IconButton";
import { LibraryGroups, type LibraryGroupRow } from "../components/LibraryGroups";
import { TrackList } from "../components/TrackList";
import { useT } from "../i18n";
import { paths } from "../lib/routes";
import type { Track } from "../lib/types";
import { usePlayer } from "../player/player";
import { useLibrary } from "../stores/library";
import { needsAttention, useSystem } from "../stores/system";
import { useUi } from "../stores/ui";

interface LibraryArtist {
  name: string;
  art: string;
  thumb: string;
}

interface LibraryAlbum {
  name: string;
  artist: string;
  art: string;
  thumb: string;
}

/** Every distinct track the library actually knows about, in favorites → playlists → history order. */
function collectTracks(groups: Track[][]): Track[] {
  const seen = new Set<string>();
  const out: Track[] = [];
  for (const group of groups) {
    for (const track of group) {
      if (!track?.id || seen.has(track.id)) continue;
      seen.add(track.id);
      out.push(track);
    }
  }
  return out;
}

function collectArtists(tracks: Track[]): LibraryArtist[] {
  const byName = new Map<string, LibraryArtist>();
  for (const track of tracks) {
    const name = track.artist?.trim();
    if (!name || byName.has(name.toLowerCase())) continue;
    byName.set(name.toLowerCase(), { name, art: track.art, thumb: track.thumb });
  }
  return [...byName.values()];
}

function collectAlbums(tracks: Track[]): LibraryAlbum[] {
  const byAlbum = new Map<string, LibraryAlbum>();
  for (const track of tracks) {
    const name = track.album?.trim();
    if (!name || byAlbum.has(name.toLowerCase())) continue;
    byAlbum.set(name.toLowerCase(), { name, artist: track.artist, art: track.art, thumb: track.thumb });
  }
  return [...byAlbum.values()];
}

const searchTo = (query: string, type?: "albums") => `${paths.search}?q=${encodeURIComponent(query)}${type ? `&type=${type}` : ""}`;

function Header() {
  const t = useT();
  const [creating, setCreating] = useState(false);
  const setSettingsOpen = useUi((s) => s.setSettingsOpen);
  const attention = useSystem((s) => needsAttention(s.info));
  const createPlaylist = useLibrary((s) => s.createPlaylist);
  const navigate = useNavigate();

  return (
    <>
      <header className="safe-top sticky top-0 z-10 flex items-center justify-between gap-3 bg-bg/85 px-4 pt-3 pb-3 backdrop-blur-xl md:bg-surface-1/85 md:px-6 md:pt-6">
        <h1 className="text-[34px] leading-none font-bold tracking-tight md:text-[40px]">{t.nav.library}</h1>
        <div className="flex items-center gap-1.5">
          <IconButton label={t.library.backup} onClick={() => setSettingsOpen(true)}>
            <DatabaseIcon size={20} />
          </IconButton>
          <button
            type="button"
            onClick={() => setCreating(true)}
            className="flex h-10 items-center gap-1.5 rounded-full bg-accent pr-4 pl-3 text-sm font-semibold text-accent-ink transition-transform active:scale-[0.97]"
          >
            <PlusIcon size={18} weight="bold" /> <span className="hidden sm:inline">{t.nav.newPlaylist}</span>
            <span className="sm:hidden">{t.library.newShort}</span>
          </button>
          <IconButton
            label={attention ? t.nav.settingsAttention : t.nav.settings}
            onClick={() => setSettingsOpen(true)}
            className="-mr-2 md:hidden"
          >
            <GearSixIcon size={22} />
            {attention && <span className="absolute top-2 right-2 size-2 rounded-full bg-accent ring-2 ring-bg" />}
          </IconButton>
        </div>
      </header>
      <NamePlaylistDialog
        open={creating}
        title={t.nav.newPlaylist}
        action={t.library.create}
        onClose={() => setCreating(false)}
        onSubmit={async (name) => {
          const playlist = await createPlaylist(name);
          setCreating(false);
          if (playlist) navigate(paths.playlist(playlist.id));
        }}
      />
    </>
  );
}

function SectionTitle({ title, detail }: { title: string; detail?: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3 px-4 md:px-6">
      <h2 className="text-[22px] leading-tight font-bold tracking-tight">{title}</h2>
      {detail && <span className="shrink-0 font-mono text-xs text-fg-3 tabular-nums">{detail}</span>}
    </div>
  );
}

function PlaylistTile({ to, name, kind, tracks }: { to: string; name: string; kind: CoverKind; tracks: Track[] }) {
  return (
    <Link to={to} className="group block min-w-0">
      <Cover
        kind={kind}
        tracks={tracks}
        iconSize={24}
        className="aspect-square w-full rounded-[14px] shadow-[0_8px_24px_rgb(0_0_0/0.18)] transition-transform duration-200 ease-out-expo group-hover:scale-[1.03]"
      />
      <span className="mt-1.5 block truncate text-center text-xs font-medium text-fg-2">{name}</span>
    </Link>
  );
}

function ArtistTile({ artist, className = "" }: { artist: LibraryArtist; className?: string }) {
  return (
    <Link to={searchTo(artist.name)} className={`group block min-w-0 ${className}`}>
      <Artwork
        src={artist.art}
        fallback={artist.thumb}
        className="aspect-square w-full rounded-full shadow-[0_8px_24px_rgb(0_0_0/0.18)] transition-transform duration-200 ease-out-expo group-hover:scale-[1.03]"
      />
      <span className="mt-1.5 block truncate text-center text-xs font-medium text-fg-2">{artist.name}</span>
    </Link>
  );
}

export default function Library() {
  const t = useT();
  const lib = useLibrary();
  // A partial or failed API response must never crash the page.
  const favorites = lib.favorites ?? [];
  const playlists = lib.playlists ?? [];
  const history = lib.history ?? [];
  const playList = usePlayer((s) => s.playList);

  const tracks = useMemo(() => collectTracks([favorites, ...playlists.map((p) => p.tracks), history]), [favorites, playlists, history]);
  const artists = useMemo(() => collectArtists(tracks), [tracks]);
  const albums = useMemo(() => collectAlbums(tracks), [tracks]);
  const recentlyAdded = useMemo(() => collectTracks([favorites, history]).slice(0, 12), [favorites, history]);

  const pinned = [
    ...playlists.slice(0, 6).map((p) => ({
      key: p.id,
      node: <PlaylistTile to={paths.playlist(p.id)} name={p.name} kind="playlist" tracks={p.tracks} />,
    })),
    ...artists.slice(0, 6).map((a) => ({ key: `artist-${a.name}`, node: <ArtistTile artist={a} /> })),
  ].slice(0, 9);

  const rows: LibraryGroupRow[] = [
    { id: "playlists", label: t.library.sectionPlaylists, icon: <ListBulletsIcon size={20} />, detail: String(playlists.length + 2), href: "#library-playlists" },
    { id: "artists", label: t.library.sectionArtists, icon: <MicrophoneIcon size={20} />, detail: String(artists.length), href: "#library-artists" },
    { id: "albums", label: t.library.sectionAlbums, icon: <StackIcon size={20} />, detail: String(albums.length), href: "#library-albums" },
    { id: "songs", label: t.library.sectionSongs, icon: <MusicNotesIcon size={20} />, detail: String(tracks.length), href: "#library-songs" },
    { id: "downloaded", label: t.library.sectionDownloaded, icon: <DownloadSimpleIcon size={20} />, detail: "0", href: "#library-downloaded" },
  ];

  const tileClass = "grid grid-cols-3 gap-x-3 gap-y-4 px-4 md:grid-cols-6 lg:grid-cols-9 md:px-6";

  return (
    <div className="pb-8">
      <Header />

      {pinned.length > 0 && (
        <ul className={`${tileClass} pt-3`}>
          {pinned.map((item) => (
            <li key={item.key}>{item.node}</li>
          ))}
        </ul>
      )}

      <LibraryGroups rows={rows} />

      {recentlyAdded.length > 0 && (
        <section className="pt-7">
          <SectionTitle title={t.library.recentlyAdded} detail={String(recentlyAdded.length)} />
          <ul className="no-scrollbar mt-3 flex snap-x snap-mandatory gap-3 overflow-x-auto px-4 pb-1 md:scroll-px-6 md:px-6">
            {recentlyAdded.map((track, i) => (
              <li key={track.id} className="w-[42vw] max-w-[220px] shrink-0 snap-start">
                <button type="button" onClick={() => playList(recentlyAdded, i)} className="group block w-full text-left">
                  <span className="relative block overflow-hidden rounded-[14px]">
                    <Artwork src={track.art} fallback={track.thumb} className="aspect-square w-full" />
                    <span className="absolute right-2 bottom-2 grid size-9 translate-y-1 place-items-center rounded-full bg-black/55 text-white opacity-0 backdrop-blur-sm transition-[opacity,transform] duration-200 ease-out-expo group-hover:translate-y-0 group-hover:opacity-100 group-focus-visible:translate-y-0 group-focus-visible:opacity-100">
                      <PlayIcon size={16} weight="fill" />
                    </span>
                  </span>
                  <span className="mt-2 block truncate text-sm font-semibold">{track.title}</span>
                  <span className="block truncate text-xs text-fg-2">{track.artist}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <ChartCard
        tracks={history}
        title={t.library.top100}
        subtitle={t.library.top100Sub(history.length)}
        onPlay={(_track, position) => playList(history, position)}
      />

      <section id="library-playlists" className="scroll-mt-28 pt-8">
        <SectionTitle title={t.library.sectionPlaylists} />
        <ul className={`${tileClass} mt-3`}>
          <li>
            <PlaylistTile to={paths.favorites} name={t.nav.favorites} kind="favorites" tracks={favorites} />
          </li>
          <li>
            <PlaylistTile to={paths.history} name={t.nav.recentlyPlayed} kind="history" tracks={history} />
          </li>
          {playlists.map((p) => (
            <li key={p.id}>
              <PlaylistTile to={paths.playlist(p.id)} name={p.name} kind="playlist" tracks={p.tracks} />
            </li>
          ))}
        </ul>
        {playlists.length === 0 && <p className="px-4 pt-4 text-sm text-fg-2 md:px-6">{t.library.noPlaylists}</p>}
      </section>

      {artists.length > 0 && (
        <section id="library-artists" className="scroll-mt-28 pt-8">
          <SectionTitle title={t.library.sectionArtists} detail={String(artists.length)} />
          <ul className="no-scrollbar mt-4 flex snap-x gap-4 overflow-x-auto px-4 pb-1 md:scroll-px-6 md:px-6">
            {artists.map((artist) => (
              <li key={artist.name} className="w-24 shrink-0 snap-start">
                <ArtistTile artist={artist} />
              </li>
            ))}
          </ul>
        </section>
      )}

      {albums.length > 0 && (
        <section id="library-albums" className="scroll-mt-28 pt-8">
          <SectionTitle title={t.library.sectionAlbums} detail={String(albums.length)} />
          <ul className="mt-3 grid grid-cols-2 gap-x-3 gap-y-5 px-4 sm:grid-cols-3 md:px-6 lg:grid-cols-5 2xl:grid-cols-7">
            {albums.slice(0, 14).map((album) => (
              <li key={album.name}>
                <Link to={searchTo(`${album.name} ${album.artist}`.trim(), "albums")} className="group block min-w-0">
                  <Artwork
                    src={album.art}
                    fallback={album.thumb}
                    className="aspect-square w-full rounded-[14px] transition-transform duration-300 ease-out-expo group-hover:scale-[1.03]"
                  />
                  <span className="mt-2 block truncate text-sm font-semibold">{album.name}</span>
                  <span className="block truncate text-xs text-fg-2">{album.artist}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      {tracks.length > 0 && (
        <section id="library-songs" className="scroll-mt-28 pt-8">
          <SectionTitle title={t.library.sectionSongs} detail={String(tracks.length)} />
          <div className="mt-2 px-2 md:px-3">
            <TrackList tracks={tracks.slice(0, 12)} context={tracks} header={false} />
          </div>
          {tracks.length > 12 && (
            <Link to={paths.history} className="ml-6 mt-2 inline-flex items-center gap-0.5 text-sm font-medium text-fg-2 hover:text-fg">
              {t.home.seeAll} <CaretRightIcon size={14} weight="bold" />
            </Link>
          )}
        </section>
      )}

      <section id="library-downloaded" className="scroll-mt-28 pt-8">
        <SectionTitle title={t.library.sectionDownloaded} detail="0" />
        <div className="mx-4 mt-3 flex items-center gap-3 rounded-[16px] bg-surface-1 p-4 ring-1 ring-line md:mx-6">
          <span className="grid size-10 shrink-0 place-items-center rounded-full bg-surface-3 text-fg-2">
            <DownloadSimpleIcon size={20} />
          </span>
          <span className="min-w-0">
            <span className="block text-[15px] font-medium">{t.library.noDownloadsTitle}</span>
            <span className="block text-sm text-fg-2">{t.library.noDownloads}</span>
          </span>
        </div>
      </section>

      {favorites.length === 0 && playlists.length === 0 && history.length === 0 && (
        <div className="mx-4 mt-6 flex items-center gap-3 rounded-[16px] bg-surface-2 p-4 ring-1 ring-line md:mx-6">
          <span className="grid size-10 shrink-0 place-items-center rounded-full bg-accent-soft text-accent-text">
            <HeartIcon size={20} />
          </span>
          <div className="min-w-0">
            <p className="text-[15px] font-semibold">{t.library.emptyTitle}</p>
            <p className="text-sm text-fg-2">{t.library.emptyBody}</p>
          </div>
          <Link to={paths.search} className="ml-auto shrink-0 rounded-full bg-surface-3 px-4 py-2 text-sm font-medium hover:bg-surface-4">
            {t.common.searchMusic}
          </Link>
        </div>
      )}
    </div>
  );
}
