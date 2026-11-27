# Lyrics edition (based on v1.5.1)

Open Now Playing on a phone and tap the speech-bubble lyrics button below the
transport controls. On desktop, use the same button in the player bar or the
Lyrics tab in the right panel.

## Included

- An album-art-colored, softly animated full-screen lyrics surface on phones.
- Large current-line highlighting, smooth follow scrolling, and instrumental
  markers, all driven by the existing player clock (including native iOS events).
- Tap a line to seek. Paused playback stays paused.
- Scroll to browse; following resumes after six seconds or with the explicit
  “Back to current line” button.
- Half-second timing adjustments, up to ten seconds in either direction, for
  the current lyrics view. Positive values show the lyrics earlier.
- Persistent playback controls, English/Portuguese labels, keyboard controls,
  reduced-motion behavior, and right-to-left text support.
- Plain-lyrics, instrumental, no-match, loading, connection-error and rate-limit
  states. Videos show plain lyrics because their edit may not match the recording.
- LRCLIB attribution and a bounded, seven-day cache of up to 40 matches, including
  offline reuse. Missing results expire after 15 minutes; errors are not cached.

## Provider and matching

Lyrics come directly from the public HTTPS LRCLIB API. No key or Musike server
change is required. Native builds use Capacitor HTTP; browser/desktop builds use
the provider's CORS-enabled API. Requests identify Musike, run sequentially,
leave at least 250 ms between calls, and respect Retry-After plus jitter.

Exact lookup uses title, artist, album and duration, then a structured search
fallback. The client additionally checks normalized title/artist and a maximum
three-second duration difference. It preserves live/remix/acoustic version labels
to avoid silently showing another recording's lyrics.

This implementation uses real **line-level LRC timestamps**, not estimated
word timing. Apple Music's proprietary lyrics catalog, Sing vocal reduction,
translations, pronunciation and duet/word-by-word rendering are not included.
Not every song has matching lyrics in LRCLIB.

## Verification

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm --filter @musike/web test:lyrics
pnpm --filter @musike/web exec playwright install chromium
pnpm --filter @musike/web test:lyrics-ui
pnpm --filter @musike/web build
pnpm --filter @musike/web build:native
```

Unit tests cover LRC parsing, timeline boundaries, recording matching and lookup
failures. Browser tests exercise phone/desktop layouts, smaller screens, both
themes, seek/follow/timing controls, real HTML audio time updates, plain lyrics,
track-switch races, retry, rate limiting and cached offline access. Provider
responses in the automated tests are fixtures, so tests do not call LRCLIB.

## iOS packaging on Linux

The upstream v1.5.1 IPA is unsigned and contains the native Capacitor shell plus
its web assets. This change needs no native code or plugin update. After building
the native web bundle, it can be packaged into a **separate custom unsigned IPA**:

```sh
python3 mobile/scripts/repack-lyrics-ipa.py \
  ~/Downloads/Musike-Setup-1.5.1-iOS.ipa \
  ~/Downloads/Musike-1.5.1-Lyrics-iOS.ipa
```

The script requires the original release SHA-256, preserves the original bridge
files and native resources, verifies their bytes, checks all replacement assets
and tests ZIP integrity. It refuses to overwrite an existing output. It does not
compile Swift, change native dependencies, or sign the app. Use the normal
`mobile/scripts/build-ipa.mjs` on macOS for changes that require native rebuilding.

Install the custom IPA with a signing/sideloading tool such as AltStore or
Sideloadly. Browser testing does not verify installation, WebKit rendering or
native playback on an actual iPhone; those still require device testing.
