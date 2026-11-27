import UIKit
import WebKit

/// Serves the bundled web app from `musike://app/...`.
/// The host part is ignored; the path is the app route, which lets the
/// web app's history-based router keep working inside WKWebView.
private final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let mime: [String: String] = [
        "html": "text/html", "js": "application/javascript", "css": "text/css",
        "json": "application/json", "png": "image/png", "svg": "image/svg+xml",
        "woff2": "font/woff2", "woff": "font/woff", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "webp": "image/webp"
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return fail(urlSchemeTask) }
        var path = url.path.isEmpty ? "/" : url.path
        if path == "/" { path = "/index.html" }

        let root = Bundle.main.bundleURL
            .appendingPathComponent("public", isDirectory: true)
            .standardizedFileURL
        let candidate = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard candidate.path.hasPrefix(root.path) else { return fail(urlSchemeTask) }

        do {
            let data = try Data(contentsOf: candidate)
            let type = mime[(candidate.pathExtension as NSString).lowercased] ?? "application/octet-stream"
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": type]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: URL(string: "musike://app/")!, statusCode: 404,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"]
        )!
        task.didReceive(response)
        task.didReceive(Data("Not found".utf8))
        task.didFinish()
    }
}

final class GlassViewController: UIViewController, WKNavigationDelegate, UITabBarDelegate {
    private let webView: WKWebView
    private let tabBar = UITabBar()
    private let miniPlayer = UIVisualEffectView(effect: nil)

    private let routes = ["/", "/search", "/library", "/search"]

    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: "musike")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        applyGlass()
        layout()
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: URL(string: "musike://app/")!))

        // Let the web view drive the system theme; do not force an override.
        overrideUserInterfaceStyle = .unspecified
    }

    private func applyGlass() {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = glass
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.items = [
            UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill"), tag: 0),
            UITabBarItem(title: "Radio", image: UIImage(systemName: "radiowaves.left"), tag: 1),
            UITabBarItem(title: "Library", image: UIImage(systemName: "music.note"), tag: 2),
            UITabBarItem(title: "Search", image: UIImage(systemName: "magnifyingglass"), tag: 3)
        ]
        tabBar.selectedItem = tabBar.items?.first

        miniPlayer.effect = UIGlassEffect(style: .regular)
        miniPlayer.layer.cornerRadius = 16
        miniPlayer.layer.masksToBounds = true
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = "Not Playing"
        label.textColor = .label
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: miniPlayer.contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: miniPlayer.contentView.centerYAnchor)
        ])
    }

    private func layout() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(miniPlayer)
        view.addSubview(tabBar)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            miniPlayer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            miniPlayer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            miniPlayer.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -4),
            miniPlayer.heightAnchor.constraint(equalToConstant: 46),

            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 58)
        ])
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 120, right: 0)
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let index = tabBar.items?.firstIndex(of: item) else { return }
        let route = routes[index]
        let js = "history.pushState({}, '', '\(route)'); window.dispatchEvent(new PopStateEvent('popstate'));"
        webView.evaluateJavaScript(js)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The web skin's own bottom bars are replaced by the native glass ones.
        let css = """
        const s=document.createElement('style');s.id='native-glass-hide';
        s.textContent='nav.fixed[aria-label="Main navigation"],.am-mini-idle,.am-mini-real,.island[class*="bottom-"]{display:none!important}main{padding-bottom:120px!important}';
        document.head.appendChild(s);
        """
        webView.evaluateJavaScript(css)
    }
}
