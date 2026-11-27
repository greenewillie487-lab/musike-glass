import Capacitor
import UIKit
import WebKit

/// Small singleton so the Capacitor plugin can reach the glass views owned by the web view controller.
private final class NativeGlass {
    static let shared = NativeGlass()
    weak var host: MusikeWebViewController?
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
    private let miniTitle = UILabel()
    private let miniArtist = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progressBar = UIView()
    private var progressWidthConstraint: NSLayoutConstraint?
    private let activePill = UIVisualEffectView(frame: .zero)
    private let activePillTint = UIView()
    private let newPlaceholder = UIView()
    private var tabBarBottomConstraint: NSLayoutConstraint?
    private var chromeCollapsed = false
    private var scrollAccumulation: CGFloat = 0
    private var lastScrollOffset: CGFloat = 0
    private var previewScrollOffset: CGFloat = 0
    private var previewNewTab = false
    private var previewLight = false
    private var isObservingScroll = false

    private var appearanceMode = "system"
    private var isPlaying = false
    private var radioSelected = false
    private static let fallbackChartJSON = #"""
{"feed":{"results":[{"name":"Faith","artistName":"Kweku Smoke & Lasmid","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/5b/ca/ac/5bcaac2e-2329-567b-0445-29efd7e03bee/766214704508.jpg/100x100bb.jpg","releaseDate":"2026-08-28"},{"name":"Bra","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"BALOTELLI (SUPA)","artistName":"Kofi Mole","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/4f/e9/71/4fe971a6-1d64-0669-30a1-378a97ea0ded/artwork.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Bombele","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Survivor","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"IKEBE 3000","artistName":"Blaqbonez & Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/08/0e/f2/080ef21a-3bad-70b4-ccd8-3221a87a09f3/1200220133765.jpg/100x100bb.jpg","releaseDate":"2026-09-23"},{"name":"Forgiveness","artistName":"Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/31/e4/eb/31e4ebf4-97bd-c193-59c7-1b72ed7ab53a/ticket.wlorjbae.jpg/100x100bb.jpg","releaseDate":"2026-04-30"},{"name":"B4 B4","artistName":"Davido, FOLA & Mayorkun","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a8/fb/21/a8fb21ed-2106-199e-75dc-f01099c29394/196874507544.jpg/100x100bb.jpg","releaseDate":"2026-07-31"},{"name":"Soul Healer","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Home","artistName":"Kwesi Arthur","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/7c/0a/a9/7c0aa928-9ace-a09f-d173-5c3776593926/711641194057.jpg/100x100bb.jpg","releaseDate":"2026-11-19"},{"name":"Halleluyah","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Gratitude","artistName":"Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/31/e4/eb/31e4ebf4-97bd-c193-59c7-1b72ed7ab53a/ticket.wlorjbae.jpg/100x100bb.jpg","releaseDate":"2026-04-30"},{"name":"GEN Z II (feat. AratheJay)","artistName":"Fameye, Joey B & Sarkodie","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/3e/cb/04/3ecb04a9-3f9c-54ed-b819-57e2d4b953d5/0.jpg/100x100bb.jpg","releaseDate":"2026-11-12"},{"name":"REPAIR","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Okwantunii","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"WHY LOVE","artistName":"Asake","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/18/65/07/186507c9-146c-473c-6eae-e4cf689c7357/197342969963_cover.jpg/100x100bb.jpg","releaseDate":"2025-02-12"},{"name":"SAVE ME","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Power House","artistName":"Kweku Smoke & Kwesi Arthur","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Mmereniho","artistName":"Kweku Smoke & Dikoo","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"FAMAME","artistName":"AratheJay","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/1f/95/9c/1f959cdd-8435-49a4-7b30-3d0908ce9fd1/823375337447_cover.jpg/100x100bb.jpg","releaseDate":"2026-07-31"},{"name":"Life Of A Hustler","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"ME NSAN","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"K\u0186K\u0186SAKYI","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Gen Z","artistName":"Fameye","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/af/9c/c1/af9cc14f-0da1-509b-0878-396cc78c9162/0.jpg/100x100bb.jpg","releaseDate":"2026-07-24"},{"name":"Yawa (Hosanna)","artistName":"Kwesi Arthur","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/36/83/04/36830411-d153-4138-217a-8ccd67c44598/199976556083.jpg/100x100bb.jpg","releaseDate":"2026-02-06"},{"name":"Hold Tight","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/a4/1e/c5/a41ec5ec-cc25-b1a6-b2c8-43f9a68a1905/757572950423.jpg/100x100bb.jpg","releaseDate":"2023-09-01"},{"name":"Young Boy","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/16/17/72/16177275-88ac-f797-48a6-b57c8801a9ba/766214662181.jpg/100x100bb.jpg","releaseDate":"2024-03-08"},{"name":"Signature","artistName":"KiDi & Lasmid","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/ab/82/c4/ab82c4fa-424b-67a2-2547-adb87fd7bd33/820233047104.jpg/100x100bb.jpg","releaseDate":"2026-04-30"},{"name":"Chanel (feat. Asake)","artistName":"Blaqbonez","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/0c/19/fc/0c19fcea-bd03-8ad3-6245-03a58ec40a00/8718521271213.jpg/100x100bb.jpg","releaseDate":"2026-05-21"},{"name":"No Days Off","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"SWAGGA","artistName":"Black Sherif","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/c6/d3/84/c6d384e6-ef16-fd9c-57de-58332def802b/199316628746_cover.jpg/100x100bb.jpg","releaseDate":"2026-05-28"},{"name":"WOUNDED LION (WASN'T GIFTED)","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Liquor Store","artistName":"Lasmid","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/42/aa/b0/42aab058-b8a7-d163-6cba-c67803ad74dd/0.jpg/100x100bb.jpg","releaseDate":"2026-08-21"},{"name":"Forever (feat. AratheJay)","artistName":"Black Sherif","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4b/dc/7c/4bdc7c0a-1905-baf7-5efb-cae0b544f6a8/199316713701_cover.jpg/100x100bb.jpg","releaseDate":"2026-09-03"},{"name":"Jolie","artistName":"Black Sherif","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4b/dc/7c/4bdc7c0a-1905-baf7-5efb-cae0b544f6a8/199316713701_cover.jpg/100x100bb.jpg","releaseDate":"2026-09-03"},{"name":"Through The Pain","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"Set it Straight","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/59/52/64/59526449-8af9-b556-e248-927a964c72d5/766214704355.jpg/100x100bb.jpg","releaseDate":"2026-09-04"},{"name":"CLARITY STONES","artistName":"O'Kenneth, JT700 & SRT Gwalla","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"TIMES LIKE THIS","artistName":"O'Kenneth","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/69/a8/0b/69a80bb3-3e23-9524-7b27-c9adce369c76/711209229979-copy-674ae09c.png/100x100bb.jpg","releaseDate":"2026-11-13"},{"name":"Jah Guide","artistName":"Kweku Smoke","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/16/17/72/16177275-88ac-f797-48a6-b57c8801a9ba/766214662181.jpg/100x100bb.jpg","releaseDate":"2024-03-08"}]}}
"""#

    private let activeColor = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
    private let homeScrollView = UIScrollView()
    private let homeStack = UIStackView()
    private var chartItems: [[String: Any]] = []
    private var displayItems: [[String: Any]] = []
    private var homeVisible = false
    private var currentPath = "/"
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?

    private let routes = ["/", "__new__", "__radio__", "/library", "/search"]

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
        buildHomeView()
        fetchCharts()
        applyAppearance()
        postRoute()
        setRoute("/")
        readPreviewArguments()
        webView?.scrollView.addObserver(self, forKeyPath: "contentOffset", options: [.initial, .new], context: nil)
        homeScrollView.addObserver(self, forKeyPath: "contentOffset", options: [.initial, .new], context: nil)
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
        tabBar.standardAppearance = tabAppearance
        tabBar.scrollEdgeAppearance = tabAppearance
        tabBar.unselectedItemTintColor = .secondaryLabel

        installActivePill()
        buildTabBar()
        buildNewPlaceholder()
        buildMiniPlayer()

        view.addSubview(homeScrollView)
        view.addSubview(tabBar)
        view.addSubview(miniGlass)
        view.insertSubview(newPlaceholder, belowSubview: tabBar)

        let guide = view.safeAreaLayoutGuide
        let bottom = tabBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8)
        tabBarBottomConstraint = bottom
        NSLayoutConstraint.activate([
            homeScrollView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            homeScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            homeScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            homeScrollView.bottomAnchor.constraint(equalTo: miniGlass.topAnchor, constant: -8),

            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bottom,
            tabBar.heightAnchor.constraint(equalToConstant: 64),

            miniGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            miniGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            miniGlass.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -8),
            miniGlass.heightAnchor.constraint(equalToConstant: 56),

            newPlaceholder.topAnchor.constraint(equalTo: view.topAnchor),
            newPlaceholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newPlaceholder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newPlaceholder.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func buildTabBar() {
        // Home 0, New 1, Radio 2, Library 3, Search 4.
        let items: [(String, String, String, String)] = [
            ("house", "house.fill", "Home", "home"),
            ("square.grid.2x2", "square.grid.2x2.fill", "New", "new"),
            ("dot.radiowaves.left.and.right", "dot.radiowaves.left.and.right", "Radio", "radio"),
            ("music.note.tv", "music.note.tv", "Library", "library"),
            ("magnifyingglass", "magnifyingglass", "Search", "search")
        ]
        var tabItems: [UITabBarItem] = []
        for item in items {
            let tabItem = UITabBarItem(
                title: item.2,
                image: UIImage(systemName: item.0),
                selectedImage: UIImage(systemName: item.1)
            )
            tabItem.tag = tabItems.count
            tabItem.accessibilityIdentifier = "glass-tab-\(item.3)"
            tabItems.append(tabItem)
        }
        tabBar.items = tabItems
        setActiveTab(0)
    }

    /// The selected tab is a translucent red glass pill behind the real tab
    /// button (never a flat rect and never a replacement for UITabBar).
    private func installActivePill() {
        activePill.translatesAutoresizingMaskIntoConstraints = false
        activePill.isUserInteractionEnabled = false
        activePill.effect = liquidGlassEffect()
        activePill.layer.masksToBounds = true
        activePill.layer.borderWidth = 0.5
        activePill.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        activePillTint.backgroundColor = activeColor.withAlphaComponent(0.26)
        activePillTint.translatesAutoresizingMaskIntoConstraints = false
        activePill.contentView.addSubview(activePillTint)
        NSLayoutConstraint.activate([
            activePillTint.topAnchor.constraint(equalTo: activePill.contentView.topAnchor),
            activePillTint.leadingAnchor.constraint(equalTo: activePill.contentView.leadingAnchor),
            activePillTint.trailingAnchor.constraint(equalTo: activePill.contentView.trailingAnchor),
            activePillTint.bottomAnchor.constraint(equalTo: activePill.contentView.bottomAnchor)
        ])
        tabBar.addSubview(activePill)
        if let background = tabBar.subviews.first(where: {
            NSStringFromClass($0.classForCoder).contains("Background")
        }), let index = tabBar.subviews.firstIndex(of: background) {
            tabBar.insertSubview(activePill, at: index + 1)
        } else {
            tabBar.insertSubview(activePill, at: 0)
        }
    }

    private func buildNewPlaceholder() {
        let title = UILabel()
        title.text = "New"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = .label
        title.textAlignment = .center
        let subtitle = UILabel()
        subtitle.text = "Built in Phase 3"
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        newPlaceholder.addSubview(stack)
        newPlaceholder.accessibilityIdentifier = "native-new-placeholder"
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: newPlaceholder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: newPlaceholder.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: newPlaceholder.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: newPlaceholder.trailingAnchor, constant: -24)
        ])
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
        let height = bounds.height - 14
        activePill.frame = CGRect(x: slot.midX - width / 2, y: (bounds.height - height) / 2,
                                  width: width, height: height)
        activePill.layer.cornerRadius = height / 2
        activePillTint.layer.cornerRadius = height / 2
    }

    private func showNewPlaceholder() {
        homeVisible = false
        homeScrollView.isHidden = true
        newPlaceholder.isHidden = false
        tabBar.isHidden = false
        miniGlass.isHidden = false
    }

    private func hideNewPlaceholder() {
        newPlaceholder.isHidden = true
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
            let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            miniArtwork.image = UIImage(systemName: "music.note", withConfiguration: config)
            miniArtwork.tintColor = .secondaryLabel
            miniArtwork.backgroundColor = UIColor.secondarySystemFill
            miniArtwork.contentMode = .center
        } else {
            miniArtwork.tintColor = nil
            miniArtwork.backgroundColor = .clear
            miniArtwork.contentMode = .scaleAspectFill
        }
    }

    // MARK: - Native Home shelves (Apple public RSS feed)

    private func buildHomeView() {
        homeScrollView.translatesAutoresizingMaskIntoConstraints = false
        homeScrollView.backgroundColor = .systemBackground
        homeScrollView.alwaysBounceVertical = true
        homeScrollView.showsVerticalScrollIndicator = false

        homeStack.axis = .vertical
        homeStack.spacing = 24
        homeStack.translatesAutoresizingMaskIntoConstraints = false
        homeScrollView.addSubview(homeStack)
        NSLayoutConstraint.activate([
            homeStack.topAnchor.constraint(equalTo: homeScrollView.topAnchor),
            homeStack.leadingAnchor.constraint(equalTo: homeScrollView.leadingAnchor),
            homeStack.trailingAnchor.constraint(equalTo: homeScrollView.trailingAnchor),
            homeStack.bottomAnchor.constraint(equalTo: homeScrollView.bottomAnchor),
            homeStack.widthAnchor.constraint(equalTo: homeScrollView.widthAnchor)
        ])

        let title = UILabel()
        title.text = "Home"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        homeStack.addArrangedSubview(title)
        homeScrollView.isHidden = true
    }

    private func fetchCharts() {
        let urlString = "https://rss.marketingtools.apple.com/api/v2/gh/music/most-played/100/songs.json"
        func use(_ data: Data) {
            guard let items = Self.parseChartData(data) else { return }
            chartItems = items
            renderHome()
        }
        if let cached = UserDefaults.standard.data(forKey: "musike:charts-cache") {
            use(cached)
        } else {
            use(Data(Self.fallbackChartJSON.utf8))
        }
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let items = Self.parseChartData(data) else { return }
            UserDefaults.standard.set(data, forKey: "musike:charts-cache")
            DispatchQueue.main.async {
                self.chartItems = items
                self.renderHome()
            }
        }.resume()
    }

    private static func parseChartData(_ data: Data) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = json["feed"] as? [String: Any],
              let results = feed["results"] as? [[String: Any]] else { return nil }
        return results
    }

    private func renderHome() {
        for view in homeStack.arrangedSubviews {
            homeStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        displayItems = []
        let title = UILabel()
        title.text = "Home"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        homeStack.addArrangedSubview(title)
        guard !chartItems.isEmpty else { applyPreviewScroll(); return }
        let newer = chartItems.sorted {
            String($0["releaseDate"] as? String ?? "") > String($1["releaseDate"] as? String ?? "")
        }
        addHomeSection("Made for You", items: Array(chartItems.prefix(20)))
        addHomeSection("New Releases", items: Array(newer.prefix(20)))
        addHomeSection("Top Charts", items: Array(chartItems.prefix(30)))
        applyPreviewScroll()
    }

    private func addHomeSection(_ title: String, items: [[String: Any]]) {
        let heading = UILabel()
        heading.text = title
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        homeStack.addArrangedSubview(heading)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .top
        for item in items {
            let card = makeChartCard(item)
            displayItems.append(item)
            card.tag = displayItems.count - 1
            card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(chartTapped(_:))))
            row.addArrangedSubview(card)
        }
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 190),
            scroller.heightAnchor.constraint(equalToConstant: 200)
        ])
        homeStack.addArrangedSubview(scroller)
    }

    private func makeChartCard(_ item: [String: Any]) -> UIView {
        let card = UIView()
        card.backgroundColor = .systemGray5
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 144).isActive = true
        card.heightAnchor.constraint(equalToConstant: 190).isActive = true

        let art = UIImageView()
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.backgroundColor = .tertiarySystemFill
        art.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(art)
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: card.topAnchor),
            art.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            art.heightAnchor.constraint(equalToConstant: 144)
        ])
        if let link = item["artworkUrl100"] as? String, let url = URL(string: link) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { art.image = image }
            }.resume()
        }

        let name = UILabel()
        name.text = item["name"] as? String
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.numberOfLines = 1
        let artist = UILabel()
        artist.text = item["artistName"] as? String
        artist.font = .systemFont(ofSize: 12)
        artist.textColor = .secondaryLabel
        artist.numberOfLines = 1
        let labels = UIStackView(arrangedSubviews: [name, artist])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            labels.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4)
        ])
        return card
    }

    @objc private func chartTapped(_ recognizer: UITapGestureRecognizer) {
        guard let index = recognizer.view?.tag, displayItems.indices.contains(index) else { return }
        let item = displayItems[index]
        let query = "\(item["name"] as? String ?? "") \(item["artistName"] as? String ?? "")"
            .trimmingCharacters(in: .whitespaces)
        homeVisible = false
        homeScrollView.isHidden = true
        navigate(to: "/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&type=song")
    }

    // MARK: - Web bridge

    private func installBridgeScript() {
        let css = """
        nav.fixed.inset-x-3[class*="bottom-[calc(10px"] { display: none !important; }
        div.fixed.inset-x-3[class*="bottom-[calc(84px"] { display: none !important; }
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
            if(h) h.postMessage(location.pathname || '/');
          }
          var push = history.pushState, replace = history.replaceState;
          history.pushState = function(){ var r = push.apply(this, arguments); postRoute(); return r; };
          history.replaceState = function(){ var r = replace.apply(this, arguments); postRoute(); return r; };
          window.addEventListener('popstate', postRoute);
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
        radioSelected = (index == 2)
        if index == 1 {
            showNewPlaceholder()
        } else if routes[index] == "__radio__" {
            hideNewPlaceholder()
            startRadio()
        } else {
            hideNewPlaceholder()
            navigate(to: routes[index])
        }
    }

    /// Radio is a real app action: open the current track's Now Playing sheet
    /// and press its existing "Start radio" control. No fake page or state flag.
    private func startRadio() {
        let js = #"""
        (function(){
          var m = document.querySelector('div.fixed.z-20 > div.glass');
          if (!m) return;
          var b = m.querySelector('button');
          if (b) b.click();
          setTimeout(function(){
            var d = document.querySelector('[role=dialog][aria-modal=true]');
            if (!d) return;
            var r = d.querySelector('button.glass-thin');
            if (r) r.click();
          }, 200);
        })();
        """#
        webView?.evaluateJavaScript(js)
    }

    private func navigate(to route: String) {
        let js = "history.pushState({}, '', \(jsString(route))); window.dispatchEvent(new PopStateEvent('popstate'));"
        webView?.evaluateJavaScript(js)
    }

    func setRoute(_ url: String) {
        if radioSelected && (url == "/" || url.isEmpty) { return }
        if !newPlaceholder.isHidden { return }
        let clean = url.components(separatedBy: "#").first ?? "/"
        let path = clean.components(separatedBy: "?").first ?? "/"
        currentPath = path
        let sheetOpen = url.contains("#now-playing")
        homeVisible = path == "/" && !sheetOpen
        homeScrollView.isHidden = !homeVisible
        if homeVisible { hideNewPlaceholder() }
        tabBar.isHidden = sheetOpen
        miniGlass.isHidden = sheetOpen
        if sheetOpen { return }
        if path.hasPrefix("/search") { setActiveTab(4) }
        else if path.hasPrefix("/library") || path.hasPrefix("/favorites") ||
                path.hasPrefix("/history") || path.hasPrefix("/playlist") { setActiveTab(3) }
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
            self.miniGlass.isHidden = !enabled
            self.tabBar.isHidden = !enabled
            self.homeVisible = enabled ? false : (self.currentPath == "/")
            self.homeScrollView.isHidden = !self.homeVisible
            if enabled { self.hideNewPlaceholder() }
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

    // MARK: - Native scroll collapse (KVO on WKWebView.scrollView, no JS)
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "contentOffset", let scroll = object as? UIScrollView else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let activeScroll = homeVisible ? homeScrollView : webView?.scrollView
        guard scroll === activeScroll else { return }
        let offset = scroll.contentOffset.y
        let delta = offset - lastScrollOffset
        lastScrollOffset = offset
        if offset <= 8 {
            scrollAccumulation = 0
            setChromeCollapsed(false)
            return
        }
        scrollAccumulation = max(0, min(scrollAccumulation + delta, 160))
        if !chromeCollapsed && scrollAccumulation >= 60 {
            setChromeCollapsed(true)
        } else if chromeCollapsed && scrollAccumulation <= 12 {
            setChromeCollapsed(false)
        }
    }

    private func setChromeCollapsed(_ collapsed: Bool) {
        guard collapsed != chromeCollapsed else { return }
        chromeCollapsed = collapsed
        // One stored constraint owns the whole chrome offset; mini follows the tab bar.
        tabBarBottomConstraint?.constant = collapsed ? 72 : -8
        miniGlass.alpha = collapsed ? 0 : 1
        miniGlass.isUserInteractionEnabled = !collapsed
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState], animations: {
            self.view.layoutIfNeeded()
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutActivePill()
    }

    deinit {
        guard isObservingScroll else { return }
        webView?.scrollView.removeObserver(self, forKeyPath: "contentOffset")
        homeScrollView.removeObserver(self, forKeyPath: "contentOffset")
    }

    // MARK: - Preview-only launch arguments (inert in normal launches)
    private func readPreviewArguments() {
        for argument in CommandLine.arguments {
            if argument.hasPrefix("-previewScroll=") {
                let value = String(argument.dropFirst("-previewScroll=".count))
                previewScrollOffset = CGFloat(Double(value) ?? 0)
            } else if argument == "-previewTab=new" {
                previewNewTab = true
            } else if argument == "-previewAppearance=light" {
                previewLight = true
            }
        }
    }

    private func applyPreviewState() {
        if previewLight {
            overrideUserInterfaceStyle = .light
            setAppearance("light")
        }
        if previewNewTab {
            setActiveTab(1)
            showNewPlaceholder()
        }
        applyPreviewScroll()
    }

    private func applyPreviewScroll() {
        guard previewScrollOffset > 0, homeVisible, !previewNewTab else { return }
        // Seed the hysteresis baseline so the preview jump alone cannot collapse chrome.
        lastScrollOffset = previewScrollOffset
        homeScrollView.setContentOffset(CGPoint(x: 0, y: previewScrollOffset), animated: false)
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
