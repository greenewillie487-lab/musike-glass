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
final class MusikeWebViewController: CAPBridgeViewController, UITabBarDelegate {
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

    private var appearanceMode = "system"
    private var isPlaying = false
    private var radioSelected = false
    private let activeColor = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?

    private let routes = ["/", "__radio__", "/library", "/search"]

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
        miniGlass.layer.cornerRadius = 18
        miniGlass.layer.masksToBounds = true
        miniGlass.translatesAutoresizingMaskIntoConstraints = false

        // A real UITabBar linked with the Xcode 27 SDK gets Apple's automatic
        // Liquid Glass material. Do not override it with a custom effect.
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        tabBar.isTranslucent = true
        tabBar.backgroundColor = .clear
        tabBar.layer.cornerRadius = 26
        tabBar.layer.masksToBounds = true
        tabBar.tintColor = activeColor
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        tabBar.standardAppearance = tabAppearance
        tabBar.scrollEdgeAppearance = tabAppearance

        buildTabBar()
        buildMiniPlayer()

        view.addSubview(tabBar)
        view.addSubview(miniGlass)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            tabBar.heightAnchor.constraint(equalToConstant: 72),

            miniGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            miniGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            miniGlass.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -10),
            miniGlass.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func buildTabBar() {
        let items: [(String, String, String, String)] = [
            ("house", "house.fill", "Home", "home"),
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

    private func setActiveTab(_ index: Int) {
        guard let items = tabBar.items, items.indices.contains(index) else { return }
        tabBar.selectedItem = items[index]
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

        miniArtwork.image = UIImage(systemName: "music.note")
        miniArtwork.tintColor = .secondaryLabel
        miniArtwork.backgroundColor = UIColor.secondarySystemFill
        miniArtwork.contentMode = .scaleAspectFill
        miniArtwork.clipsToBounds = true
        miniArtwork.layer.cornerRadius = 6
        miniArtwork.translatesAutoresizingMaskIntoConstraints = false

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
        nextButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)
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
        radioSelected = (index == 1)
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

    func setRoute(_ path: String) {
        if radioSelected && (path == "/" || path.isEmpty) { return }
        if path.hasPrefix("/search") { setActiveTab(3) }
        else if path.hasPrefix("/library") { setActiveTab(2) }
        else { setActiveTab(0) }
    }

    private func postRoute() {
        webView?.evaluateJavaScript("(function(){var h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.musikeRoute;if(h)h.postMessage(location.pathname||'/');})();")
    }

    @objc private func playTapped() {
        let action = isPlaying ? "pause" : "play"
        webView?.evaluateJavaScript("window.__musikeMediaAction && window.__musikeMediaAction('\(action)');")
    }

    @objc private func nextTapped() {
        webView?.evaluateJavaScript("window.__musikeMediaAction && window.__musikeMediaAction('next');")
    }

    // MARK: - GlassPlayer plugin calls

    func setGlassEnabled(_ enabled: Bool) {
        miniGlass.isHidden = !enabled
        tabBar.isHidden = !enabled
        if !enabled {
            miniTitle.text = "Not Playing"
            miniArtist.text = ""
            setProgress(0)
        }
    }

    func setTrack(title: String?, artist: String?, artwork link: String?, duration: Double) {
        let name = (title?.isEmpty == false ? title : "Not Playing") ?? "Not Playing"
        miniTitle.text = name
        miniArtist.text = (artist?.isEmpty == false ? artist : nil)
        setProgress(0)
        loadArtwork(link)
    }

    func setPlaying(playing: Bool, progress: Double) {
        isPlaying = playing
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
        setProgress(progress)
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
            DispatchQueue.main.async { self.miniArtwork.image = image }
        }
        artworkTask?.resume()
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
