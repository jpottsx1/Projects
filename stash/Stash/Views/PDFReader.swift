import PDFKit
import SwiftUI
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A PDF, with highlights: select some text, then Highlight. Highlights
/// are drawn over the page, not saved into the file.
struct PDFReader: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    @State private var controller = PDFController()

    var body: some View {
        let highlights = item.sortedHighlights
        PDFKitView(url: url, controller: controller)
            .onAppear { controller.onTap = { id in open(id) } }
            .onChange(of: Self.signature(highlights), initial: true) {
                controller.show(highlights)
            }
            .onChange(of: library.revealedHighlight) { _, highlight in
                guard let highlight, highlight.item == item else { return }
                controller.reveal(highlight)
                library.revealedHighlight = nil
            }
            .toolbar {
                ToolbarItem {
                    HighlightMenu { color, withNote in highlightSelection(color, withNote: withNote) }
                }
            }
    }

    private func highlightSelection(_ color: HighlightColor, withNote: Bool) {
        guard let selected = controller.selectedPassage() else { return }
        let highlight = library.addHighlight(to: item, text: selected.text, anchor: selected.anchor,
                                             position: selected.position, color: color)
        controller.clearSelection()
        if withNote { library.editingHighlight = highlight }
    }

    private func open(_ id: UUID) {
        library.editingHighlight = item.highlights?.first { $0.uuid == id }
    }

    /// Changes whenever a highlight is added, removed or recoloured.
    static func signature(_ highlights: [Highlight]) -> String {
        highlights.map { $0.uuid.uuidString + $0.colorRaw }.joined(separator: ",")
    }
}

/// Highlight in yellow, or choose a colour, or highlight and write a note.
struct HighlightMenu: View {
    let action: (HighlightColor, Bool) -> Void

    var body: some View {
        Menu {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button {
                    action(color, false)
                } label: {
                    Label(color.name, systemImage: "circle.fill")
                }
                .tint(color.swatch)
            }
            Divider()
            Button {
                action(.yellow, true)
            } label: {
                Label("Highlight and Add Note", systemImage: "note.text.badge.plus")
            }
        } label: {
            Label("Highlight", systemImage: "highlighter")
        } primaryAction: {
            action(.yellow, false)
        }
        .help("Highlight the selected text")
        .accessibilityIdentifier("highlightButton")
    }
}

extension HighlightColor {
    var swatch: Color {
        switch self {
        case .yellow: Color(red: 1, green: 0.84, blue: 0.04)
        case .green: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .blue: Color(red: 0.04, green: 0.52, blue: 1)
        case .pink: Color(red: 1, green: 0.22, blue: 0.37)
        case .purple: Color(red: 0.75, green: 0.35, blue: 0.95)
        }
    }
}

/// Talks to the PDFView: reads the selection, draws highlights, scrolls to one.
@MainActor
final class PDFController: NSObject {
    weak var view: PDFView?
    var onTap: (UUID) -> Void = { _ in }
    private var drawn: [PDFAnnotation] = []
    private var waiting: [Highlight]?
    private static let prefix = "stash:"

    struct Passage {
        var text: String
        var anchor: HighlightAnchor
        var position: Double
    }

    func attach(_ view: PDFView) {
        self.view = view
        NotificationCenter.default.addObserver(self, selector: #selector(annotationHit(_:)),
                                               name: .PDFViewAnnotationHit, object: view)
        if let waiting { show(waiting) }
    }

    func documentChanged() {
        drawn = []
        if let waiting { show(waiting) }
    }

    @objc private func annotationHit(_ notification: Notification) {
        guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
              let name = annotation.userName, name.hasPrefix(Self.prefix),
              let id = UUID(uuidString: String(name.dropFirst(Self.prefix.count))) else { return }
        onTap(id)
    }

    /// The selected text and where it is, line by line.
    func selectedPassage() -> Passage? {
        guard let view, let document = view.document, let selection = view.currentSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var pages: [HighlightAnchor.PDFPageRects] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let index = document.index(for: page)
                let rect = HighlightAnchor.Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
                if let last = pages.indices.last, pages[last].page == index {
                    pages[last].rects.append(rect)
                } else {
                    pages.append(.init(page: index, rects: [rect]))
                }
            }
        }
        guard let first = pages.first, let rect = first.rects.first,
              let page = document.page(at: first.page) else { return nil }
        let height = max(page.bounds(for: .mediaBox).height, 1)
        // Further down the page is later; PDF y counts up from the bottom.
        let position = Double(first.page) + (1 - min(max(rect.y + rect.height, 0), height) / height)
        return Passage(text: text, anchor: .pdf(pages), position: position)
    }

    func clearSelection() {
        view?.clearSelection()
    }

    func show(_ highlights: [Highlight]) {
        waiting = highlights
        guard let document = view?.document else { return }
        for annotation in drawn { annotation.page?.removeAnnotation(annotation) }
        drawn = []
        for highlight in highlights {
            guard case .pdf(let pages)? = highlight.anchor else { continue }
            for part in pages {
                guard let page = document.page(at: part.page) else { continue }
                for rect in part.rects {
                    let annotation = PDFAnnotation(bounds: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                                                   forType: .highlight, withProperties: nil)
                    annotation.color = highlight.color.platformColor
                    annotation.userName = Self.prefix + highlight.uuid.uuidString
                    if !highlight.note.isEmpty { annotation.contents = highlight.note }
                    page.addAnnotation(annotation)
                    drawn.append(annotation)
                }
            }
        }
    }

    func reveal(_ highlight: Highlight) {
        guard let view, let document = view.document, case .pdf(let pages)? = highlight.anchor,
              let first = pages.first, let page = document.page(at: first.page) else { return }
        if let rect = first.rects.first {
            let target = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).insetBy(dx: 0, dy: -80)
            view.go(to: target, on: page)
        } else {
            view.go(to: page)
        }
    }
}

extension HighlightColor {
    #if os(macOS)
    var platformColor: NSColor { NSColor(swatch).withAlphaComponent(0.45) }
    #else
    var platformColor: UIColor { UIColor(swatch).withAlphaComponent(0.45) }
    #endif
}

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let controller: PDFController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            controller.documentChanged()
        }
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let url: URL
    let controller: PDFController

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        controller.attach(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            controller.documentChanged()
        }
    }
}
#endif
