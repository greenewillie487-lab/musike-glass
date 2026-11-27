import type { Track } from "./types";

export interface LyricLine {
  time: number;
  text: string;
}

export interface LyricsRecord {
  id: number;
  trackName: string;
  artistName: string;
  albumName: string;
  duration: number;
  instrumental: boolean;
  plainLyrics: string | null;
  syncedLyrics: string | null;
}

/** Keep version labels (live, remix, acoustic): they can have completely different timings. */
export function cleanTitle(title: string): string {
  return title.replace(/\s*[([](?:official\s+)?(?:audio|music video|video|lyric video|lyrics)[)\]]/gi, "").trim();
}

const normalize = (s: string) => s.normalize("NFKC").toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

export function isLyricsRecord(value: unknown): value is LyricsRecord {
  if (!value || typeof value !== "object") return false;
  const r = value as LyricsRecord;
  return Number.isFinite(r.id) && typeof r.trackName === "string" && typeof r.artistName === "string"
    && typeof r.albumName === "string" && Number.isFinite(r.duration) && typeof r.instrumental === "boolean"
    && (r.plainLyrics === null || typeof r.plainLyrics === "string")
    && (r.syncedLyrics === null || typeof r.syncedLyrics === "string");
}

/** Parse standard LRC, including repeated timestamps, empty interludes and millisecond offsets. */
export function parseLrc(text: string): LyricLine[] {
  const offset = Number(text.match(/\[offset:\s*([+-]?\d+)\]/i)?.[1] ?? 0) / 1000;
  const lines: LyricLine[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const stamps = [...raw.matchAll(/\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]/g)];
    if (!stamps.length) continue;
    // Enhanced LRC word markers are removed rather than shown as visible markup.
    const lyric = raw.slice(stamps.at(-1)!.index! + stamps.at(-1)![0].length)
      .replace(/<\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?>/g, "").trim();
    for (const stamp of stamps) {
      const time = Number(stamp[1]) * 60 + Number(stamp[2]) + Number(`0.${stamp[3] ?? "0"}`) + offset;
      lines.push({ time: Math.max(0, time), text: lyric });
    }
  }
  // Combine simultaneous lines, preserving duets/translations without a zero-length active line.
  const merged: LyricLine[] = [];
  for (const line of lines.sort((a, b) => a.time - b.time)) {
    const prev = merged.at(-1);
    if (prev?.time === line.time) {
      if (line.text && !prev.text.split("\n").includes(line.text)) prev.text = [prev.text, line.text].filter(Boolean).join("\n");
    } else merged.push({ ...line });
  }
  return merged.some((line) => line.text) ? merged : [];
}

/** Last line at or before the actual player clock; works equally for forwards/backwards seeks. */
export function activeLineAt(lines: LyricLine[], position: number): number {
  let low = 0;
  let high = lines.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (lines[mid].time <= position) low = mid + 1;
    else high = mid;
  }
  return low - 1;
}

export function matchLyrics(records: LyricsRecord[], track: Track): LyricsRecord | null {
  const candidates = records.filter((r) =>
    normalize(cleanTitle(r.trackName)) === normalize(cleanTitle(track.title))
    && normalize(r.artistName) === normalize(track.artist.replace(/\s*-\s*Topic$/i, ""))
    && (!(track.duration > 0) || Math.abs(r.duration - track.duration) <= 3)
    && (r.instrumental || r.plainLyrics?.trim() || r.syncedLyrics?.trim()),
  );
  const score = (r: LyricsRecord) =>
    (normalize(r.albumName) === normalize(track.album ?? "") ? 4 : 0)
    + (r.syncedLyrics ? 2 : 0) - (track.duration > 0 ? Math.abs(r.duration - track.duration) / 10 : 0);
  return candidates.sort((a, b) => score(b) - score(a))[0] ?? null;
}

export type LyricsRequest = (path: string) => Promise<unknown>;

export async function resolveLyrics(track: Track, request: LyricsRequest): Promise<LyricsRecord | null> {
  if (!track.title.trim() || !track.artist.trim()) return null;
  const query = new URLSearchParams({
    track_name: cleanTitle(track.title),
    artist_name: track.artist.replace(/\s*-\s*Topic$/i, "").trim(),
  });
  const exact = new URLSearchParams(query);
  if (track.album) exact.set("album_name", track.album);
  if (track.duration >= 1 && track.duration <= 3600) exact.set("duration", String(track.duration));
  const result = await request(`/get?${exact}`);
  const found = isLyricsRecord(result) ? matchLyrics([result], track) : null;
  if (found) return found;
  const results = await request(`/search?${query}`);
  if (!Array.isArray(results)) throw new Error("Invalid lyrics response");
  return matchLyrics(results.filter(isLyricsRecord), track);
}
