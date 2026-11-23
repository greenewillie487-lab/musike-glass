import Capacitor
import UIKit
import WebKit

/// Reports the web mini-player's text to the native glass bar.
private final class GlassMessageHandler: NSObject, WKScriptMessageHandler {
    weak var controller: MusikeWebViewController?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String] else { return }
        controller?.updateMini(title: body["title"], artist: body["artist"])
    }
}

/// The app's web view with its original Capacitor bridges intact. The only
/// native addition is a Liquid Glass tab bar + mini-player above the web view.
final class MusikeWebViewController: CAPBridgeViewController {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let glassHandler = GlassMessageHandler()

    private let tabBar = UITabBar()
    private let miniPlayer = UIVisualEffectView(effect: nil)
    private let miniLabel = UILabel()

    private let routes = ["/", "/search", "/library", "/search"]

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        webView?.configuration.userContentController.add(playback, name: "musikeMedia")
        webView?.configuration.userContentController.add(youtube, name: "musikeResolve")
        webView?.configuration.userContentController.add(audio, name: "musikeAudio")
        webView?.configuration.userContentController.add(glassHandler, name: "musikeGlass")
        glassHandler.controller = self
        playback.attach(webView)
        youtube.attach(webView)
        audio.attach(webView)
        webView?.allowsBackForwardNavigationGestures = true

        installBootstrap()
        installGlassOverlay()
    }

    private func installBootstrap() {
        let css = """
        nav.fixed[aria-label="Main navigation"],
        div[class*="bottom-[calc("],
        .am-mini-idle, .am-mini-real,
        .island[class*="bottom-"] { display:none !important; }
        main { padding-bottom:160px !important; }
        """
        let source = """
        var css = \(jsString(css));
        function inject(){ if(document.head){ var s=document.createElement('style'); s.id='native-glass'; s.textContent=css; document.head.appendChild(s); } else setTimeout(inject,0); }
        inject();
        var nativeFetch = window.fetch.bind(window);
        window.fetch = function(input, init){ return nativeFetch(input, init); };
        setInterval(function(){
          var el = document.querySelector('.am-mini-real, div[class*="bottom-[calc(84px"]') || document.body;
          var t = el ? el.innerText : '';
          var lines = t.split('\\n').map(function(x){return x.trim();}).filter(Boolean);
          window.webkit?.messageHandlers?.musikeGlass?.postMessage({
            title: lines[0] || 'Not Playing',
            artist: lines[1] || ''
          });
        }, 500);
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView?.configuration.userContentController.addUserScript(script)
        webView?.evaluateJavaScript(source)
    }

    private func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }

    private func installGlassOverlay() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        tabBar.items = [
            UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill", withConfiguration: cfg), tag: 0),
            UITabBarItem(title: "Radio", image: UIImage(systemName: "radiowaves.left", withConfiguration: cfg), tag: 1),
            UITabBarItem(title: "Library", image: UIImage(systemName: "music.note", withConfiguration: cfg), tag: 2),
            UITabBarItem(title: "Search", image: UIImage(systemName: "magnifyingglass", withConfiguration: cfg), tag: 3)
        ]
        tabBar.selectedItem = tabBar.items?.first

        miniPlayer.effect = UIGlassEffect(style: .regular)
        miniPlayer.layer.cornerRadius = 20
        miniPlayer.layer.masksToBounds = true
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false

        miniLabel.text = "Not Playing"
        miniLabel.textColor = .label
        miniLabel.font = .systemFont(ofSize: 15, weight: .medium)
        miniLabel.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.contentView.addSubview(miniLabel)

        let play = UIImageView(image: UIImage(systemName: "play.fill"))
        let next = UIImageView(image: UIImage(systemName: "forward.end.fill"))
        play.tintColor = .label
        next.tintColor = .label
        play.translatesAutoresizingMaskIntoConstraints = false
        next.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.contentView.addSubview(play)
        miniPlayer.contentView.addSubview(next)

        view.addSubview(miniPlayer)
        view.addSubview(tabBar)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            miniLabel.leadingAnchor.constraint(equalTo: miniPlayer.contentView.leadingAnchor, constant: 16),
            miniLabel.centerYAnchor.constraint(equalTo: miniPlayer.contentView.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: miniPlayer.contentView.trailingAnchor, constant: -18),
            next.centerYAnchor.constraint(equalTo: miniPlayer.contentView.centerYAnchor),
            next.widthAnchor.constraint(equalToConstant: 20),
            play.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -20),
            play.centerYAnchor.constraint(equalTo: miniPlayer.contentView.centerYAnchor),
            play.widthAnchor.constraint(equalToConstant: 18),

            miniPlayer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            miniPlayer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            miniPlayer.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -6),
            miniPlayer.heightAnchor.constraint(equalToConstant: 62),

            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 68)
        ])
        webView?.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 160, right: 0)
    }

    func updateMini(title: String?, artist: String?) {
        let t = (title?.isEmpty == false ? title : "Not Playing") ?? "Not Playing"
        miniLabel.text = artist?.isEmpty == false ? "\(t) — \(artist!)" : t
    }
}

extension MusikeWebViewController: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let index = tabBar.items?.firstIndex(of: item) else { return }
        let route = routes[index]
        webView?.evaluateJavaScript("history.pushState({}, '', '\(route)'); window.dispatchEvent(new PopStateEvent('popstate'));")
    }
}
