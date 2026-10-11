import SwiftUI
import WebKit
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A saved link: its address, the saved copy of the page to read offline,
/// and notes.
struct LinkDetail: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var isRefreshing = false
    @State private var copyURL: URL?
    /// Which saved version to show, when there's an article as well as the full page.
    @AppStorage("showArticle") private var showArticle = true
    @AppStorage("articleTextSize") private var articleTextSize = 1.0
    @State private var article = ArticleController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()

            Divider()

            Group {
                if showArticle, let saved = item.article {
                    ArticleView(controller: article, html: saved.page(textSize: articleTextSize), pageURL: item.url)
                        .onAppear { article.attach(item: item, library: library) }
                } else if let copyURL {
                    PageCopyView(fileURL: copyURL, pageURL: item.url)
                } else if library.copyingPages.contains(item.uuid) {
                    ProgressView("Saving a copy of the page…")
                } else if item.archivePath != nil {
                    ContentUnavailableView(
                        "Saved Copy Not on This Device Yet", systemImage: "icloud.and.arrow.down",
                        description: Text("It appears once iCloud has downloaded it. Copies over 100 MB stay on the device that saved them."))
                } else {
                    ContentUnavailableView {
                        Label("No Saved Copy", systemImage: "doc.richtext")
                    } description: {
                        Text("Save a copy to read this page offline, exactly as it was.")
                    } actions: {
                        Button("Save a Copy") {
                            Task { await library.savePageCopy(of: item) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.headline)
                TextEditor(text: $item.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
            }
            .padding()
        }
        .onChange(of: item.body) { library.didEdit(item) }
        .onChange(of: PDFReader.signature(item.sortedHighlights)) { article.showHighlights() }
        .onChange(of: library.revealedHighlight) { _, highlight in
            guard let highlight, highlight.item == item, case .article? = highlight.anchor else { return }
            showArticle = true
            article.reveal(highlight)
            library.revealedHighlight = nil
        }
        .toolbar {
            if item.article != nil {
                ToolbarItem {
                    Picker("Show", selection: $showArticle) {
                        Text("Article").tag(true)
                        Text("Full Page").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("The article on its own, or the whole page as it was")
                }
                if showArticle {
                    ToolbarItem {
                        HighlightMenu { color, withNote in
                            Task { await highlightSelection(color, withNote: withNote) }
                        }
                    }
                    ToolbarItem {
                        Menu {
                            Button("Larger Text") { articleTextSize = min(articleTextSize + 0.1, 2.5) }
                            Button("Smaller Text") { articleTextSize = max(articleTextSize - 0.1, 0.6) }
                            Button("Actual Size") { articleTextSize = 1 }
                        } label: {
                            Label("Text Size", systemImage: "textformat.size")
                        }
                    }
                }
            }
        }
        // Looked for again whenever the library changes: that includes a
        // copy being saved, or arriving from iCloud.
        .task(id: library.revision) {
            copyURL = library.localPageCopy(for: item)
        }
    }

    private func highlightSelection(_ color: HighlightColor, withNote: Bool) async {
        guard let selected = await article.selection() else { return }
        let highlight = library.addHighlight(to: item, text: selected.words, anchor: .article(quote: selected.quote),
                                             position: selected.fraction, color: color)
        if withNote { library.editingHighlight = highlight }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = item.url {
                HStack {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        Task {
                            isRefreshing = true
                            await library.refreshPage(of: item)
                            isRefreshing = false
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing || library.copyingPages.contains(item.uuid))
                    .help("Fetch the page again: its latest summary, text to search, and a new saved copy")
                }
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let date = item.archivedAt {
                Text("Copy saved \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows a saved web archive. Links in it open in the browser rather than
/// replacing the copy.
#if os(macOS)
struct PageCopyView: NSViewRepresentable {
    let fileURL: URL
    let pageURL: URL?

    func makeCoordinator() -> PageCopyCoordinator { PageCopyCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = PageCopyCoordinator.makeWebView()
        view.navigationDelegate = context.coordinator
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
    }
}
#else
struct PageCopyView: UIViewRepresentable {
    let fileURL: URL
    let pageURL: URL?

    func makeCoordinator() -> PageCopyCoordinator { PageCopyCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = PageCopyCoordinator.makeWebView()
        view.navigationDelegate = context.coordinator
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.show(fileURL, baseURL: pageURL, in: view)
    }
}
#endif

@MainActor
final class PageCopyCoordinator: NSObject, WKNavigationDelegate {
    private var shown: URL?
    private var shownDate: Date?

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Loads the copy, unless it's the one already showing -- a redraw
    /// mustn't reload the page and lose your place in it.
    func show(_ fileURL: URL, baseURL: URL?, in view: WKWebView) {
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard fileURL != shown || modified != shownDate,
              let data = try? Data(contentsOf: fileURL) else { return }
        shown = fileURL
        shownDate = modified
        view.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                  baseURL: baseURL ?? fileURL)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            return .allow
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        _ = await UIApplication.shared.open(url)
        #endif
        return .cancel
    }
}

/// Runs a clean article's web view: showing it, its highlights, and links.
@MainActor
final class ArticleController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) weak var webView: WKWebView?
    private weak var item: Item?
    private weak var library: Library?
    private var shownHTML: String?
    private var loaded = false
    private var revealAfterLoad: UUID?

    func attach(item: Item, library: Library) {
        self.item = item
        self.library = library
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakMessageHandler(self), name: "stash")
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebHighlights.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    /// Loads the article, unless it's the one already showing.
    func show(html: String, baseURL: URL?) {
        guard html != shownHTML, let webView else { return }
        shownHTML = html
        loaded = false
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func showHighlights() {
        guard loaded, let webView, let item else { return }
        let highlights = item.sortedHighlights.compactMap { highlight -> (Highlight, TextQuote)? in
            guard case .article(let quote)? = highlight.anchor else { return nil }
            return (highlight, quote)
        }
        Task { await WebHighlights.show(highlights, in: webView) }
    }

    func reveal(_ highlight: Highlight) {
        if loaded, let webView {
            WebHighlights.reveal(highlight.uuid, in: webView)
        } else {
            revealAfterLoad = highlight.uuid
        }
    }

    func selection() async -> WebHighlights.Selection? {
        guard let webView else { return nil }
        return await WebHighlights.selection(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        showHighlights()
        if let id = revealAfterLoad {
            revealAfterLoad = nil
            // After the highlights are marked, which is a moment's work.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                WebHighlights.reveal(id, in: webView)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            return .allow
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        _ = await UIApplication.shared.open(url)
        #endif
        return .cancel
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "tap",
              let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        library?.editingHighlight = item?.highlights?.first { $0.uuid == id }
    }
}

/// A clean article, laid out for reading. Links open in the browser.
#if os(macOS)
struct ArticleView: NSViewRepresentable {
    let controller: ArticleController
    let html: String
    let pageURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let view = controller.webView ?? controller.makeWebView()
        controller.show(html: html, baseURL: pageURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        controller.show(html: html, baseURL: pageURL)
    }
}
#else
struct ArticleView: UIViewRepresentable {
    let controller: ArticleController
    let html: String
    let pageURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let view = controller.webView ?? controller.makeWebView()
        controller.show(html: html, baseURL: pageURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        controller.show(html: html, baseURL: pageURL)
    }
}
#endif
