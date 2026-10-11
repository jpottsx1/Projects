import SwiftUI
import WebKit
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reads an EPUB book a chapter at a time, remembering where you got to.
/// Select some text, then Highlight; tap a highlight to write a note on it.
struct EPUBReader: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    @State private var document: EPUBDocument?
    @State private var failed = false
    @State private var controller = EPUBController()
    @AppStorage("bookZoom") private var zoom = 1.0

    var body: some View {
        Group {
            if let document {
                EPUBWebView(controller: controller)
                    .onAppear { controller.open(document, item: item, library: library, zoom: zoom) }
            } else if failed {
                ContentUnavailableView("Can’t Read This Book", systemImage: "book.closed",
                                       description: Text("The file isn’t an EPUB book Stash understands. Quick Look may still show it."))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let url = self.url
            let opened = await Task.detached(priority: .userInitiated) { try? EPUBDocument(url: url) }.value
            document = opened
            failed = opened == nil
        }
        .onChange(of: PDFReader.signature(item.sortedHighlights)) {
            controller.showHighlights()
        }
        .onChange(of: library.revealedHighlight) { _, highlight in
            guard let highlight, highlight.item == item else { return }
            controller.reveal(highlight)
            library.revealedHighlight = nil
        }
        .onChange(of: zoom) { controller.setZoom(zoom) }
        .toolbar {
            if let document {
                ToolbarItemGroup {
                    Button {
                        controller.go(by: -1)
                    } label: {
                        Label("Previous Chapter", systemImage: "chevron.left")
                    }
                    .disabled(controller.chapter <= 0)
                    contents(of: document.book)
                    Button {
                        controller.go(by: 1)
                    } label: {
                        Label("Next Chapter", systemImage: "chevron.right")
                    }
                    .disabled(controller.chapter >= document.book.chapters.count - 1)
                }
                ToolbarItem {
                    Menu {
                        Button("Larger Text") { zoom = min(zoom + 0.1, 3) }
                        Button("Smaller Text") { zoom = max(zoom - 0.1, 0.5) }
                        Button("Actual Size") { zoom = 1 }
                    } label: {
                        Label("Text Size", systemImage: "textformat.size")
                    }
                }
                ToolbarItem {
                    HighlightMenu { color, withNote in
                        Task { await highlightSelection(color, withNote: withNote) }
                    }
                }
            }
        }
    }

    private func contents(of book: EPUBBook) -> some View {
        Menu {
            if book.toc.isEmpty {
                ForEach(book.chapters.indices, id: \.self) { index in
                    Button("Chapter \(index + 1)") { controller.open(target: book.chapters[index].path) }
                }
            } else {
                ForEach(Array(book.toc.enumerated()), id: \.offset) { _, entry in
                    Button(String(repeating: "    ", count: min(entry.level, 4)) + entry.title) {
                        controller.open(target: entry.target)
                    }
                }
            }
        } label: {
            Label("Contents", systemImage: "list.bullet")
        }
        .help(book.title ?? "Contents")
    }

    private func highlightSelection(_ color: HighlightColor, withNote: Bool) async {
        guard let passage = await controller.selectedPassage() else { return }
        let highlight = library.addHighlight(to: item, text: passage.text, anchor: passage.anchor,
                                             position: passage.position, color: color)
        if withNote { library.editingHighlight = highlight }
    }
}

/// Runs the book's web view: which chapter is showing, the highlights in
/// it, and where you are.
@MainActor
@Observable
final class EPUBController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let scheme = "stash-book"

    private(set) var chapter = 0
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var document: EPUBDocument?
    @ObservationIgnored private weak var item: Item?
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var scrollAfterLoad: Double?
    @ObservationIgnored private var revealAfterLoad: UUID?

    struct Passage {
        var text: String
        var anchor: HighlightAnchor
        var position: Double
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EPUBSchemeHandler(controller: self), forURLScheme: Self.scheme)
        let scripts = configuration.userContentController
        scripts.add(WeakMessageHandler(self), name: "stash")
        scripts.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func file(at path: String) throws -> Data {
        guard let document else { throw URLError(.fileDoesNotExist) }
        return try document.data(at: path)
    }

    /// Shows the book, at the chapter and place it was left.
    func open(_ document: EPUBDocument, item: Item, library: Library, zoom: Double) {
        guard self.document !== document else { return }
        self.document = document
        self.item = item
        self.library = library
        setZoom(zoom)
        let saved = item.readingPosition.split(separator: "|", maxSplits: 1)
        if let path = saved.first.map(String.init), let index = document.book.chapterIndex(for: path) {
            scrollAfterLoad = saved.count > 1 ? Double(saved[1]) : nil
            load(index)
        } else {
            load(0)
        }
    }

    func setZoom(_ zoom: Double) {
        webView?.pageZoom = zoom
    }

    func go(by step: Int) {
        guard let count = document?.book.chapters.count else { return }
        load(min(max(chapter + step, 0), count - 1))
    }

    /// A chapter, perhaps with "#section" after it.
    func open(target: String) {
        guard let book = document?.book, let index = book.chapterIndex(for: target) else { return }
        let fragment = target.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
        load(index, fragment: fragment)
    }

    private func load(_ index: Int, fragment: String? = nil) {
        guard let book = document?.book, book.chapters.indices.contains(index), let webView else { return }
        chapter = index
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "book"
        components.path = "/" + book.chapters[index].path
        components.fragment = fragment
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }

    var chapterPath: String? {
        document?.book.chapters.indices.contains(chapter) == true ? document?.book.chapters[chapter].path : nil
    }

    // MARK: - Highlights

    /// Draws this chapter's highlights, found again by their words.
    func showHighlights() {
        guard let webView, let path = chapterPath, let item else { return }
        let highlights = item.sortedHighlights
        Task {
            guard let text = try? await webView.evaluateJavaScript("stash.text()") as? String else { return }
            var marks: [[String: Any]] = []
            for highlight in highlights {
                guard case .epub(let chapter, let quote)? = highlight.anchor, chapter == path,
                      let range = quote.locate(in: text) else { continue }
                marks.append(["id": highlight.uuid.uuidString, "start": range.lowerBound, "end": range.upperBound,
                              "color": highlight.colorRaw])
            }
            let json = (try? JSONSerialization.data(withJSONObject: marks)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            _ = try? await webView.evaluateJavaScript("stash.unmarkAll(); stash.mark(\(json));")
            if let reveal = revealAfterLoad {
                revealAfterLoad = nil
                _ = try? await webView.evaluateJavaScript("stash.reveal('\(reveal.uuidString)')")
            }
        }
    }

    func reveal(_ highlight: Highlight) {
        guard case .epub(let path, _)? = highlight.anchor, let book = document?.book,
              let index = book.chapterIndex(for: path) else { return }
        if index == chapter {
            webView?.evaluateJavaScript("stash.reveal('\(highlight.uuid.uuidString)')")
        } else {
            revealAfterLoad = highlight.uuid
            load(index)
        }
    }

    func selectedPassage() async -> Passage? {
        guard let webView, let path = chapterPath,
              let found = try? await webView.evaluateJavaScript("stash.selection()") as? [String: Any],
              let start = (found["start"] as? NSNumber)?.intValue, let end = (found["end"] as? NSNumber)?.intValue,
              let text = found["text"] as? String,
              let quote = TextQuote(in: text, start: start, end: end) else { return nil }
        let words = quote.exact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        _ = try? await webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        let length = max(text.utf16.count, 1)
        return Passage(text: words, anchor: .epub(chapter: path, quote: quote),
                       position: Double(chapter) + Double(start) / Double(length))
    }

    // MARK: - Web view

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == Self.scheme {
            // A link to another chapter.
            if navigationAction.navigationType == .linkActivated, let book = document?.book,
               let index = book.chapterIndex(for: String(url.path.dropFirst())) {
                chapter = index
            }
            return .allow
        }
        if navigationAction.navigationType == .linkActivated {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            _ = await UIApplication.shared.open(url)
            #endif
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let fraction = scrollAfterLoad {
            scrollAfterLoad = nil
            webView.evaluateJavaScript("stash.scrollTo(\(fraction))")
        } else {
            savePosition(0)
        }
        showHighlights()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "position":
            savePosition((body["value"] as? NSNumber)?.doubleValue ?? 0)
        case "tap":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            library?.editingHighlight = item?.highlights?.first { $0.uuid == id }
        default:
            break
        }
    }

    private func savePosition(_ fraction: Double) {
        guard let item, let library, let path = chapterPath else { return }
        let position = "\(path)|\((fraction * 1000).rounded() / 1000)"
        if item.readingPosition != position {
            item.readingPosition = position
            library.save()
        }
    }

    /// Finds text, marks highlights, reports scrolling and taps. Offsets
    /// count UTF-16 units through the body's text nodes, as `TextQuote` does.
    static let script = #"""
    (function () {
      const style = document.createElement('style');
      style.textContent = `
        :root { color-scheme: light dark; }
        body { max-width: 40em; margin: 0 auto !important; padding: 1.5em 1.5em 4em !important; line-height: 1.6; }
        img, svg, video { max-width: 100%; height: auto; }
        mark.stash-hl { color: inherit; border-radius: 2px; cursor: pointer; }
        mark.stash-yellow { background: rgba(255, 214, 10, .45); }
        mark.stash-green { background: rgba(52, 199, 89, .35); }
        mark.stash-blue { background: rgba(10, 132, 255, .3); }
        mark.stash-pink { background: rgba(255, 55, 95, .3); }
        mark.stash-purple { background: rgba(191, 90, 242, .3); }`;
      (document.head || document.documentElement).appendChild(style);

      const post = (message) => window.webkit.messageHandlers.stash.postMessage(message);
      const textNodes = () => {
        const nodes = [];
        if (!document.body) return nodes;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) nodes.push(node);
        return nodes;
      };
      const offsetOf = (container, offset) => {
        const range = document.createRange();
        range.setStart(document.body, 0);
        range.setEnd(container, offset);
        return range.toString().length;
      };

      const stash = {
        text: () => textNodes().map((node) => node.data).join(''),
        selection: () => {
          const selection = window.getSelection();
          if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
          const range = selection.getRangeAt(0);
          try {
            return { start: offsetOf(range.startContainer, range.startOffset),
                     end: offsetOf(range.endContainer, range.endOffset), text: stash.text() };
          } catch (error) { return null; }
        },
        mark: (marks) => {
          for (const mark of marks) {
            let position = 0;
            const spans = textNodes().map((node) => {
              const span = { node, start: position, end: position + node.data.length };
              position = span.end;
              return span;
            });
            for (const span of spans) {
              const from = Math.max(mark.start, span.start), to = Math.min(mark.end, span.end);
              if (from >= to) continue;
              if (!span.node.data.slice(from - span.start, to - span.start).trim()) continue;
              let target = span.node;
              if (to - span.start < target.data.length) target.splitText(to - span.start);
              if (from > span.start) target = target.splitText(from - span.start);
              const element = document.createElement('mark');
              element.className = 'stash-hl stash-' + mark.color;
              element.dataset.stash = mark.id;
              target.parentNode.insertBefore(element, target);
              element.appendChild(target);
            }
          }
        },
        unmarkAll: () => {
          document.querySelectorAll('mark.stash-hl').forEach((element) => {
            const parent = element.parentNode;
            while (element.firstChild) parent.insertBefore(element.firstChild, element);
            parent.removeChild(element);
          });
          if (document.body) document.body.normalize();
        },
        reveal: (id) => {
          const element = document.querySelector('mark[data-stash="' + id + '"]');
          if (element) element.scrollIntoView({ block: 'center' });
        },
        scrollTo: (fraction) => {
          setTimeout(() => {
            const height = document.documentElement.scrollHeight - window.innerHeight;
            window.scrollTo(0, Math.max(0, fraction * height));
          }, 60);
        },
      };
      window.stash = stash;

      let timer;
      window.addEventListener('scroll', () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const height = document.documentElement.scrollHeight - window.innerHeight;
          post({ type: 'position', value: height > 0 ? window.scrollY / height : 0 });
        }, 800);
      });
      document.addEventListener('click', (event) => {
        const element = event.target.closest && event.target.closest('mark.stash-hl');
        if (element) post({ type: 'tap', id: element.dataset.stash });
      });
    })();
    """#
}

/// Serves the book's files to its web view from inside the EPUB.
private final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var controller: EPUBController?

    init(controller: EPUBController) {
        self.controller = controller
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = String(url.path.dropFirst())
        MainActor.assumeIsolated {
            do {
                guard let controller else { throw URLError(.cancelled) }
                let data = try controller.file(at: path)
                let response = URLResponse(url: url, mimeType: EPUBDocument.mimeType(for: path),
                                           expectedContentLength: data.count, textEncodingName: nil)
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch {
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The content controller holds its handlers strongly; this keeps that
/// from keeping the reader alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

#if os(macOS)
struct EPUBWebView: NSViewRepresentable {
    let controller: EPUBController
    func makeNSView(context: Context) -> WKWebView { controller.webView ?? controller.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct EPUBWebView: UIViewRepresentable {
    let controller: EPUBController
    func makeUIView(context: Context) -> WKWebView { controller.webView ?? controller.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
