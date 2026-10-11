import Foundation
import WebKit
import StashCore

/// Highlighting text in a web view -- a book's chapter, a saved article.
/// A highlight is found by its words (`TextQuote`), so it survives the text
/// being laid out differently; the page script does the marking.
@MainActor
enum WebHighlights {
    struct Selection {
        var quote: TextQuote
        /// The words, trimmed.
        var words: String
        /// How far through the page's text it starts, 0 to 1.
        var fraction: Double
    }

    /// Marks `highlights` in the page, replacing any marked before.
    static func show(_ highlights: [(Highlight, TextQuote)], in webView: WKWebView) async {
        guard let text = try? await webView.evaluateJavaScript("stash.text()") as? String else { return }
        var marks: [[String: Any]] = []
        for (highlight, quote) in highlights {
            guard let range = quote.locate(in: text) else { continue }
            marks.append(["id": highlight.uuid.uuidString, "start": range.lowerBound, "end": range.upperBound,
                          "color": highlight.colorRaw])
        }
        let json = (try? JSONSerialization.data(withJSONObject: marks)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        _ = try? await webView.evaluateJavaScript("stash.unmarkAll(); stash.mark(\(json));")
    }

    /// The selected text, as a quote; nil when nothing is selected. The
    /// selection is cleared, as it's about to become a highlight.
    static func selection(in webView: WKWebView) async -> Selection? {
        guard let found = try? await webView.evaluateJavaScript("stash.selection()") as? [String: Any],
              let start = (found["start"] as? NSNumber)?.intValue, let end = (found["end"] as? NSNumber)?.intValue,
              let text = found["text"] as? String,
              let quote = TextQuote(in: text, start: start, end: end) else { return nil }
        let words = quote.exact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        _ = try? await webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        return Selection(quote: quote, words: words, fraction: Double(start) / Double(max(text.utf16.count, 1)))
    }

    static func reveal(_ id: UUID, in webView: WKWebView) {
        webView.evaluateJavaScript("stash.reveal('\(id.uuidString)')")
    }

    /// Defines `window.stash`: the page's text, the selection, marking and
    /// unmarking highlights, scrolling to one, and reporting taps on them
    /// (`{type: 'tap', id}` to the "stash" message handler). Offsets count
    /// UTF-16 units through the body's text nodes, as `TextQuote` does.
    static let script = #"""
    (function () {
      const style = document.createElement('style');
      style.textContent = `
        mark.stash-hl { color: inherit; border-radius: 2px; cursor: pointer; }
        mark.stash-yellow { background: rgba(255, 214, 10, .45); }
        mark.stash-green { background: rgba(52, 199, 89, .35); }
        mark.stash-blue { background: rgba(10, 132, 255, .3); }
        mark.stash-pink { background: rgba(255, 55, 95, .3); }
        mark.stash-purple { background: rgba(191, 90, 242, .3); }`;
      (document.head || document.documentElement).appendChild(style);

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
      };
      window.stash = stash;

      document.addEventListener('click', (event) => {
        const element = event.target.closest && event.target.closest('mark.stash-hl');
        if (element) window.webkit.messageHandlers.stash.postMessage({ type: 'tap', id: element.dataset.stash });
      });
    })();
    """#
}
