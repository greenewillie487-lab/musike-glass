import Capacitor
import UIKit
import WebKit

/// Small singleton so the Capacitor plugin can reach the glass views owned by the web view controller.
private final class NativeGlass {
    static let shared = NativeGlass()
    weak var host: MusikeWebViewController?
}

/// Full-screen chrome container. Passes touches through everywhere except its
/// real glass children so the web view below stays interactive.
private final class ChromeContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The web app posts its appearance mode here. Native forwards system changes back
/// through the exact callback the original bundle already defines.
private final class AppearanceHandler: NSObject, WKScriptMessageHandler {
    weak var controller: MusikeWebViewController?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let mode = body["mode"] as? String else { return }
        controller?.setAppearance(mode)
    }
}

/// Keeps the native tab highlight in sync with the web app's router.
private final class RouteHandler: NSObject, WKScriptMessageHandler {
    weak var controller: MusikeWebViewController?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let path = message.body as? String else { return }
        // The page scrolls its own <main> scroller, so webView.scrollView's
        // contentOffset never moves on a user scroll. The bridge reports the
        // internal scroller's offset as "scroll:<n>"; it feeds the SAME
        // scroll master (no direct chrome writes), keeping one writer.
        if path.hasPrefix("scroll:") {
            let y = Double(path.dropFirst("scroll:".count)) ?? 0
            DispatchQueue.main.async { [weak controller] in
                controller?.applyScrollMaster(offsetY: CGFloat(y))
            }
            return
        }
        controller?.setRoute(path)
    }
}

/// Fetches Apple's public chart feed natively so the web bundle is not blocked by CORS.
private final class LiveFeedHandler: NSObject, WKScriptMessageHandler {
    weak var controller: MusikeWebViewController?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              url.host == "rss.marketingtools.apple.com" else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.controller?.deliverLiveFeed(id: id, json: json) }
        }.resume()
    }
}

/// Restores the original GlassPlayer bridge. The web bundle already calls these four
/// methods; nothing in the web app is modified to make this work.
@objc(GlassPlayerPlugin)
final class GlassPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    let identifier = "GlassPlayerPlugin"
    let jsName = "GlassPlayer"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setTrack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPlaying", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disable", returnType: CAPPluginReturnPromise)
    ]

    @objc func setTrack(_ call: CAPPluginCall) {
        NativeGlass.shared.host?.setTrack(
            title: call.getString("title"),
            artist: call.getString("artist"),
            artwork: call.getString("artwork"),
            duration: call.getDouble("duration") ?? 0
        )
        call.resolve()
    }

    @objc func setPlaying(_ call: CAPPluginCall) {
        NativeGlass.shared.host?.setPlaying(
            playing: call.getBool("playing") ?? false,
            progress: call.getDouble("progress") ?? 0
        )
        call.resolve()
    }

    @objc func enable(_ call: CAPPluginCall) {
        NativeGlass.shared.host?.setGlassEnabled(true)
        call.resolve()
    }

    @objc func disable(_ call: CAPPluginCall) {
        NativeGlass.shared.host?.setGlassEnabled(false)
        call.resolve()
    }
}

/// Your original Capacitor wrapper plus real iOS 27 Liquid Glass chrome.
/// No web assets, icons, plist keys, routes or app logic are changed.
final class MusikeWebViewController: CAPBridgeViewController, UITabBarDelegate, UIGestureRecognizerDelegate {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let appearanceHandler = AppearanceHandler()
    private let routeHandler = RouteHandler()
    private let liveFeedHandler = LiveFeedHandler()

    private let tabBar = UITabBar(frame: .zero)
    private let miniGlass = UIVisualEffectView(frame: .zero)
    private let miniArtwork = UIImageView()
    private let idleNoteLabel = UILabel()
    private let miniTitle = UILabel()
    private let miniArtist = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progressBar = UIView()
    private var progressWidthConstraint: NSLayoutConstraint?
    private let activePill = UIVisualEffectView(frame: .zero)
    private let activePillTint = UIView()
    private var tabBarBottomConstraint: NSLayoutConstraint?
    /// One stored container for the whole fixed-size chrome (tab bar + mini
    /// player). Scroll only translates/fades this unit; no subview is added,
    /// removed or resized while scrolling.
    private let chromeContainer = ChromeContainerView()
    private static let tabGlyphs: [(normal: String, selected: String, title: String, key: String)] = [
        ("house", "house", "Home", "home"),
        ("square.grid.2x2", "square.grid.2x2", "New", "new"),
        ("music.quarternote.3", "music.quarternote.3", "Library", "library"),
        ("magnifyingglass", "magnifyingglass", "Search", "search")
    ]
    /// ONE fixed glyph configuration and ONE fixed label font for every scroll
    /// state. Apple does not rescale tab glyphs/labels as the bar collapses.
    private static let tabSymbolConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    private static let tabLabelFont = UIFont.systemFont(ofSize: 10, weight: .medium)
    private let compactTitleLabel = UILabel()
    private let compactTitleBackground = UIView()
    private var compactTitleTopConstraint: NSLayoutConstraint?
    /// Single source of truth for native title/chrome state. Derived from the
    /// active scroll view's contentOffset; no boolean collapse flag and no
    /// accumulated delta, so the title tracks position continuously.
    private var scrollProgress: CGFloat = 0
    private var previewScrollOffset: CGFloat = 0
    private var previewNewTab = false
    private var previewRoute: String?
    /// Preview-only: a search-results preview must follow a real artist link
    /// instead of opening a hard-coded id that may not exist in the catalog.
    private var previewArtistTap = false
    private var previewLight = false
    private var previewSeedHistory = false
    private var isObservingScroll = false

    private var appearanceMode = "system"
    private var isPlaying = false
    /// Native glass chrome is shown only while the web app has it enabled.
    private var glassEnabled = true

    private static let fallbackChartJSON = #"""
{"feed":{"results":[{"name":"Faith","artistName":"Kweku Smoke & Lasmid","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/5b/ca/ac/5bcaac2e-2329-567b-0445-29efd7e03bee/766214704508.jpg/100x100bb.jpg","releaseDate":"2026-08-28"},{"name":"Bra","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"BALOTELLI (SUPA)","artistName":"Kofi Mole","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/4f/e9/71/4fe971a6-1d64-0669-30a1-378a97ea0ded/artwork.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Bombele","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Survivor","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"IKEBE 3000","artistName":"Blaqbonez & Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/08/0e/f2/080ef21a-3bad-70b4-ccd8-3221a87a09f3/1200220133765.jpg/100x100bb.jpg","releaseDate":"2026-09-23"},{"name":"Forgiveness","artistName":"Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/31/e4/eb/31e4ebf4-97bd-c193-59c7-1b72ed7ab53a/ticket.wlorjbae.jpg/100x100bb.jpg","releaseDate":"2026-04-30"},{"name":"B4 B4","artistName":"Davido, FOLA & Mayorkun","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a8/fb/21/a8fb21ed-2106-199e-75dc-f01099c29394/196874507544.jpg/100x100bb.jpg","releaseDate":"2026-07-31"},{"name":"Soul Healer","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Home","artistName":"Kwesi Arthur","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/7c/0a/a9/7c0aa928-9ace-a09f-d173-5c3776593926/711641194057.jpg/100x100bb.jpg","releaseDate":"2026-11-19"},{"name":"Halleluyah","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Gratitude","artistName":"Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/31/e4/eb/31e4ebf4-97bd-c193-59c7-1b72ed7ab53a/ticket.wlorjbae.jpg/100x100bb.jpg","releaseDate":"2026-04-30"},{"name":"GEN Z II (feat. AratheJay)","artistName":"Fameye, Joey B & Sarkodie","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/3e/cb/04/3ecb04a9-3f9c-54ed-b819-57e2d4b953d5/0.jpg/100x100bb.jpg","releaseDate":"2026-11-12"},{"name":"REPAIR","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Okwantunii","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"WHY LOVE","artistName":"Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/18/65/07/186507c9-146c-473c-6eae-e4cf689c7357/197342969963_cover.jpg/100x100bb.jpg","releaseDate":"2025-02-12"},{"name":"SAVE ME","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Power House","artistName":"Kweku Smoke & Kwesi Arthur","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Mmereniho","artistName":"Kweku Smoke & Dikoo","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"FAMAME","artistName":"AratheJay","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/1f/95/9c/1f959cdd-8435-49a4-7b30-3d0908ce9fd1/823375337447_cover.jpg/100x100bb.jpg","releaseDate":"2026-07-31"},{"name":"Life Of A Hustler","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"ME NSAN","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"K\u0186K\u0186SAKYI","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Gen Z","artistName":"Fameye","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/af/9c/c1/af9cc14f-0da1-509b-0878-396cc78c9162/0.jpg/100x100bb.jpg","releaseDate":"2026-07-24"},{"name":"Yawa (Hosanna)","artistName":"Kwesi Arthur","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/36/83/04/36830411-d153-4138-217a-8ccd67c44598/199976556083.jpg/100x100bb.jpg","releaseDate":"2026-02-06"},{"name":"Hold Tight","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/a4/1e/c5/a41ec5ec-cc25-b1a6-b2c8-43f9a68a1905/757572950423.jpg/100x100bb.jpg","releaseDate":"2023-09-01"},{"name":"Young Boy","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/16/17/72/16177275-88ac-f797-48a6-b57c8801a9ba/766214662181.jpg/100x100bb.jpg","releaseDate":"2024-03-08"},{"name":"Signature","artistName":"KiDi & Lasmid","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/ab/82/c4/ab82c4fa-424b-67a2-2547-adb87fd7bd33/820233047104.jpg/100x100bb.jpg","releaseDate":"2026-04-30"},{"name":"Chanel (feat. Asake)","artistName":"Blaqbonez","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/0c/19/fc/0c19fcea-bd03-8ad3-6245-03a58ec40a00/8718521271213.jpg/100x100bb.jpg","releaseDate":"2026-05-21"},{"name":"No Days Off","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"SWAGGA","artistName":"Black Sherif","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/c6/d3/84/c6d384e6-ef16-fd9c-57de-58332def802b/199316628746_cover.jpg/100x100bb.jpg","releaseDate":"2026-05-28"},{"name":"WOUNDED LION (WASN'T GIFTED)","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Liquor Store","artistName":"Lasmid","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/42/aa/b0/42aab058-b8a7-d163-6cba-c67803ad74dd/0.jpg/100x100bb.jpg","releaseDate":"2026-08-21"},{"name":"Forever (feat. AratheJay)","artistName":"Black Sherif","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4b/dc/7c/4bdc7c0a-1905-baf7-5efb-cae0b544f6a8/199316713701_cover.jpg/100x100bb.jpg","releaseDate":"2026-09-03"},{"name":"Jolie","artistName":"Black Sherif","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4b/dc/7c/4bdc7c0a-1905-baf7-5efb-cae0b544f6a8/199316713701_cover.jpg/100x100bb.jpg","releaseDate":"2026-09-03"},{"name":"Through The Pain","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Set it Straight","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"CLARITY STONES","artistName":"O'Kenneth, JT700 & SRT Gwalla","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"TIMES LIKE THIS","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Jah Guide","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/16/17/72/16177275-88ac-f797-48a6-b57c8801a9ba/766214662181.jpg/100x100bb.jpg","releaseDate":"2024-03-08"}]}}
"""#

    private let activeColor = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
    private var currentPath = "/"
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?

    private let routes = ["/", "/new", "/library", "/search"]

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        NativeGlass.shared.host = self
        bridge?.registerPluginInstance(GlassPlayerPlugin())

        webView?.configuration.userContentController.add(playback, name: "musikeMedia")
        webView?.configuration.userContentController.add(youtube, name: "musikeResolve")
        webView?.configuration.userContentController.add(audio, name: "musikeAudio")
        webView?.configuration.userContentController.add(appearanceHandler, name: "musikeAppearance")
        webView?.configuration.userContentController.add(routeHandler, name: "musikeRoute")
        webView?.configuration.userContentController.add(liveFeedHandler, name: "musikeLive")
        appearanceHandler.controller = self
        routeHandler.controller = self
        liveFeedHandler.controller = self
        playback.attach(webView)
        youtube.attach(webView)
        audio.attach(webView)
        webView?.allowsBackForwardNavigationGestures = true

        installBridgeScript()
        installGlassChrome()
        applyAppearance()
        postRoute()
        setRoute("/")
        readPreviewArguments()
        // Web Home is the only Home: the WKWebView scroll view is the sole
        // scroll master, so no second scroll view is observed.
        webView?.scrollView.addObserver(self, forKeyPath: "contentOffset", options: [.initial, .new], context: nil)
        isObservingScroll = true
        applyPreviewState()
    }

    // MARK: - Native Liquid Glass

    private func liquidGlassEffect() -> UIVisualEffect {
        if #available(iOS 26, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            return effect
        }
        return UIBlurEffect(style: .systemUltraThinMaterial)
    }

    private func installGlassChrome() {
        miniGlass.effect = liquidGlassEffect()
        miniGlass.layer.cornerRadius = 28
        miniGlass.layer.masksToBounds = true
        miniGlass.translatesAutoresizingMaskIntoConstraints = false

        // A real UITabBar linked with the Xcode 27 SDK gets Apple's automatic
        // Liquid Glass material. Do not override it with a custom effect.
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        tabBar.isTranslucent = true
        tabBar.backgroundColor = .clear
        tabBar.layer.cornerRadius = 32
        tabBar.layer.masksToBounds = true
        tabBar.tintColor = activeColor
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        // Kill any inherited opaque bar background so colorless glass can refract content.
        tabAppearance.backgroundImage = UIImage()
        tabAppearance.shadowImage = UIImage()
        // Fixed label font in every layout; red only on the selected icon/label.
        for layout in [
            tabAppearance.stackedLayoutAppearance,
            tabAppearance.inlineLayoutAppearance,
            tabAppearance.compactInlineLayoutAppearance
        ] {
            layout.normal.titleTextAttributes[.font] = Self.tabLabelFont
            layout.normal.titleTextAttributes[.foregroundColor] = UIColor.secondaryLabel
            layout.normal.iconColor = .secondaryLabel
            layout.selected.titleTextAttributes[.font] = Self.tabLabelFont
            layout.selected.titleTextAttributes[.foregroundColor] = activeColor
            layout.selected.iconColor = activeColor
        }
        tabBar.standardAppearance = tabAppearance
        tabBar.scrollEdgeAppearance = tabAppearance
        tabBar.unselectedItemTintColor = .secondaryLabel
        tabBar.layer.backgroundColor = UIColor.clear.cgColor

        installActivePill()
        buildTabBar()
        buildMiniPlayer()

        view.addSubview(chromeContainer)
        chromeContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chromeContainer.topAnchor.constraint(equalTo: view.topAnchor),
            chromeContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        chromeContainer.addSubview(tabBar)
        chromeContainer.addSubview(miniGlass)

        compactTitleLabel.text = "Home"
        compactTitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        compactTitleLabel.textColor = .label
        compactTitleLabel.alpha = 0
        compactTitleBackground.alpha = 0
        compactTitleBackground.backgroundColor = .systemBackground
        compactTitleBackground.isUserInteractionEnabled = false
        compactTitleBackground.translatesAutoresizingMaskIntoConstraints = false
        compactTitleLabel.isUserInteractionEnabled = false
        compactTitleLabel.accessibilityIdentifier = "native-compact-home-title"
        compactTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Below the glass chrome container.
        view.insertSubview(compactTitleLabel, belowSubview: chromeContainer)
        view.insertSubview(compactTitleBackground, belowSubview: compactTitleLabel)
        NSLayoutConstraint.activate([
            compactTitleBackground.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            compactTitleBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            compactTitleBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            compactTitleBackground.heightAnchor.constraint(equalToConstant: 44)
        ])

        let guide = view.safeAreaLayoutGuide
        // Anchor to the physical bottom (10pt inset) like Apple's floating
        // glass bar, not the safe-area bottom, so the capsule does not float
        // far above the home indicator.
        let bottom = tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        let tabHeight = tabBar.heightAnchor.constraint(equalToConstant: 64)
        let compactTop = compactTitleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 0)
        compactTitleTopConstraint = compactTop
        tabBarBottomConstraint = bottom
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bottom,
            tabHeight,

            miniGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            miniGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            miniGlass.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -8),
            miniGlass.heightAnchor.constraint(equalToConstant: 56),

            compactTop,
            compactTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])
    }

    private func buildTabBar() {
        // Home 0, New 1, Library 2, Search 3.
        var tabItems: [UITabBarItem] = []
        for glyph in Self.tabGlyphs {
            let tabItem = UITabBarItem(
                title: glyph.title,
                image: UIImage(systemName: glyph.normal, withConfiguration: Self.tabSymbolConfig),
                selectedImage: UIImage(systemName: glyph.selected, withConfiguration: Self.tabSymbolConfig)
            )
            tabItem.tag = tabItems.count
            tabItem.accessibilityIdentifier = "glass-tab-\(glyph.key)"
            tabItems.append(tabItem)
        }
        tabBar.items = tabItems
        setActiveTab(0)
    }

    /// The selected tab sits in a colorless glass pill behind the real tab
    /// button (never a flat rect and never a replacement for UITabBar).
    /// Its red accent comes only from the selected icon + label.
    private func installActivePill() {
        activePill.translatesAutoresizingMaskIntoConstraints = false
        activePill.isUserInteractionEnabled = false
        activePill.effect = liquidGlassEffect()
        activePill.backgroundColor = .clear
        activePill.contentView.backgroundColor = .clear
        activePill.layer.masksToBounds = true
        activePill.layer.borderWidth = 0.5
        activePill.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        // Neutral white only: no red/tinted fill. Color comes from artwork behind the glass.
        activePillTint.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        activePillTint.translatesAutoresizingMaskIntoConstraints = false
        activePill.contentView.addSubview(activePillTint)
        NSLayoutConstraint.activate([
            activePillTint.topAnchor.constraint(equalTo: activePill.contentView.topAnchor),
            activePillTint.leadingAnchor.constraint(equalTo: activePill.contentView.leadingAnchor),
            activePillTint.trailingAnchor.constraint(equalTo: activePill.contentView.trailingAnchor),
            activePillTint.bottomAnchor.constraint(equalTo: activePill.contentView.bottomAnchor)
        ])
        tabBar.addSubview(activePill)
        raisePillAboveTabBackground()
    }

    /// UIKit can reinsert its bar background on every layout pass. Keep the
    /// colorless glass layers above it and below the real tab buttons.
    private func raisePillAboveTabBackground() {
        let backgroundIndex = tabBar.subviews.firstIndex(where: {
            NSStringFromClass($0.classForCoder).contains("Background")
        })
        let index = (backgroundIndex ?? -1) + 1
        tabBar.insertSubview(activePill, at: min(index, tabBar.subviews.count))
    }

    private func setActiveTab(_ index: Int) {
        guard let items = tabBar.items, items.indices.contains(index) else { return }
        tabBar.selectedItem = items[index]
        layoutActivePill()
    }

    private func layoutActivePill() {
        guard let items = tabBar.items, let selected = tabBar.selectedItem,
              let index = items.firstIndex(where: { $0 === selected }) else {
            activePill.isHidden = true
            return
        }
        let bounds = tabBar.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        activePill.isHidden = false
        let buttons = tabBar.subviews.filter { NSStringFromClass($0.classForCoder).contains("UITabBarButton") }
        let slot: CGRect
        if buttons.count == items.count, buttons.indices.contains(index), buttons[index].frame.width > 0 {
            slot = buttons[index].frame
        } else {
            let slotWidth = bounds.width / CGFloat(items.count)
            slot = CGRect(x: CGFloat(index) * slotWidth, y: 0, width: slotWidth, height: bounds.height)
        }
        let maxWidth = max(40, bounds.width / CGFloat(items.count) - 8)
        let width = min(max(40, slot.width * 0.86), maxWidth)
        // Tab metrics are fixed at every scroll state, so the highlight keeps
        // its size and simply tracks the selected button frame. Near-full-height
        // pill so the glyph + label sit fully inside the glass highlight (the
        // icon stack rides high inside UITabBarButton).
        let height = max(28, min(slot.height - 4, bounds.height - 4))
        activePill.frame = CGRect(x: slot.midX - width / 2, y: (bounds.height - height) / 2,
                                  width: width, height: height)
        activePill.layer.cornerRadius = height / 2
        activePillTint.layer.cornerRadius = height / 2
        raisePillAboveTabBackground()
        for view in tabBar.subviews where NSStringFromClass(view.classForCoder).contains("UITabBarButton") {
            tabBar.bringSubviewToFront(view)
        }
    }

    private func buildMiniPlayer() {
        progressBar.backgroundColor = UIColor.label.withAlphaComponent(0.45)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        miniGlass.contentView.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: miniGlass.contentView.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: miniGlass.contentView.leadingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])

        miniArtwork.clipsToBounds = true
        miniArtwork.translatesAutoresizingMaskIntoConstraints = false
        idleNoteLabel.text = "♪"
        idleNoteLabel.font = .systemFont(ofSize: 22, weight: .regular)
        idleNoteLabel.textAlignment = .center
        idleNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        miniArtwork.addSubview(idleNoteLabel)
        NSLayoutConstraint.activate([
            idleNoteLabel.centerXAnchor.constraint(equalTo: miniArtwork.centerXAnchor),
            idleNoteLabel.centerYAnchor.constraint(equalTo: miniArtwork.centerYAnchor)
        ])
        setIdleArtwork(true)

        miniTitle.text = "Not Playing"
        miniTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        miniTitle.textColor = .label
        miniArtist.font = .systemFont(ofSize: 11, weight: .regular)
        miniArtist.textColor = .secondaryLabel
        let labels = UIStackView(arrangedSubviews: [miniTitle, miniArtist])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        nextButton.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        playButton.tintColor = .label
        nextButton.tintColor = .label
        playButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        playButton.accessibilityLabel = "Play"
        nextButton.accessibilityLabel = "Next"

        let stack = UIStackView(arrangedSubviews: [miniArtwork, labels, playButton, nextButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        miniGlass.contentView.addSubview(stack)
        let miniTap = UITapGestureRecognizer(target: self, action: #selector(openNowPlaying))
        miniTap.delegate = self
        miniTap.cancelsTouchesInView = false
        miniGlass.addGestureRecognizer(miniTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(miniPanned(_:)))
        pan.delegate = self
        miniGlass.addGestureRecognizer(pan)
        let widthConstraint = progressBar.widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
        progressWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: miniGlass.contentView.topAnchor, constant: 5),
            stack.leadingAnchor.constraint(equalTo: miniGlass.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: miniGlass.contentView.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: miniGlass.contentView.bottomAnchor, constant: -5),

            miniArtwork.widthAnchor.constraint(equalToConstant: 44),
            miniArtwork.heightAnchor.constraint(equalToConstant: 44),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.widthAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func setIdleArtwork(_ idle: Bool) {
        miniArtwork.layer.cornerRadius = 10
        if idle {
            miniArtwork.image = nil
            miniArtwork.tintColor = nil
            miniArtwork.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.28, alpha: 1)
                    : UIColor.systemGray5
            }
            miniArtwork.contentMode = .center
            idleNoteLabel.isHidden = false
            idleNoteLabel.textColor = .label
        } else {
            miniArtwork.tintColor = nil
            miniArtwork.backgroundColor = .clear
            miniArtwork.contentMode = .scaleAspectFill
            idleNoteLabel.isHidden = true
        }
    }

    // MARK: - Web bridge

    private func installBridgeScript() {
        let css = """
        nav.safe-bottom.fixed.inset-x-0.bottom-0 { display: none !important; }
        div.fixed.inset-x-2[class*="bottom-[calc(72px"] { display: none !important; }
        main { padding-bottom: 160px !important; }
        """
        let source = """
        (function(){
          var css = \(jsString(css));
          function inject(){
            if(document.head){
              var style = document.getElementById('musike-native-glass');
              if(!style){ style = document.createElement('style'); style.id='musike-native-glass'; document.head.appendChild(style); }
              style.textContent = css;
            } else { setTimeout(inject, 0); }
          }
          inject();

          function postRoute(){
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.musikeRoute;
            if(h) h.postMessage((location.pathname || '/') + (location.search || '') + (location.hash || ''));
          }
          var push = history.pushState, replace = history.replaceState;
          history.pushState = function(){ var r = push.apply(this, arguments); postRoute(); return r; };
          history.replaceState = function(){ var r = replace.apply(this, arguments); postRoute(); return r; };
          window.addEventListener('popstate', postRoute);
          // The app scrolls its internal <main> scroller (html/body are
          // height:100%), so WKScrollView contentOffset never moves on a user
          // scroll. Report the real offset so the native chrome collapse
          // tracks page scrolling. Capture phase catches the scroller's
          // non-bubbling scroll events even before React mounts.
          document.addEventListener('scroll', function(e){
            var t = e.target;
            if (t && t.nodeType === 1 && t.matches && t.matches('main.scroll-area')) {
              var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.musikeRoute;
              if (h) h.postMessage('scroll:' + Math.round(t.scrollTop));
            }
          }, { passive: true, capture: true });
          document.addEventListener('DOMContentLoaded', postRoute);
          postRoute();
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView?.configuration.userContentController.addUserScript(script)
        webView?.evaluateJavaScript(source)
    }

    func deliverLiveFeed(id: String, json: String) {
        let js = "window.__musikeLiveResult && window.__musikeLiveResult(\(jsString(id)), \(jsString(json)));"
        webView?.evaluateJavaScript(js)
    }

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let text = String(data: data, encoding: .utf8)!
        return String(text.dropFirst().dropLast())
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        let index = item.tag
        guard routes.indices.contains(index) else { return }
        navigate(to: routes[index])
    }

    private func navigate(to route: String) {
        let js = "history.pushState({}, '', \(jsString(route))); window.dispatchEvent(new PopStateEvent('popstate'));"
        webView?.evaluateJavaScript(js)
    }

    /// Preview navigation that survives a slow first page commit: a fixed +4s
    /// one-shot silently dies when the document is still provisional, which is
    /// why a working capture can break on the next identical run. Poll until
    /// the web app confirms it is on the route (the SPA keeps its document, so
    /// one successful pushState + popstate is enough; React Router picks up a
    /// pre-mount URL change when it initializes).
    private func navigateVerified(to route: String, attempts: Int = 24) {
        guard attempts > 0 else { return }
        let path = route.components(separatedBy: "?").first ?? route
        let js = """
        (function(){
          if (document.getElementById('root')) {
            history.pushState({}, '', \(jsString(route)));
            window.dispatchEvent(new PopStateEvent('popstate'));
            return location.pathname;
          }
          return '';
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            let landed = (result as? String)?.hasPrefix(path) ?? false
            DispatchQueue.main.async {
                if !landed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                        self?.navigateVerified(to: route, attempts: attempts - 1)
                    }
                }
            }
        }
    }

    func setRoute(_ url: String) {
        if (previewNewTab || previewRoute != nil) && (url == "/" || url.isEmpty) { return }
        let clean = url.components(separatedBy: "#").first ?? "/"
        let path = clean.components(separatedBy: "?").first ?? "/"
        currentPath = path
        let sheetOpen = url.contains("#now-playing")
        // A route change always starts with the compact title fully hidden.
        // Route through the scroll master so it stays the only runtime writer.
        applyScrollMaster(offsetY: 0)
        tabBar.isHidden = sheetOpen
        miniGlass.isHidden = sheetOpen
        if sheetOpen { return }
        if path == "/new" { setActiveTab(1); return }
        if path.hasPrefix("/search") { setActiveTab(3) }
        else if path.hasPrefix("/library") || path.hasPrefix("/favorites") ||
                path.hasPrefix("/history") || path.hasPrefix("/playlist") { setActiveTab(2) }
        else { setActiveTab(0) }
    }

    private func postRoute() {
        webView?.evaluateJavaScript("(function(){var h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.musikeRoute;if(h)h.postMessage((location.pathname||'/')+(location.search||'')+(location.hash||''));})();")
    }

    @objc private func playTapped() {
        let action = isPlaying ? "pause" : "play"
        webView?.evaluateJavaScript("window.__musikeMediaAction && window.__musikeMediaAction('\(action)');")
    }

    @objc private func nextTapped() {
        webView?.evaluateJavaScript("window.__musikeMediaAction && window.__musikeMediaAction('next');")
    }

    @objc private func openNowPlaying() {
        let js = """
        (function(){
          var h = window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.musikeRoute;
          var buttons = document.querySelectorAll('button');
          for (var i = 0; i < buttons.length; i++) {
            var label = buttons[i].getAttribute('aria-label') || '';
            if (label.indexOf('Open Now playing:') === 0) {
              buttons[i].click();
              setTimeout(function(){
                if (h) h.postMessage((location.pathname || '/') + (location.search || '') + (location.hash || ''));
              }, 50);
              return;
            }
          }
          history.pushState({ idx: (window.history.state?.idx ?? 0) + 1 }, '', '#now-playing');
          window.dispatchEvent(new PopStateEvent('popstate'));
          setTimeout(function(){
            if (h) h.postMessage((location.pathname || '/') + (location.search || '') + (location.hash || ''));
          }, 0);
        })();
        """
        webView?.evaluateJavaScript(js)
    }

    // MARK: - GlassPlayer plugin calls

    func setGlassEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glassEnabled = enabled
            self.miniGlass.isHidden = !enabled
            self.tabBar.isHidden = !enabled
            // Re-derive title/bar state from the live web offset, so disabling
            // chrome cannot leave a stale compact title behind.
            self.applyScrollMaster(offsetY: self.webView?.scrollView.contentOffset.y ?? 0)
            if !enabled {
                self.miniTitle.text = "Not Playing"
                self.miniArtist.text = ""
                self.artworkURL = ""
                self.setIdleArtwork(true)
                self.setProgress(0)
            }
        }
    }

    func setTrack(title: String?, artist: String?, artwork link: String?, duration: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let name = (title?.isEmpty == false ? title : "Not Playing") ?? "Not Playing"
            self.miniTitle.text = name
            self.miniArtist.text = (artist?.isEmpty == false ? artist : nil)
            self.setProgress(0)
            self.setIdleArtwork(true)
            self.loadArtwork(link)
        }
    }

    func setPlaying(playing: Bool, progress: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlaying = playing
            self.playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
            self.playButton.accessibilityLabel = playing ? "Pause" : "Play"
            self.setProgress(progress)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if let view = touch.view, view is UIButton { return false }
        return true
    }

    private func setProgress(_ value: Double) {
        let clamped = max(0, min(1, value))
        let width = miniGlass.contentView.bounds.width * CGFloat(clamped)
        progressWidthConstraint?.constant = width
        progressBar.superview?.layoutIfNeeded()
    }

    private func loadArtwork(_ link: String?) {
        guard let link, !link.isEmpty, link != artworkURL, let url = URL(string: link), url.scheme == "https" else { return }
        artworkURL = link
        artworkTask?.cancel()
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data), link == self.artworkURL else { return }
            DispatchQueue.main.async {
                self.miniArtwork.image = image
                self.setIdleArtwork(false)
            }
        }
        artworkTask?.resume()
    }

    @objc private func miniPanned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended || gesture.state == .cancelled else { return }
        let translation = gesture.translation(in: miniGlass)
        let velocity = gesture.velocity(in: miniGlass)
        if translation.y < -36 || velocity.y < -420 { openNowPlaying() }
        gesture.setTranslation(.zero, in: miniGlass)
    }

    // MARK: - Native scroll master (single source of truth)

    /// KVO reports which scroll moved; it never decides chrome state itself.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "contentOffset", let scroll = object as? UIScrollView else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        // WK-level scrolls (rubber band, programmatic) feed the same master as
        // the page's internal scroller does through the "scroll:" bridge
        // message; neither writes chrome state directly.
        guard scroll === webView?.scrollView else { return }
        applyScrollMaster(offsetY: scroll.contentOffset.y)
    }

    /// The one scroll master: a pure, continuous mapping from contentOffset to
    /// every title/bar value. No accumulation, no thresholds, no boolean cliff
    /// and no animation that could fight successive KVO callbacks.
    /// SOLE writer of compactTitleLabel/compactTitleBackground alpha. progress
    /// is clamped to 0 at scroll-top, so progress == 0 always means alpha == 0
    /// (no faint "Home" behind the status bar).
    /// fileprivate: the RouteHandler feeds the "scroll:" bridge messages into
    /// this same master (one writer of all chrome state).
    fileprivate func applyScrollMaster(offsetY: CGFloat) {
        let progress = max(0, min(1, (offsetY - 40) / 120))
        scrollProgress = progress
        // Web content is the real Home. The compact "Home" strip belongs only
        // to the web Home route while native glass chrome is enabled.
        let showsTitle = glassEnabled && currentPath == "/"
        // progress == 0 => 0; hidden routes/overlays are also 0.
        let titleAlpha = showsTitle ? progress : 0
        compactTitleTopConstraint?.constant = 8 * titleAlpha
        compactTitleLabel.alpha = titleAlpha
        compactTitleBackground.alpha = titleAlpha
        // Apple minimizes the whole bar/accessory as ONE unit. Translate and
        // fade the stored chrome container together; the tab bar, active pill,
        // buttons and mini-player all move as one. Tab height, glyphs and
        // labels keep fixed metrics at every scroll position.
        // With the bar now 10pt above the physical bottom, a 10pt translate
        // brings it flush with the edge at full collapse instead of clipping it.
        chromeContainer.transform = CGAffineTransform(translationX: 0, y: 10 * scrollProgress)
        chromeContainer.alpha = 1 - 0.25 * scrollProgress
        view.layoutIfNeeded()
        layoutActivePill()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutActivePill()
    }

    deinit {
        guard isObservingScroll else { return }
        webView?.scrollView.removeObserver(self, forKeyPath: "contentOffset")
    }

    // MARK: - Preview-only launch arguments (inert in normal launches)
    private func readPreviewArguments() {
        for argument in CommandLine.arguments {
            if argument.hasPrefix("-previewScroll=") {
                let value = String(argument.dropFirst("-previewScroll=".count))
                previewScrollOffset = CGFloat(Double(value) ?? 0)
            } else if argument == "-previewTab=new" {
                previewNewTab = true
            } else if argument.hasPrefix("-previewRoute=") {
                let route = String(argument.dropFirst("-previewRoute=".count))
                previewRoute = route
                // Artist previews land on a real search-results page and then
                // follow a live artist link. A bare "/search/artist/<id>" can
                // point at an id the bundled catalog does not have, which
                // renders the "Invalid artist" empty state.
                if route.contains("type=artist") { previewArtistTap = true }
            } else if argument == "-previewAppearance=light" {
                previewLight = true
            } else if argument == "-previewSeedHistory" {
                previewSeedHistory = true
            }
        }
    }

    private func applyPreviewState() {
        if previewLight {
            overrideUserInterfaceStyle = .light
            setAppearance("light")
        }
        if previewNewTab || previewRoute != nil {
            let route = previewRoute ?? "/new"
            if route.hasPrefix("/search") { setActiveTab(3) }
            else if route.hasPrefix("/library") || route.hasPrefix("/favorites") ||
                    route.hasPrefix("/history") || route.hasPrefix("/playlist") { setActiveTab(2) }
            else { setActiveTab(1) }
            // The web app owns the destination. No native placeholder: just
            // navigate once its initial route post has settled — with a
            // verified retry, since the fixed-timer one-shot is racy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.navigateVerified(to: route)
            }
            if previewArtistTap {
                // Results render after the route change, and the album/genre
                // page they lead to needs another beat. The JS retries itself
                // until a real artist link exists; this delay only makes sure
                // the page has had time to render before it starts looking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.tapFirstArtistResult()
                }
            }
        }
        applyPreviewScroll()
        if previewSeedHistory {
            seedListeningHistory()
        } else if previewScrollOffset > 0, previewRoute == nil {
            // Web content is still loading when capacitorDidLoad runs. The page
            // script re-applies the scroll on load and short timers, and these
            // native retries cover a slow first paint for both scroll targets
            // (Home plain, New via -previewTab=new). Only the scroll position
            // is set here — the contentOffset KVO still drives every title/bar
            // value; nothing is pinned directly.
            for delay in [3.0, 6.0, 9.0, 13.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.applyPreviewScroll()
                }
            }
        }
    }

    /// Preview-only: seed REAL listening history so the Home capture has enough
    /// content to scroll. One injected script does the whole sequence with
    /// in-page retries (same pattern as tapFirstArtistResult): wait for search
    /// results, click the first "Play <song>" overlay, give playback a beat to
    /// record history, then return Home. Everything afterwards is real data.
    private func seedListeningHistory() {
        // Land on a live search first; the injected tick loop below keeps
        // running across SPA route changes until results render. The loop is
        // injected at +5s — evaluateJavaScript called before the first page
        // commits runs in the provisional document whose timers die on load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.navigateVerified(to: "/search?q=Kweku%20Smoke")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let js = """
            (function(){
              var tries = 0, max = 120, clicked = false;
              function tick(){
                if (!clicked) {
                  var b = document.querySelector('button[aria-label^="Play "]') ||
                          document.querySelector('button[aria-label="Play"]');
                  if (b) {
                    b.click();
                    clicked = true;
                    setTimeout(function(){
                      history.pushState({}, '', '/');
                      window.dispatchEvent(new PopStateEvent('popstate'));
                    }, 6000);
                    return;
                  }
                }
                if (++tries < max) setTimeout(tick, 250);
              }
              tick();
            })();
            """
            self.webView?.evaluateJavaScript(js) { _, _ in }
        }
        // Scroll retries AFTER the seed window: results click typically lands
        // by ~20s (loop starts at +5s), +6s playback, then Home re-renders.
        for delay in [30.0, 34.0, 38.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyPreviewScroll()
            }
        }
    }

    /// Preview-only: scroll the rendered web page itself. The app scrolls its
    /// own <main> scroller (html/body are height:100%), so setting the
    /// WKWebView scroll view's contentOffset never moves the content. Ask the
    /// page to scroll with window.scrollTo plus the real scroller; WebKit then
    /// reports any resulting offset through the contentOffset KVO, which stays
    /// the single source of truth for native title/chrome state.
    private func applyPreviewScroll() {
        // The scroll applies to the page the preview landed on: Home for a
        // plain scroll, the New page for -previewTab=new. currentPath must
        // match the destination so the preview's own navigation is not fought.
        guard previewScrollOffset > 0, previewRoute == nil else { return }
        guard currentPath == (previewNewTab ? "/new" : "/") else { return }
        let y = Int(previewScrollOffset.rounded())
        let js = """
        (function(){
          var y = \(y);
          function scrollPage(){
            window.scrollTo(0, y);
            var scroller = document.querySelector('main.scroll-area') || document.querySelector('main');
            if (scroller && scroller.scrollHeight > scroller.clientHeight) {
              scroller.scrollTop = y;
            }
          }
          scrollPage();
          window.addEventListener('load', scrollPage, {once:true});
          setTimeout(scrollPage, 100);
          setTimeout(scrollPage, 500);
        })();
        """
        webView?.evaluateJavaScript(js) { _, _ in }
    }

    /// Preview-only: follow a real artist link so the Artist capture shows a
    /// catalog artist instead of the "Invalid artist" empty state. Song search
    /// results have no artist links, so switch to the Albums tab (if needed),
    /// open an album, then click its real artist link.
    private func tapFirstArtistResult() {
        let js = """
        (function(){
          var tries = 0, max = 100, switched = false;
          function tick(){
            var artist = document.querySelector('a[href^="/search/artist/"]');
            if (artist) { artist.click(); return; }
            var album = document.querySelector('a[href^="/search/album/"]') ||
                        document.querySelector('a[href^="/search/genre/"]');
            if (album) { album.click(); return; }
            // Default results are songs (plain text artists). The third result
            // tab is Albums; its grid links to albums that link to artists.
            if (!switched) {
              var tabs = document.querySelectorAll('[role="tab"]');
              if (tabs.length >= 3) { switched = true; tabs[2].click(); }
            }
            if (++tries < max) setTimeout(tick, 250);
          }
          tick();
        })();
        """
        webView?.evaluateJavaScript(js) { _, _ in }
    }

    // MARK: - Appearance

    func setAppearance(_ mode: String) {
        appearanceMode = mode
        applyAppearance()
    }

    private func applyAppearance() {
        let dark: Bool
        switch appearanceMode {
        case "dark": dark = true
        case "light": dark = false
        default: dark = traitCollection.userInterfaceStyle == .dark
        }
        webView?.evaluateJavaScript("window.__musikeAppearanceChange && window.__musikeAppearanceChange(\(dark ? "true" : "false"));")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }
}
