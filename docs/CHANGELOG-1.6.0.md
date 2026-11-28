# Zidon (Musike fork) 1.6.0 — changelog vs Musike-iOS27-PlaybackFix.ipa

Every change below is built from source (`pnpm --filter web build --mode native` → rsync into
the native shell → unsigned device IPA via Codemagic `ios-native-glass`). The engine —
playback, YouTube sourcing, LRCLIB time-synced lyrics, queue, favorites/playlists — is
**untouched**; this release is entirely looks and native chrome, as agreed ("looks are the
product").

## Pages rebuilt from source (Phase 3)
- **Home**: Apple-shaped rails (half-screen tiles), feature card from real library/history,
  "Stations for You" from live genre data; opaque sticky header; the old "Start with search"
  empty-state card removed — Home goes straight into content like Apple Music.
- **Artist**: real hero page (full-bleed artwork, album metadata, play/shuffle controls,
  track list) reached through real search results — no more "Invalid artist" empty state.
- **Now Playing**: glass control surfaces + lyrics fixes (retry countdown during LRCLIB
  backoff, `-webkit-backdrop-filter` so blur survives iOS ≤ 17).
- **Library**: inset grouped lists (Playlists/Artists/Albums/Songs/Downloaded), Favorites and
  Recently played tiles, counts.
- **New**: built from scratch — press-style feed of large feature cards (hero artwork, glass
  play/radio/ellipsis circles), genre sections, opaque sticky header.

## Native chrome
- **Real Liquid Glass kept**: native `UITabBar` + `UIGlassEffect` miniplayer, colorless glass,
  red only on the selected glyph/label.
- **Tab bar is now Home / New / Library / Search** (Radio removed per request); correct
  Library glyph (`music.quarternote.3`), 16pt glyphs sized to sit fully inside the active
  glass pill, near-full-height highlight capsule.
- **Bars sit low**: miniplayer + tab bar anchored 10pt above the physical screen edge (Apple
  floating-bar placement) instead of floating 42pt up.
- **Whole-chrome scroll collapse fixed and verified**: chrome (miniplayer + tab bar as one
  unit) translates 10pt down and fades to 75% as you scroll any page, then restores on
  scroll-back. Root cause of it being dead since the overlay removal: the app scrolls its own
  internal `<main>` element, so the old `webView.scrollView` KVO never fired — replaced with a
  bridge scroll-message feed (single writer preserved); spurious WebKit zero-offset KVO
  callbacks that silently reset the collapse were eliminated.
- **One chrome**: the duplicate web tab bar / miniplayer stay hidden; native Home overlay
  removed (web Home is the only Home) — ghost titles, "S" bleed-through and rail slivers gone.

## Look
- **Accent recolored from Musike lime (#c3ec52) to Apple Music red (#fa243d)** — matched
  exactly to the native chrome tint; dark/light theme text variants re-derived (WCAG); the
  old green is no longer the default anywhere and was removed from the settings swatches
  ("Apple Red" replaces "Volt").
- Search page: single translucent-white focus border (no accent rim), Genres pill kept.

## Under the hood (no user-visible change)
- Web bundle built from source in CI and hash-verified against the local build; pre-paint
  theme/accent migration preserved; accent migration also clears a stored old-green choice so
  it cannot resurrect.
- Preview/capture harness: verified route navigation (retry until the SPA confirms the route),
  blank-capture retry inside CI, New-page scroll evidence.
- Version 1.5.1 → **1.6.0** (build 10600).

## Known leftovers (polish, next pass)
- Scrolled New page can still ghost its title under the status bar (real-inset sticky needs a
  device-context pass).
- Branding pass pending: app icon, display name → Zidon, "musike" chips on cards (assets
  already prepared).

## Verification summary
- Simulator captures (dark/light/scrolled/New/Library/Search/Artist) eye-audited against the
  target screenshots; scroll collapse pixel-verified: translate +30px (=10pt @3x), fade
  195/255 = 0.76 (spec 0.75).
- Typecheck clean (web + native configs); lyrics Playwright suite green.
