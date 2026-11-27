# OLD APPROACH — DO NOT SHIP

This directory is an archival copy of `MusikeGlass-LiquidGlass-source.zip`, kept for
reference only. It contains the earlier CSS/JS skin approach (`apple-skin.css`,
`apple-behavior.js`, `apple-icons.js`) and an incomplete native prototype
(`Sources/GlassViewController.swift`; `SceneDelegate.swift` references a missing
`GlassTabBarController`).

It is NOT imported by the web build, NOT copied into the IPA, and NOT part of the
current native Liquid Glass implementation. The shipped implementation lives in
`mobile/ios/App/App/MusikeWebViewController.swift` and the `ios-native-glass`
workflow in `codemagic.yaml`.

Everything below is the original README from the old zip, preserved verbatim for
reference.

---

# MusikeGlass

A native iOS 26/27 wrapper around the reskinned Musike web app. It uses Apple's
real Liquid Glass (`UIGlassEffect`) for the bottom tab bar and mini-player,
hosted in `WKWebView`.

## Build (free, no Mac needed)

1. Create an empty **public** GitHub repository.
2. Upload this folder's contents to it (or push with git).
3. In the repo, open **Actions** → **Build Liquid Glass IPA** → **Run workflow**.
4. When the job finishes, download the `MusikeGlass-LiquidGlass` artifact and
   unzip it to get `MusikeGlass-LiquidGlass.ipa`.
5. Sideload that IPA with siboot / SideInstaller using your Apple Account.

The build is unsigned. Signing happens on the phone, as with the earlier IPAs.

## What it changes

- Native `UITabBar` with `UIGlassEffect(style: .regular)` — real Liquid Glass,
  not a CSS blur. Active tab tinted Apple Music red.
- Native glass mini-player above the tab bar.
- Web app served through `musike://app/` so its history routes keep working.
- The web skin's own bottom bars and player are hidden; the native ones replace them.

Bundle id: `app.musike.glass` (separate from the original app).
Deployment target: iOS 26.0.
