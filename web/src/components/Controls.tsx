import {
  AirplayIcon,
  HeartIcon,
  InfinityIcon,
  MusicNotesIcon,
  PauseIcon,
  PlayIcon,
  RepeatIcon,
  RepeatOnceIcon,
  ShuffleIcon,
  SkipBackIcon,
  SkipForwardIcon,
  SpeakerHighIcon,
  SpeakerLowIcon,
  SpeakerXIcon,
  StarIcon,
  VideoCameraIcon,
} from "@phosphor-icons/react";
import { useState } from "react";
import { useShallow } from "zustand/react/shallow";
import { useT } from "../i18n";
import { capabilities } from "../lib/api";
import { cn, formatTime } from "../lib/format";
import type { Track } from "../lib/types";
import { usePlayer } from "../player/player";
import { useLibrary } from "../stores/library";
import { useUi } from "../stores/ui";
import { IconButton, PlayDisc } from "./IconButton";
import { Slider } from "./Slider";

/** Frosted glass used by the Now Playing sheet's quick actions and icon circles. */
export const glassCircle = "bg-fg/10 ring-1 ring-fg/15 backdrop-blur-xl shadow-[inset_0_1px_0_rgb(255_255_255/0.18)]";
export const glassPill = "bg-fg/8 ring-1 ring-fg/12 backdrop-blur-xl shadow-[inset_0_1px_0_rgb(255_255_255/0.14)]";

export function PlayPauseIcon({ size = 22 }: { size?: number }) {
  const status = usePlayer((s) => s.status);
  if (status === "loading") {
    return <span className="block size-[18px] animate-spin rounded-full border-2 border-current border-t-transparent" />;
  }
  return status === "playing" ? <PauseIcon size={size} weight="fill" /> : <PlayIcon size={size} weight="fill" />;
}

export function Transport({
  big = false,
  minimal = false,
  discClassName,
  discPx,
}: {
  big?: boolean;
  /** Hide shuffle/repeat when they live in the quick-action pill row instead. */
  minimal?: boolean;
  discClassName?: string;
  /** Override the play disc diameter (short landscape screens use a smaller disc). */
  discPx?: number;
}) {
  const t = useT();
  const p = usePlayer(
    useShallow((s) => ({
      hasQueue: s.queue.length > 0,
      status: s.status,
      shuffle: s.shuffle,
      repeat: s.repeat,
      toggle: s.toggle,
      prev: s.prev,
      next: s.next,
      toggleShuffle: s.toggleShuffle,
      cycleRepeat: s.cycleRepeat,
    })),
  );
  const hasTrack = p.hasQueue;
  const RepeatGlyph = p.repeat === "one" ? RepeatOnceIcon : RepeatIcon;
  const repeatLabel = { off: t.player.repeatOff, all: t.player.repeatAll, one: t.player.repeatOne }[p.repeat];
  const iconSize = big ? 26 : 19;

  return (
    <div className={cn("flex items-center", big ? (minimal ? "justify-around" : "justify-between") : "gap-2")}>
      {!minimal && (
        <IconButton
          label={p.shuffle ? t.player.shuffleOn : t.player.shuffleOff}
          active={p.shuffle}
          size={big ? "lg" : "sm"}
          onClick={p.toggleShuffle}
          disabled={!hasTrack}
        >
          <ShuffleIcon size={big ? 22 : 17} />
          {p.shuffle && <span className="absolute bottom-0.5 size-1 rounded-full bg-accent-text" />}
        </IconButton>
      )}
      <IconButton label={t.player.previous} size={big ? "lg" : "md"} onClick={p.prev} disabled={!hasTrack} className="text-fg">
        <SkipBackIcon size={iconSize} weight="fill" />
      </IconButton>
      <PlayDisc
        label={p.status === "playing" ? t.common.pause : t.common.play}
        px={discPx ?? (big ? 72 : 40)}
        onClick={p.toggle}
        disabled={!hasTrack}
        className={discClassName}
      >
        <PlayPauseIcon size={big ? 30 : 20} />
      </PlayDisc>
      <IconButton label={t.player.next} size={big ? "lg" : "md"} onClick={p.next} disabled={!hasTrack} className="text-fg">
        <SkipForwardIcon size={iconSize} weight="fill" />
      </IconButton>
      {!minimal && (
        <IconButton
          label={repeatLabel}
          active={p.repeat !== "off"}
          size={big ? "lg" : "sm"}
          onClick={p.cycleRepeat}
          disabled={!hasTrack}
        >
          <RepeatGlyph size={big ? 22 : 17} />
          {p.repeat !== "off" && <span className="absolute bottom-0.5 size-1 rounded-full bg-accent-text" />}
        </IconButton>
      )}
    </div>
  );
}

export function Scrubber({ touch = false, className }: { touch?: boolean; className?: string }) {
  const t = useT();
  const position = usePlayer((s) => s.position);
  const duration = usePlayer((s) => s.duration);
  const buffered = usePlayer((s) => s.buffered);
  const seek = usePlayer((s) => s.seek);
  const [scrub, setScrub] = useState<number | null>(null);
  const shown = scrub ?? position;

  const time = <span className="w-10 shrink-0 font-mono text-[11px] text-fg-3 tabular-nums">{formatTime(shown)}</span>;
  const total = <span className="w-10 shrink-0 text-right font-mono text-[11px] text-fg-3 tabular-nums">{formatTime(duration)}</span>;

  if (touch) {
    return (
      <div className={className}>
        <Slider label={t.player.progress} value={position} max={duration} buffered={buffered} onChange={seek} onScrub={setScrub} showThumb step={5} valueText={formatTime} />
        <div className="mt-0.5 flex justify-between">
          {time}
          {total}
        </div>
      </div>
    );
  }
  return (
    <div className={cn("flex items-center gap-2", className)}>
      <span className="text-right">{time}</span>
      <Slider label={t.player.progress} value={position} max={duration} buffered={buffered} onChange={seek} onScrub={setScrub} step={5} valueText={formatTime} className="flex-1" />
      {total}
    </div>
  );
}

export function Volume({ className, wide = false }: { className?: string; wide?: boolean }) {
  const t = useT();
  const volume = usePlayer((s) => s.volume);
  const muted = usePlayer((s) => s.muted);
  const setVolume = usePlayer((s) => s.setVolume);
  const toggleMute = usePlayer((s) => s.toggleMute);
  const level = muted ? 0 : volume;
  const Glyph = level === 0 ? SpeakerXIcon : level < 0.5 ? SpeakerLowIcon : SpeakerHighIcon;
  return (
    <div className={cn("flex items-center", wide ? "gap-2" : "gap-1", className)}>
      <IconButton label={muted ? t.player.unmute : t.player.mute} size="sm" onClick={toggleMute}>
        <Glyph size={wide ? 20 : 18} />
      </IconButton>
      <Slider
        label={t.player.volume}
        value={level}
        max={1}
        step={0.05}
        live
        onChange={setVolume}
        valueText={(v) => `${Math.round(v * 100)}%`}
        className={wide ? "min-w-0 flex-1" : "w-24"}
      />
      {wide && <SpeakerHighIcon size={18} className="shrink-0 text-fg-3" aria-hidden="true" />}
    </div>
  );
}

type MediaPicker = HTMLMediaElement & {
  webkitShowPlaybackTargetPicker?: () => void;
  remote?: { prompt?: () => Promise<void> | void };
};

/** AirPlay uses the platform picker when available; elsewhere it reports that no output is available. */
export function AirplayButton({ className, large = false }: { className?: string; large?: boolean }) {
  const toast = useUi((s) => s.toast);
  const open = () => {
    const media = document.querySelector<MediaPicker>("audio, video");
    if (media?.webkitShowPlaybackTargetPicker) return media.webkitShowPlaybackTargetPicker();
    if (media?.remote?.prompt) return void media.remote.prompt();
    toast("AirPlay", "info");
  };
  return (
    <button
      type="button"
      aria-label="AirPlay"
      title="AirPlay"
      onClick={open}
      className={cn(large ? "size-11" : "size-9", "grid shrink-0 place-items-center rounded-full text-fg-2 transition-colors hover:text-fg", className)}
    >
      <AirplayIcon size={19} />
    </button>
  );
}

/** The four frosted quick actions above the track list in the Now Playing sheet. */
export function QuickActions({ className }: { className?: string }) {
  const t = useT();
  const p = usePlayer(
    useShallow((s) => ({
      hasQueue: s.queue.length > 0,
      shuffle: s.shuffle,
      repeat: s.repeat,
      autoRadio: s.autoRadio,
      toggleShuffle: s.toggleShuffle,
      cycleRepeat: s.cycleRepeat,
      setAutoRadio: s.setAutoRadio,
    })),
  );
  const RepeatGlyph = p.repeat === "one" ? RepeatOnceIcon : RepeatIcon;
  const repeatLabel = { off: t.player.repeatOff, all: t.player.repeatAll, one: t.player.repeatOne }[p.repeat];
  const pill = (on: boolean) =>
    cn(
      "grid h-9 min-w-0 flex-1 place-items-center rounded-full transition-colors duration-200",
      glassPill,
      on ? "bg-fg/20 text-fg" : "text-fg-2 hover:bg-fg/15 hover:text-fg",
    );

  return (
    <div role="group" aria-label={t.player.mode} className={cn("flex w-full items-center gap-2", className)}>
      <button
        type="button"
        aria-label={p.shuffle ? t.player.shuffleOn : t.player.shuffleOff}
        aria-pressed={p.shuffle}
        disabled={!p.hasQueue}
        onClick={p.toggleShuffle}
        className={pill(p.shuffle)}
      >
        <ShuffleIcon size={18} />
      </button>
      <button
        type="button"
        aria-label={repeatLabel}
        aria-pressed={p.repeat !== "off"}
        disabled={!p.hasQueue}
        onClick={p.cycleRepeat}
        className={pill(p.repeat !== "off")}
      >
        <RepeatGlyph size={18} />
      </button>
      <button
        type="button"
        aria-label={t.queue.autoRadio}
        aria-pressed={p.autoRadio}
        title={t.queue.autoRadio}
        onClick={() => p.setAutoRadio(!p.autoRadio)}
        className={pill(p.autoRadio)}
      >
        <InfinityIcon size={20} />
      </button>
      <AirplayButton className={cn("flex-1", glassPill)} />
    </div>
  );
}

export function FavoriteButton({
  track,
  size = "md",
  star = false,
  glass = false,
}: {
  track: Track | null;
  size?: "sm" | "md" | "lg";
  /** Apple Music uses a star for the current song; other surfaces keep the heart. */
  star?: boolean;
  glass?: boolean;
}) {
  const isFavorite = useLibrary((s) => !!track && s.favorites.some((t) => t.id === track.id));
  const toggle = useLibrary((s) => s.toggleFavorite);
  const t = useT();
  const Glyph = star ? StarIcon : HeartIcon;
  return (
    <IconButton
      label={isFavorite ? t.common.removeFromFavorites : t.common.addToFavorites}
      active={isFavorite}
      size={size}
      disabled={!track}
      onClick={() => track && void toggle(track)}
      className={glass ? cn(glassCircle, isFavorite ? "text-fg" : "text-fg-2 hover:text-fg") : undefined}
    >
      <Glyph size={size === "lg" ? 24 : 19} weight={isFavorite ? "fill" : "regular"} />
    </IconButton>
  );
}

/** Audio / Video segmented switch. For songs, Video plays the song's music video when YouTube has one. */
export function ModeSwitch({ className }: { className?: string }) {
  const t = useT();
  const preferVideo = usePlayer((s) => s.preferVideo);
  const setPreferVideo = usePlayer((s) => s.setPreferVideo);
  const quality = usePlayer((s) => s.quality);
  const setQuality = usePlayer((s) => s.setQuality);
  const showingVideo = usePlayer((s) => s.mediaKind === "video");
  // The Android app plays audio only for now.
  if (!capabilities.video) return null;

  const seg = (on: boolean) =>
    cn(
      "flex h-9 items-center gap-1.5 rounded-full px-3.5 text-[13px] font-medium transition-colors duration-200",
      on ? "bg-surface-4 text-fg shadow-[inset_0_1px_0_var(--highlight)]" : "text-fg-2 hover:text-fg",
    );

  return (
    <div className={cn("flex items-center gap-2", className)}>
      <div role="radiogroup" aria-label={t.player.mode} className="flex rounded-full bg-surface-1 p-1 ring-1 ring-line">
        <button type="button" role="radio" aria-checked={!preferVideo} className={seg(!preferVideo)} onClick={() => setPreferVideo(false)}>
          <MusicNotesIcon size={15} /> {t.player.audio}
        </button>
        <button
          type="button"
          role="radio"
          aria-checked={preferVideo}
          className={seg(preferVideo)}
          onClick={() => setPreferVideo(true)}
          title={t.player.watchClip}
        >
          <VideoCameraIcon size={15} /> {t.player.video}
        </button>
      </div>
      {showingVideo && (
        <button
          type="button"
          onClick={() => setQuality(quality === "sd" ? "hd" : "sd")}
          title={quality === "sd" ? t.player.toHd : t.player.toSd}
          className={cn(
            "h-9 rounded-full px-3 font-mono text-[12px] font-semibold ring-1 transition-colors",
            quality === "hd" ? "bg-accent-soft text-accent-text ring-accent/40" : "text-fg-2 ring-line hover:text-fg",
          )}
        >
          {quality === "hd" ? "HD" : "SD"}
        </button>
      )}
    </div>
  );
}
