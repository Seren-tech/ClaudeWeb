import UIKit
import WebKit

// MARK: - Config

enum Config {
    static let startURL = URL(string: "https://claude.ai")!
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_1_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.1 Mobile/15E148 Safari/604.1"
    static let maxLogLines = 2000
}

// MARK: - Injected JavaScript

enum UserScripts {

    // 1) Debug hook: forwards console / errors to native. Runs first so later failures are captured.
    static let debugHook = #"""
    (function () {
      if (window.__nativeDebugInstalled) return;
      window.__nativeDebugInstalled = true;
      var frameTag = (function () {
        try { return window === window.top ? 'top' : 'sub:' + location.host; } catch (e) { return 'sub'; }
      })();
      function fmt(a) {
        try {
          if (a instanceof Error) return a.stack || a.message;
          if (typeof a === 'object' && a !== null) return JSON.stringify(a);
          return String(a);
        } catch (e) { return String(a); }
      }
      function send(level, msg) {
        try {
          window.webkit.messageHandlers.nativeLog.postMessage({ level: level, msg: String(msg), frame: frameTag });
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error'].forEach(function (lvl) {
        var orig = console[lvl];
        console[lvl] = function () {
          send(lvl, Array.prototype.map.call(arguments, fmt).join(' '));
          if (orig) { try { orig.apply(console, arguments); } catch (e) {} }
        };
      });
      // Equivalent to window.onerror, plus resource load errors (capture phase).
      window.addEventListener('error', function (e) {
        if (e.target && e.target !== window) {
          send('error', 'resource error: <' + (e.target.tagName || '?') + '> ' + (e.target.src || e.target.href || ''));
        } else {
          send('error', 'onerror: ' + e.message + ' @ ' + e.filename + ':' + e.lineno + ':' + e.colno +
               (e.error && e.error.stack ? '\n' + e.error.stack : ''));
        }
      }, true);
      window.addEventListener('unhandledrejection', function (e) {
        send('error', 'unhandledrejection: ' + fmt(e.reason));
      });
      send('info', 'debug hook installed @ ' + location.href);
    })();
    """#

    // 2) Small hand-written polyfills (feature-checked). Syntax-level features cannot be polyfilled.
    static let minimalPolyfills = #"""
    (function () {
      var g = (typeof globalThis !== 'undefined') ? globalThis : window;
      function def(obj, name, fn) {
        if (!obj[name]) Object.defineProperty(obj, name, { value: fn, configurable: true, writable: true });
      }
      try {
        def(Object, 'hasOwn', function (o, k) { return Object.prototype.hasOwnProperty.call(Object(o), k); });

        def(Array.prototype, 'at', function (n) {
          n = Math.trunc(n) || 0; if (n < 0) n += this.length;
          return (n < 0 || n >= this.length) ? undefined : this[n];
        });
        def(String.prototype, 'at', function (n) {
          var s = String(this); n = Math.trunc(n) || 0; if (n < 0) n += s.length;
          return (n < 0 || n >= s.length) ? undefined : s.charAt(n);
        });
        def(Array.prototype, 'findLast', function (fn, t) {
          for (var i = this.length - 1; i >= 0; i--) if (fn.call(t, this[i], i, this)) return this[i];
          return undefined;
        });
        def(Array.prototype, 'findLastIndex', function (fn, t) {
          for (var i = this.length - 1; i >= 0; i--) if (fn.call(t, this[i], i, this)) return i;
          return -1;
        });
        def(Array.prototype, 'toSorted', function (cmp) { return Array.prototype.slice.call(this).sort(cmp); });
        def(Array.prototype, 'toReversed', function () { return Array.prototype.slice.call(this).reverse(); });

        if (typeof Promise.withResolvers !== 'function') {
          Promise.withResolvers = function () {
            var resolve, reject;
            var promise = new Promise(function (a, b) { resolve = a; reject = b; });
            return { promise: promise, resolve: resolve, reject: reject };
          };
        }

        if (g.crypto && typeof g.crypto.randomUUID !== 'function' && g.crypto.getRandomValues) {
          g.crypto.randomUUID = function () {
            var b = g.crypto.getRandomValues(new Uint8Array(16));
            b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
            var h = Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); });
            return h.slice(0, 4).join('') + '-' + h.slice(4, 6).join('') + '-' + h.slice(6, 8).join('') + '-' +
                   h.slice(8, 10).join('') + '-' + h.slice(10).join('');
          };
        }

        if (g.AbortSignal && typeof g.AbortSignal.timeout !== 'function') {
          g.AbortSignal.timeout = function (ms) {
            var c = new AbortController();
            setTimeout(function () { c.abort(); }, ms);
            return c.signal;
          };
        }

        if (typeof g.structuredClone !== 'function') {
          g.structuredClone = function (value) {
            var seen = new Map();
            function c(x) {
              if (typeof x === 'function' || typeof x === 'symbol') throw new DOMException('Value is not cloneable', 'DataCloneError');
              if (x === null || typeof x !== 'object') return x;
              if (seen.has(x)) return seen.get(x);
              var r;
              if (x instanceof Date) return new Date(x.getTime());
              if (x instanceof RegExp) return new RegExp(x.source, x.flags);
              if (x instanceof ArrayBuffer) return x.slice(0);
              if (ArrayBuffer.isView(x)) {
                return (x instanceof DataView)
                  ? new DataView(x.buffer.slice(0), x.byteOffset, x.byteLength)
                  : new x.constructor(x);
              }
              if (x instanceof Map) { r = new Map(); seen.set(x, r); x.forEach(function (v, k) { r.set(c(k), c(v)); }); return r; }
              if (x instanceof Set) { r = new Set(); seen.set(x, r); x.forEach(function (v) { r.add(c(v)); }); return r; }
              if (Array.isArray(x)) { r = []; seen.set(x, r); for (var i = 0; i < x.length; i++) r[i] = c(x[i]); return r; }
              r = {}; seen.set(x, r);
              Object.keys(x).forEach(function (k) { r[k] = c(x[k]); });
              return r;
            }
            return c(value);
          };
        }
      } catch (e) {
        try { console.error('minimalPolyfills failed: ' + e); } catch (_) {}
      }
    })();
    """#

    // 3) >>> PASTE EXTRA POLYFILLS HERE (e.g. the contents of core-js-bundle's minified.js) <<<
    //    Paste between the #""" and """# lines. Do not leave a literal  """#  inside the pasted text.
    static let extraPolyfills = #"""
    /* PLACEHOLDER: paste core-js bundle or other polyfills here */
    """#

    static var combined: String {
        // Each part is wrapped so one failing part cannot stop the others.
        return [debugHook, minimalPolyfills, extraPolyfills]
            .map { "try {\n\($0)\n} catch (e) { try { console.error('userscript part failed: ' + e); } catch (_) {} }" }
            .joined(separator: "\n;\n")
    }
}

// MARK: - Weak proxy (WKUserContentController retains its handlers)

@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - ViewController

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private let panel = UIView()
    private let textView = UITextView()
    private let toggleButton = UIButton(type: .system)
    private var copyButton: UIButton?

    private var logLines: [String] = []
    private var refreshScheduled = false
    private var didPlaceToggle = false

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupPanel()
        setupToggle()
        appendLog("native", "loading \(Config.startURL.absoluteString)")
        webView.load(URLRequest(url: Config.startURL))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didPlaceToggle && view.bounds.width > 0 {
            didPlaceToggle = true
            toggleButton.frame = CGRect(
                x: view.bounds.width - 56,
                y: view.safeAreaInsets.top + 120,
                width: 44, height: 44)
        }
    }

    // MARK: Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()   // persistent
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let ucc = WKUserContentController()
        ucc.add(WeakScriptHandler(self), name: "nativeLog")
        ucc.addUserScript(WKUserScript(
            source: UserScripts.combined,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        config.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: g.topAnchor),
            wv.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: g.trailingAnchor)
        ])
        webView = wv
    }

    private func makePanelButton(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func setupPanel() {
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let copy = makePanelButton("Copy all", #selector(copyLogs))
        copyButton = copy
        let clear = makePanelButton("Clear", #selector(clearLogs))
        let close = makePanelButton("Close", #selector(togglePanel))
        let reload = makePanelButton("Reload", #selector(reloadPage))

        let bar = UIStackView(arrangedSubviews: [copy, clear, reload, close])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(bar)

        textView.isEditable = false
        textView.isSelectable = true          // long-press to select / copy
        textView.backgroundColor = .clear
        textView.textColor = UIColor(red: 0.7, green: 1.0, blue: 0.7, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(textView)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            panel.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),

            bar.topAnchor.constraint(equalTo: panel.topAnchor),
            bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),

            textView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            textView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            textView.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
    }

    private func setupToggle() {
        toggleButton.setTitle("DBG", for: .normal)
        toggleButton.setTitleColor(.white, for: .normal)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        toggleButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toggleButton.layer.cornerRadius = 22
        toggleButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        toggleButton.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragToggle(_:))))
        view.addSubview(toggleButton)   // added last = always on top
    }

    // MARK: Actions

    @objc private func togglePanel() {
        panel.isHidden.toggle()
        if !panel.isHidden { refreshText() }
    }

    @objc private func copyLogs() {
        UIPasteboard.general.string = logLines.joined(separator: "\n")
        copyButton?.setTitle("Copied", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton?.setTitle("Copy all", for: .normal)
        }
    }

    @objc private func clearLogs() {
        logLines.removeAll()
        refreshText()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func dragToggle(_ g: UIPanGestureRecognizer) {
        guard let v = g.view else { return }
        let t = g.translation(in: view)
        v.center = CGPoint(x: v.center.x + t.x, y: v.center.y + t.y)
        g.setTranslation(.zero, in: view)
    }

    // MARK: Logging

    private func appendLog(_ level: String, _ msg: String) {
        let line = "[\(timeFormatter.string(from: Date()))] \(level.uppercased()): \(msg)"
        logLines.append(line)
        if logLines.count > Config.maxLogLines {
            logLines.removeFirst(logLines.count - Config.maxLogLines)
        }
        guard !panel.isHidden, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshScheduled = false
            self?.refreshText()
        }
    }

    private func refreshText() {
        textView.text = logLines.joined(separator: "\n")
        let len = (textView.text as NSString).length
        textView.scrollRangeToVisible(NSRange(location: len, length: 0))
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativeLog", let body = message.body as? [String: Any] else { return }
        let level = (body["level"] as? String) ?? "log"
        let msg = (body["msg"] as? String) ?? ""
        let frame = (body["frame"] as? String) ?? "?"
        appendLog("js.\(level)", "(\(frame)) \(msg)")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            UIApplication.shared.open(url)   // mailto:, tel:, etc.
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendLog("native", "didFinish \(webView.url?.absoluteString ?? "-")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logNavError("didFail", error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logNavError("didFailProvisional", error)
    }

    private func logNavError(_ tag: String, _ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        appendLog("native.error", "\(tag): \(e.domain) \(e.code) \(e.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        appendLog("native.error", "web content process terminated; reloading")
        webView.reload()
    }

    // MARK: WKUIDelegate

    // target=_blank / window.open -> same web view
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(a.textFields?.first?.text)
        })
        present(a, animated: true)
    }

    // Camera / microphone requests from web pages (iOS 15.0+)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}
