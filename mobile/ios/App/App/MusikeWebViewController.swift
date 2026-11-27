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
        ("dot.radiowaves.left.and.right", "dot.radiowaves.left.and.right", "Radio", "radio"),
        ("music.quarternote.3", "music.quarternote.3", "Library", "library"),
        ("magnifyingglass", "magnifyingglass", "Search", "search")
    ]
    /// ONE fixed glyph configuration and ONE fixed label font for every scroll
    /// state. Apple does not rescale tab glyphs/labels as the bar collapses.
    private static let tabSymbolConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
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
    private var previewLight = false
    private var isObservingScroll = false

    private var appearanceMode = "system"
    private var isPlaying = false
    private var radioSelected = false
    /// Native glass chrome is shown only while the web app has it enabled.
    private var glassEnabled = true

    private let activeColor = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
    private var currentPath = "/"
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?

    private let routes = ["/", "/new", "__radio__", "/library", "/search"]

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
        let bottom = tabBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8)
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
        // Home 0, New 1, Radio 2, Library 3, Search 4.
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
        // its size and simply tracks the selected button frame.
        let height = max(28, min(slot.height - 14, bounds.height - 8))
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
        if routes[index] == "__radio__" {
            startRadio()
        } else {
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
        // Web Home is the only Home: the WKWebView scroll view is the sole
        // scroll master. KVO reports the offset; it never decides chrome state.
        guard scroll === webView?.scrollView else { return }
        applyScrollMaster(offsetY: scroll.contentOffset.y)
    }

    /// The one scroll master: a pure, continuous mapping from contentOffset to
    /// every title/bar value. No accumulation, no thresholds, no boolean cliff
    /// and no animation that could fight successive KVO callbacks.
    /// SOLE writer of compactTitleLabel/compactTitleBackground alpha. progress
    /// is clamped to 0 at scroll-top, so progress == 0 always means alpha == 0
    /// (no faint "Home" behind the status bar).
    private func applyScrollMaster(offsetY: CGFloat) {
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
        chromeContainer.transform = CGAffineTransform(translationX: 0, y: 18 * scrollProgress)
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
                previewRoute = String(argument.dropFirst("-previewRoute=".count))
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
        if previewNewTab || previewRoute != nil {
            let route = previewRoute ?? "/new"
            if route.hasPrefix("/search") { setActiveTab(4) }
            else if route.hasPrefix("/library") || route.hasPrefix("/favorites") ||
                    route.hasPrefix("/history") || route.hasPrefix("/playlist") { setActiveTab(3) }
            else { setActiveTab(1) }
            // The web app owns the destination. No native placeholder: just
            // navigate once its initial route post has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.navigate(to: route)
            }
        }
        applyPreviewScroll()
        if previewScrollOffset > 0, !previewNewTab, previewRoute == nil {
            // Web content is still loading when capacitorDidLoad runs; retry
            // until the web Home has enough height to scroll. Only the scroll
            // position is set here — KVO still drives every title/bar value.
            for delay in [3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.applyPreviewScroll()
                }
            }
        }
    }

    private func applyPreviewScroll() {
        guard previewScrollOffset > 0, !previewNewTab, previewRoute == nil,
              currentPath == "/" else { return }
        // The harness only moves the web view's scroll view. KVO routes that
        // offset through applyScrollMaster, the sole writer of title/bar state.
        webView?.scrollView.setContentOffset(CGPoint(x: 0, y: previewScrollOffset), animated: false)
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
