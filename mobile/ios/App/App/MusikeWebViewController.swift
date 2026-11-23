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
final class MusikeWebViewController: CAPBridgeViewController {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let appearanceHandler = AppearanceHandler()
    private let routeHandler = RouteHandler()

    private let tabGlass = UIVisualEffectView(frame: .zero)
    private let miniGlass = UIVisualEffectView(frame: .zero)
    private var tabButtons: [UIButton] = []
    private let miniArtwork = UIImageView()
    private let miniTitle = UILabel()
    private let miniArtist = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progressBar = UIView()

    private var appearanceMode = "system"
    private var isPlaying = false
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?

    private let routes = ["/", "/search", "/library"]

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        NativeGlass.shared.host = self
        bridge?.registerPluginInstance(GlassPlayerPlugin())

        webView?.configuration.userContentController.add(playback, name: "musikeMedia")
        webView?.configuration.userContentController.add(youtube, name: "musikeResolve")
        webView?.configuration.userContentController.add(audio, name: "musikeAudio")
        webView?.configuration.userContentController.add(appearanceHandler, name: "musikeAppearance")
        webView?.configuration.userContentController.add(routeHandler, name: "musikeRoute")
        appearanceHandler.controller = self
        routeHandler.controller = self
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
        tabGlass.effect = liquidGlassEffect()
        miniGlass.effect = liquidGlassEffect()
        tabGlass.layer.cornerRadius = 26
        miniGlass.layer.cornerRadius = 18
        tabGlass.layer.masksToBounds = true
        miniGlass.layer.masksToBounds = true
        tabGlass.translatesAutoresizingMaskIntoConstraints = false
        miniGlass.translatesAutoresizingMaskIntoConstraints = false

        buildTabBar()
        buildMiniPlayer()

        view.addSubview(tabGlass)
        view.addSubview(miniGlass)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tabGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabGlass.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            tabGlass.heightAnchor.constraint(equalToConstant: 72),

            miniGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            miniGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            miniGlass.bottomAnchor.constraint(equalTo: tabGlass.topAnchor, constant: -10),
            miniGlass.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func buildTabBar() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        tabGlass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: tabGlass.contentView.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: tabGlass.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: tabGlass.contentView.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: tabGlass.contentView.bottomAnchor, constant: -4)
        ])

        let items: [(String, String, String)] = [
            ("house.fill", "Home", "home"),
            ("magnifyingglass", "Search", "search"),
            ("music.note.square.stack", "Library", "library")
        ]
        for (index, item) in items.enumerated() {
            let button = makeTabButton(symbol: item.0, title: item.1, tag: index)
            button.accessibilityIdentifier = "glass-tab-\(item.2)"
            tabButtons.append(button)
            stack.addArrangedSubview(button)
        }
        setActiveTab(0)
    }

    private func makeTabButton(symbol: String, title: String, tag: Int) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        config.title = title
        config.imagePlacement = .top
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 4, trailing: 4)
        config.background.cornerRadius = 20
        let button = UIButton(configuration: config)
        button.tag = tag
        button.tintColor = .label
        button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
        return button
    }

    private func setActiveTab(_ index: Int) {
        for (i, button) in tabButtons.enumerated() {
            var config = button.configuration
            let active = i == index
            config?.background.backgroundColor = active ? UIColor.systemBlue.withAlphaComponent(0.22) : .clear
            config?.baseForegroundColor = active ? .systemBlue : .label
            button.configuration = config
            button.accessibilityTraits = active ? [.button, .selected] : .button
        }
    }

    private func buildMiniPlayer() {
        progressBar.backgroundColor = UIColor.label.withAlphaComponent(0.45)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        miniGlass.contentView.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: miniGlass.contentView.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: miniGlass.contentView.leadingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
            progressBar.widthAnchor.constraint(equalToConstant: 0)
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
        nav[aria-label="Main navigation"] { display: none !important; }
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

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let text = String(data: data, encoding: .utf8)!
        return String(text.dropFirst().dropLast())
    }

    @objc private func tabTapped(_ button: UIButton) {
        let index = button.tag
        guard routes.indices.contains(index) else { return }
        setActiveTab(index)
        navigate(to: routes[index])
    }

    private func navigate(to route: String) {
        let js = "history.pushState({}, '', \(jsString(route))); window.dispatchEvent(new PopStateEvent('popstate'));"
        webView?.evaluateJavaScript(js)
    }

    func setRoute(_ path: String) {
        if path.hasPrefix("/search") { setActiveTab(1) }
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
        tabGlass.isHidden = !enabled
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
        progressBar.widthAnchor.constraint(equalToConstant: width).isActive = true
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
