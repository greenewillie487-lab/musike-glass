/**
 * Apple Music-style live charts for Home and New: Apple's public RSS charts, fetched through the
 * app's `musikeLive` bridge (the RSS host sends no CORS headers, so only native code can read it),
 * cached briefly in localStorage, with the baked Ghana fallback for when the network is unreachable.
 */
import { api } from "./api";
import { usePlayer } from "../player/player";
import type { Track } from "./types";

export interface ChartItem {
  name: string;
  artistName: string;
  artworkUrl100: string;
  releaseDate?: string;
}

export interface Charts {
  topSongs: ChartItem[];
  ghanaSongs: ChartItem[];
  nigeriaSongs: ChartItem[];
  topAlbums: ChartItem[];
}

const CACHE_KEY = "musike:charts:v2";
const TTL = 3 * 60 * 60 * 1000;
const TIMEOUT = 10000;

const FEEDS: Record<keyof Charts, string> = {
  topSongs: "https://rss.marketingtools.apple.com/api/v2/us/music/most-played/50/songs.json",
  ghanaSongs: "https://rss.marketingtools.apple.com/api/v2/gh/music/most-played/50/songs.json",
  nigeriaSongs: "https://rss.marketingtools.apple.com/api/v2/ng/music/most-played/50/songs.json",
  topAlbums: "https://rss.marketingtools.apple.com/api/v2/us/music/most-played/50/albums.json",
};

interface LiveBridge {
  postMessage(message: unknown): void;
}

const live = (globalThis as { webkit?: { messageHandlers?: { musikeLive?: LiveBridge } } }).webkit
  ?.messageHandlers?.musikeLive;

const pending = new Map<string, (json: string) => void>();
let wired = false;

function wire() {
  if (wired || !live) return;
  wired = true;
  (globalThis as { __musikeLiveResult?: (id: string, json: string) => void }).__musikeLiveResult = (id, json) => {
    pending.get(id)?.(json);
    pending.delete(id);
  };
}

function fetchFeed(url: string): Promise<ChartItem[] | null> {
  if (!live) return Promise.resolve(null);
  wire();
  const id = `chart-${Math.random().toString(36).slice(2)}`;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve(null);
    }, TIMEOUT);
    pending.set(id, (json) => {
      clearTimeout(timer);
      try {
        const data = JSON.parse(json) as { feed?: { results?: ChartItem[] } };
        resolve(data.feed?.results ?? null);
      } catch {
        resolve(null);
      }
    });
    live.postMessage({ id, url });
  });
}

/** The baked Ghana chart: what Home showed before the live feed existed. */
async function ghanaFallback(): Promise<ChartItem[] | null> {
  try {
    const res = await fetch("chart-fallback.json");
    if (!res.ok) return null;
    const data = (await res.json()) as { results?: ChartItem[] };
    return data.results ?? null;
  } catch {
    return null;
  }
}

export async function loadCharts(): Promise<Charts | null> {
  try {
    const cached = localStorage.getItem(CACHE_KEY);
    if (cached) {
      const c = JSON.parse(cached) as { at: number; charts: Charts };
      if (Date.now() - c.at < TTL) return c.charts;
    }
  } catch {
    /* an unreadable cache is just refetched */
  }
  const once = (key: keyof Charts): Promise<ChartItem[] | null> =>
    fetchFeed(FEEDS[key]).then((r) => r ?? fetchFeed(FEEDS[key]));
  const [topSongs, ghanaSongs, nigeriaSongs, topAlbums] = await Promise.all([
    once("topSongs"),
    once("ghanaSongs").then((r) => r ?? ghanaFallback()),
    once("nigeriaSongs"),
    once("topAlbums"),
  ]);
  const charts: Charts = {
    topSongs: topSongs ?? [],
    ghanaSongs: ghanaSongs ?? [],
    nigeriaSongs: nigeriaSongs ?? [],
    topAlbums: topAlbums ?? [],
  };
  const any = Object.values(charts).some((list) => list.length > 0);
  if (!any) return null;
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), charts }));
  } catch {
    /* storage may be unavailable; the feed is refetched next time */
  }
  return charts;
}

/** A chart entry as a displayable track; playback resolves the real stream by search. */
export function chartTrack(item: ChartItem, i: number): Track {
  return {
    id: `chart-${item.name}-${i}`,
    title: item.name,
    artist: item.artistName,
    duration: 0,
    thumb: item.artworkUrl100,
    art: item.artworkUrl100.replace("100x100bb", "600x600bb"),
    kind: "song",
  };
}

/** Resolves a chart entry to a real, playable track through the app's own search. */
export async function playChartSong(item: ChartItem): Promise<boolean> {
  try {
    const found = await api.search(`${item.name} ${item.artistName}`.trim(), "song");
    if (found.length > 0) {
      usePlayer.getState().playList(found, 0);
      return true;
    }
  } catch {
    /* the caller falls back to the search page */
  }
  return false;
}
