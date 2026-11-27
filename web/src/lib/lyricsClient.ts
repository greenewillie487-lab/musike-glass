import { Capacitor, CapacitorHttp } from "@capacitor/core";
import { isLyricsRecord, resolveLyrics, type LyricsRecord } from "./lyrics";
import type { Track } from "./types";

const CACHE_KEY = "musike:lyrics:v1";
type Entry = { key: string; expires: number; record: LyricsRecord | null };
let cache: Entry[] = [];
try {
  const saved: unknown = JSON.parse(localStorage.getItem(CACHE_KEY) ?? "[]");
  if (Array.isArray(saved)) cache = saved.filter((e): e is Entry =>
    e && typeof e.key === "string" && Number.isFinite(e.expires) && e.expires > Date.now()
    && (e.record === null || isLyricsRecord(e.record)),
  ).slice(-40);
} catch { /* Lyrics also work with storage disabled. */ }

// Serialize lookups from the phone sheet and desktop panel, and honor provider backoff globally.
let queue: Promise<unknown> = Promise.resolve();
let nextRequest = 0;
let retryAt = 0;

export class LyricsRateLimit extends Error {}

/** Milliseconds left in the provider's backoff, or 0 when another request is allowed. */
export function getLyricsRetryAfter(): number {
  return Math.max(0, retryAt - Date.now());
}

async function request(path: string, signal: AbortSignal): Promise<unknown> {
  signal.throwIfAborted();
  if (Date.now() < retryAt) throw new LyricsRateLimit();
  await new Promise((resolve) => setTimeout(resolve, Math.max(0, nextRequest - Date.now())));
  signal.throwIfAborted();
  const url = `https://lrclib.net/api${path}`;
  const headers = { "Lrclib-Client": `Musike/${__APP_VERSION__} (https://github.com/Ernani1234/musike)` };
  let status: number;
  let body: unknown;
  let retry: string | undefined;
  try {
    if (Capacitor.isNativePlatform()) {
      const res = await CapacitorHttp.get({ url, headers, responseType: "json", connectTimeout: 12000, readTimeout: 12000 });
      status = res.status;
      body = res.data;
      retry = Object.entries(res.headers).find(([key]) => key.toLowerCase() === "retry-after")?.[1];
    } else {
      const controller = new AbortController();
      const abort = () => controller.abort();
      signal.addEventListener("abort", abort, { once: true });
      const timeout = setTimeout(abort, 12000);
      try {
        const res = await fetch(url, { headers, signal: controller.signal });
        status = res.status;
        retry = res.headers.get("retry-after") ?? undefined;
        body = res.ok ? await res.json() : null;
      } finally {
        clearTimeout(timeout);
        signal.removeEventListener("abort", abort);
      }
    }
  } finally {
    nextRequest = Date.now() + 250;
  }
  if (status === 429 || status === 503) {
    const seconds = retry && /^\d+$/.test(retry) ? Number(retry) : retry ? (Date.parse(retry) - Date.now()) / 1000 : 60;
    retryAt = Date.now() + Math.max(1, Number.isFinite(seconds) ? seconds : 60) * 1000 * (1 + Math.random() * 0.3);
    throw new LyricsRateLimit();
  }
  signal.throwIfAborted();
  if (status === 404) return null;
  if (status < 200 || status >= 300) throw new Error(`Lyrics HTTP ${status}`);
  return body;
}

export function loadLyrics(track: Track, signal: AbortSignal): Promise<LyricsRecord | null> {
  const key = JSON.stringify([track.id, track.title, track.artist, track.album, track.duration]);
  const run = async () => {
    signal.throwIfAborted();
    const hit = cache.find((e) => e.key === key && e.expires > Date.now());
    if (hit) return hit.record;
    const record = await resolveLyrics(track, (path) => request(path, signal));
    signal.throwIfAborted();
    cache = [...cache.filter((e) => e.key !== key && e.expires > Date.now()), {
      key, record, expires: Date.now() + (record ? 7 * 24 * 60 * 60_000 : 15 * 60_000),
    }].slice(-40);
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(cache)); } catch { /* cache is optional */ }
    return record;
  };
  const result = queue.then(run, run);
  queue = result.catch(() => {});
  return result;
}
