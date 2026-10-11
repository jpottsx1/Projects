import Foundation
import WebKit
#if os(iOS)
import UIKit
#endif

/// Makes a full copy of a web page -- its text, pictures and styles -- as
/// a Safari web archive, by loading it in a browser view nobody sees.
///
/// Loading it properly, rather than just downloading the HTML, also means
/// pages that build their text with JavaScript are copied as they look,
/// and their text becomes searchable.
@MainActor
final class PageArchiver: NSObject, WKNavigationDelegate {
    struct Page {
        var archive: Data
        var title: String?
        /// The page's visible text, as shown.
        var text: String
    }

    /// Loads `url` and copies it. Nil if it doesn't load within the time
    /// allowed, or can't be copied.
    static func archive(_ url: URL) async -> Page? {
        let archiver = PageArchiver()
        return await archiver.run(url)
    }

    private let webView: WKWebView
    private var loading: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        // Nothing from these visits -- cookies, caches -- is kept.
        configuration.websiteDataStore = .nonPersistent()
        // A desktop-sized page, so sites send their full layout.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    private func run(_ url: URL) async -> Page? {
        attachOffscreen()
        defer { webView.removeFromSuperview() }

        let loaded: Bool = await withCheckedContinuation { continuation in
            loading = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                self?.finishLoading(false)
            }
        }
        guard loaded else {
            webView.stopLoading()
            return nil
        }
        // Pictures that load late, and scripts that fill the page in after
        // it says it has finished.
        try? await Task.sleep(for: .seconds(2))

        let text = await visibleText()
        guard let archive = await webArchive() else { return nil }
        return Page(archive: archive, title: webView.title, text: text)
    }

    private func visibleText() async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
    }

    private func webArchive() async -> Data? {
        await withCheckedContinuation { continuation in
            webView.createWebArchiveData { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    /// Resumes whoever is waiting for the load, once: a load can both fail
    /// and time out.
    private func finishLoading(_ succeeded: Bool) {
        timeout?.cancel()
        timeout = nil
        loading?.resume(returning: succeeded)
        loading = nil
    }

    /// iOS slows a web view that isn't in a window -- timers stall, lazy
    /// pictures never load -- so while copying it sits in the window,
    /// all but transparent and letting touches through. It keeps its full
    /// size, so the page lays itself out as it would on screen. A Mac
    /// loads it fine as it is.
    private func attachOffscreen() {
        #if os(iOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return }
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.addSubview(webView)
        #endif
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(false)
    }
}
