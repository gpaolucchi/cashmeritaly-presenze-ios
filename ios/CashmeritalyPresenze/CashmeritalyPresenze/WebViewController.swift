import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let uc = config.userContentController
        uc.add(self, name: "cashmeritaly")
        // Espone le stesse API JS usate su Android
        let js = """
        (function(){
          window.__CASHMERITALY_NATIVE__ = true;
          window.__CASHMERITALY_PLATFORM__ = 'ios';
          window.CashmeritalyNativeStartMonitor = function(cfg) {
            try {
              window.webkit.messageHandlers.cashmeritaly.postMessage({action:'startMonitor', config: cfg||{}});
            } catch(e) {}
          };
          window.CashmeritalyNativeStopMonitor = function() {
            try {
              window.webkit.messageHandlers.cashmeritaly.postMessage({action:'stopMonitor'});
            } catch(e) {}
          };
        })();
        """
        uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = UIColor(red: 0.31, green: 0.43, blue: 0.97, alpha: 1)
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            webView.topAnchor.constraint(equalTo: progress.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        webView.load(URLRequest(url: AppConfig.webURL))
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: "estimatedProgress")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" {
            progress.progress = Float(webView.estimatedProgress)
            progress.isHidden = webView.estimatedProgress >= 1
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "cashmeritaly",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        if action == "stopMonitor" {
            LocationMonitor.shared.stop()
            return
        }
        if action == "startMonitor" {
            let cfg = body["config"] as? [String: Any] ?? [:]
            let negozioId = intVal(cfg["negozio_id"])
            let lat = doubleVal(cfg["lat"])
            let lng = doubleVal(cfg["lng"])
            let raggio = intVal(cfg["raggio_metri"])
            let token = (cfg["monitor_token"] as? String) ?? ""
            LocationMonitor.shared.start(
                negozioId: negozioId,
                lat: lat,
                lng: lng,
                raggio: raggio > 0 ? raggio : 150,
                token: token
            )
            // Chiedi permesso Always se ancora WhenInUse
            LocationMonitor.shared.restoreIfNeeded()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let host = url.host,
           !host.contains("cashmeritaly.cloud"),
           navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func intVal(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    private func doubleVal(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return 0
    }
}
