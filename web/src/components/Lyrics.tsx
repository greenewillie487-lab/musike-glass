import { ChatTextIcon, MusicNotesIcon } from "@phosphor-icons/react";
import { useReducedMotion } from "motion/react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useI18n, useT } from "../i18n";
import { formatTime } from "../lib/format";
import { activeLineAt, parseLrc, type LyricsRecord } from "../lib/lyrics";
import { getLyricsRetryAfter, loadLyrics, LyricsRateLimit } from "../lib/lyricsClient";
import type { Track } from "../lib/types";
import { usePlayer } from "../player/player";

export function LyricsBackdrop({ track }: { track: Track }) {
  const playing = usePlayer((s) => s.status === "playing");
  return (
    <div className="lyrics-backdrop" aria-hidden="true" data-playing={playing}>
      <img key={track.thumb} src={track.thumb} alt="" />
      <div />
    </div>
  );
}

/** Keyed by track at the call site: old lyrics and scroll state never flash on the next song. */
export function Lyrics({ track }: { track: Track }) {
  const t = useT().lyrics;
  const lang = useI18n((s) => s.lang);
  const position = usePlayer((s) => s.position);
  const status = usePlayer((s) => s.status);
  const mediaKind = usePlayer((s) => s.mediaKind);
  const seek = usePlayer((s) => s.seek);
  const reduce = useReducedMotion();
  const [result, setResult] = useState<LyricsRecord | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "error" | "limited">("loading");
  const [attempt, setAttempt] = useState(0);
  const [following, setFollowing] = useState(true);
  const [retryLeft, setRetryLeft] = useState(0);
  const [offset, setOffset] = useState(0);
  const [adjusting, setAdjusting] = useState(false);
  const viewport = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const resumeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    setState("loading");
    loadLyrics(track, controller.signal).then(
      (record) => { if (!controller.signal.aborted) { setResult(record); setState("ready"); } },
      (err) => { if (!controller.signal.aborted) setState(err instanceof LyricsRateLimit ? "limited" : "error"); },
    );
    return () => controller.abort();
  }, [track, attempt]);

  useEffect(() => () => { if (resumeTimer.current) clearTimeout(resumeTimer.current); }, []);

  // LRCLIB's Retry-After is global, so mirror the shared backoff instead of hammering it.
  useEffect(() => {
    if (state !== "limited") {
      setRetryLeft(0);
      return;
    }
    const tick = () => setRetryLeft(getLyricsRetryAfter());
    tick();
    const timer = setInterval(tick, 500);
    return () => clearInterval(timer);
  }, [state, attempt, lang]);

  const lines = useMemo(() => parseLrc(result?.syncedLyrics ?? ""), [result]);
  // A music video can have an intro/edit different from the album recording. Don't pretend it is synced.
  const synced = lines.length > 0 && mediaKind !== "video";
  const active = activeLineAt(lines, position + offset);
  const center = () => {
    const node = list.current?.querySelector<HTMLElement>(`[data-line="${Math.max(0, active)}"]`);
    const scroller = viewport.current;
    if (node && scroller) scroller.scrollTo({
      top: node.offsetTop - scroller.clientHeight * 0.32,
      behavior: reduce ? "instant" : "smooth",
    });
  };

  useLayoutEffect(() => {
    if (!synced || !following) return;
    center();
    const observer = new ResizeObserver(center);
    if (viewport.current) observer.observe(viewport.current);
    return () => observer.disconnect();
  }, [active, synced, following, reduce, lines]);

  const browse = () => {
    if (!synced) return;
    setFollowing(false);
    if (resumeTimer.current) clearTimeout(resumeTimer.current);
    resumeTimer.current = setTimeout(() => setFollowing(true), 6000);
  };
  const resume = () => {
    if (resumeTimer.current) clearTimeout(resumeTimer.current);
    setFollowing(true);
    center();
  };
  const plain = result?.plainLyrics?.trim() || lines.map((line) => line.text).join("\n");
  const empty = !result || (!lines.length && !plain);

  return (
    <section className="lyrics-view" aria-label={t.title} data-following={following} data-playing={status === "playing"}>
      {state === "loading" ? (
        <div className="lyrics-state" role="status">
          <div className="lyrics-skeleton" aria-hidden="true"><i /><i /><i /></div>
          <p>{t.loading}</p>
        </div>
      ) : state === "error" || state === "limited" ? (
        <div className="lyrics-state" role="status">
          <ChatTextIcon size={34} /><h3>{t.error}</h3>
          <p>{state === "limited" ? t.limited : t.errorBody}</p>
          {state === "limited" && retryLeft > 0 && (
            <p className="lyrics-backoff" aria-live="polite">
              {new Intl.RelativeTimeFormat(lang, { numeric: "always" }).format(Math.ceil(retryLeft / 1000), "second")}
            </p>
          )}
          <button className="lyrics-pill" onClick={() => setAttempt((n) => n + 1)}>{t.retry}</button>
        </div>
      ) : result?.instrumental || empty ? (
        <div className="lyrics-state" role="status">
          <MusicNotesIcon size={36} /><h3>{result?.instrumental ? t.instrumental : t.unavailable}</h3>
          <p>{result?.instrumental ? t.instrumentalBody : t.unavailableBody}</p>
        </div>
      ) : (
        <>
          <div className="lyrics-caption">
            <span>{synced ? t.live : mediaKind === "video" && lines.length ? t.video : t.plain}</span>
            {synced && <button aria-expanded={adjusting} onClick={() => setAdjusting(!adjusting)}>{t.timing}</button>}
          </div>
          {adjusting && synced && (
            <div className="lyrics-timing" role="group" aria-label={t.timing}>
              <button aria-label={t.later} disabled={offset <= -10} onClick={() => setOffset((n) => Math.max(-10, n - 0.5))}>−</button>
              <output aria-live="polite">{offset > 0 ? "+" : ""}{offset.toFixed(1)} s</output>
              <button aria-label={t.earlier} disabled={offset >= 10} onClick={() => setOffset((n) => Math.min(10, n + 0.5))}>+</button>
              <button onClick={() => setOffset(0)}>{t.reset}</button>
            </div>
          )}
          <div
            ref={viewport}
            className="lyrics-scroll"
            tabIndex={0}
            aria-label={synced ? t.seekHint : t.title}
            onWheel={browse}
            onTouchStart={browse}
            onTouchMove={browse}
            onPointerDown={browse}
            onKeyDown={(e) => { if (["ArrowDown", "ArrowUp", "PageDown", "PageUp", "Home", "End", "Tab"].includes(e.key)) browse(); }}
          >
            <div ref={list} className="lyrics-lines">
              {synced ? (
                <>
                  {active < 0 && <div className="lyrics-intro" aria-label={t.intro}><span /><span /><span /></div>}
                  {lines.map((line, i) => (
                    <button
                      key={`${line.time}-${i}`}
                      type="button"
                      dir="auto"
                      data-line={i}
                      data-active={i === active}
                      data-past={i < active}
                      aria-current={i === active ? "true" : undefined}
                      aria-label={t.seekTo(line.text || t.interlude, formatTime(line.time))}
                      className="lyric-line"
                      onClick={() => { seek(Math.max(0, line.time - offset)); resume(); }}
                    >
                      {line.text || <span className="lyrics-dots" aria-hidden="true"><i /><i /><i /></span>}
                    </button>
                  ))}
                </>
              ) : <p className="lyrics-plain" dir="auto">{plain}</p>}
              <p className="lyrics-credit">{t.credit}</p>
            </div>
          </div>
          <div className="lyrics-follow">
            {synced && !following ? <button className="lyrics-pill" onClick={resume}>{t.resume}</button> : <span>{synced ? t.seekHint : t.credit}</span>}
          </div>
        </>
      )}
    </section>
  );
}
