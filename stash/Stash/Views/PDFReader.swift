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
    @AppStorage("showsPDFPages") private var showsPages = false
    /// The colour "Custom Color" highlights in, as #RRGGBB.
    @AppStorage("customHighlightColor") private var customColor = "#FF6B9A"

    var body: some View {
        let highlights = item.sortedHighlights
        HStack(spacing: 0) {
            if showsPages {
                PDFPagesPanel(item: item, url: url, controller: controller)
                    .frame(width: 190)
                Divider()
            }
            pdf(highlights)
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showsPages) {
                    Label("Pages", systemImage: "sidebar.left")
                }
                .help("Page thumbnails and the outline")
            }
            ToolbarItem {
                ColorPicker("Custom Highlight Color", selection: Binding(
                    get: { Color(hex: customColor) ?? .pink },
                    set: { customColor = $0.hex ?? customColor }), supportsOpacity: false)
                    .labelsHidden()
                    .help("The colour for Custom Color highlights")
            }
        }
        .onAppear {
            // Opened from a search: the first place it matches.
            if let term = library.search.query.terms.first?.text, !term.isEmpty { controller.reveal(firstMatchOf: term) }
        }
    }

    private func pdf(_ highlights: [Highlight]) -> some View {
        PDFKitView(url: url, controller: controller)
            .onAppear {
                controller.onTap = { id in open(id) }
                controller.onPageChanged = { page, count in
                    library.setReadingProgress(item, Double(page + 1) / Double(max(count, 1)), position: "pdf|\(page)")
                }
                if item.readingPosition.hasPrefix("pdf|"), let page = Int(item.readingPosition.dropFirst(4)) {
                    controller.open(atPage: page)
                }
            }
            .onChange(of: Self.signature(highlights), initial: true) {
                controller.show(highlights)
            }
            .onChange(of: library.revealedHighlight) { _, highlight in
                guard let highlight, highlight.item == item else { return }
                controller.reveal(highlight)
                library.revealedHighlight = nil
            }
            .onChange(of: library.revealedPage) { _, request in
                guard let request, request.itemID == item.uuid else { return }
                controller.go(toPage: request.page)
                library.revealedPage = nil
            }
            .toolbar {
                ToolbarItem {
                    HighlightMenu(action: { color, withNote in highlightSelection(color, withNote: withNote) },
                                  custom: { highlightSelection(.pink, withNote: false, custom: customColor) })
                }
            }
    }

    private func highlightSelection(_ color: HighlightColor, withNote: Bool, custom: String? = nil) {
        guard let selected = controller.selectedPassage() else { return }
        let highlight = library.addHighlight(to: item, text: selected.text, anchor: selected.anchor,
                                             position: selected.position, color: color)
        if let custom {
            highlight.customColor = custom
            library.save()
        }
        controller.clearSelection()
        if withNote { library.editingHighlight = highlight }
    }

    private func open(_ id: UUID) {
        library.editingHighlight = item.highlights?.first { $0.uuid == id }
    }

    /// Changes whenever a highlight is added, removed or recoloured.
    static func signature(_ highlights: [Highlight]) -> String {
        highlights.map { $0.uuid.uuidString + $0.colorRaw + $0.customColor }.joined(separator: ",")
    }
}

/// Highlight in yellow, or choose a colour, or highlight and write a note.
struct HighlightMenu: View {
    let action: (HighlightColor, Bool) -> Void
    /// Highlighting in the colour of your own, where there's one (PDFs).
    var custom: (() -> Void)?

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
            if let custom {
                Button(action: custom) {
                    Label("Custom Color", systemImage: "paintpalette")
                }
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
    /// The page showing (from 0), and how many there are.
    var onPageChanged: (Int, Int) -> Void = { _, _ in }
    /// Where to open, once the document's in.
    private var startPage: Int?
    /// When the view was set up: page changes just after are its own
    /// settling in, not reading, and mustn't overwrite where you'd got to.
    private var attachedAt = Date.distantPast
    private var drawn: [PDFAnnotation] = []
    private var waiting: [Highlight]?
    private static let prefix = "stash:"

    struct Passage {
        var text: String
        var anchor: HighlightAnchor
        var position: Double
    }

    /// Shows a page (from 0).
    func go(toPage index: Int) {
        guard let view, let page = view.document?.page(at: index) else { return }
        view.go(to: page)
    }

    /// Shows and selects the first place the text is found.
    func reveal(firstMatchOf text: String) {
        pendingMatch = text
        revealPendingMatch()
    }

    private var pendingMatch: String?

    private func revealPendingMatch() {
        guard let text = pendingMatch, let view, let document = view.document else { return }
        pendingMatch = nil
        guard let found = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]).first else { return }
        DispatchQueue.main.async {
            view.go(to: found)
            view.setCurrentSelection(found, animate: true)
        }
    }

    func attach(_ view: PDFView) {
        self.view = view
        attachedAt = .now
        NotificationCenter.default.addObserver(self, selector: #selector(annotationHit(_:)),
                                               name: .PDFViewAnnotationHit, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        if let waiting { show(waiting) }
        goToStartPage()
        revealPendingMatch()
    }

    /// Opens at a page (from 0): where reading stopped last time.
    func open(atPage page: Int) {
        startPage = page
        goToStartPage()
    }

    private func goToStartPage() {
        guard let page = startPage, let view, let document = view.document,
              page > 0, page < document.pageCount, let target = document.page(at: page) else { return }
        startPage = nil
        // Once it's laid out, or the go is lost.
        DispatchQueue.main.async { view.go(to: target) }
    }

    @objc private func pageChanged(_ notification: Notification) {
        guard startPage == nil, Date.now.timeIntervalSince(attachedAt) > 1,
              let view, let document = view.document, let page = view.currentPage else { return }
        onPageChanged(document.index(for: page), document.pageCount)
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
                    annotation.color = highlight.platformColor
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

extension Highlight {
    /// Its colour: the one of your own, if it has one.
    var displayColor: Color { Color(hex: customColor) ?? color.swatch }

    #if os(macOS)
    var platformColor: NSColor { NSColor(displayColor).withAlphaComponent(0.45) }
    #else
    var platformColor: UIColor { UIColor(displayColor).withAlphaComponent(0.45) }
    #endif
}

extension Color {
    /// From "#RRGGBB"; nil for anything else.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// As "#RRGGBB".
    var hex: String? {
        let resolved = resolve(in: EnvironmentValues())
        func byte(_ component: Float) -> Int { Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
    }
}

/// A PDF's pages as thumbnails, to go to and (when the file is Stash's
/// own) drag into another order or delete; or its outline.
struct PDFPagesPanel: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    let controller: PDFController
    @State private var showsOutline = false
    @State private var pages: [Int] = []
    @State private var thumbnails: [Int: PlatformImage] = [:]
    @State private var outline: [OutlineNode] = []
    @State private var deleting: Int?

    struct OutlineNode: Identifiable {
        let id = UUID()
        let title: String
        let page: Int?
        let children: [OutlineNode]?
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $showsOutline) {
                Text("Pages").tag(false)
                Text("Outline").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            if showsOutline {
                if outline.isEmpty {
                    ContentUnavailableView("No Outline", systemImage: "list.bullet.indent")
                } else {
                    List(outline, children: \.children) { node in
                        Button(node.title) { if let page = node.page { controller.go(toPage: page) } }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                List {
                    ForEach(Array(pages.enumerated()), id: \.element) { position, page in
                        Button {
                            controller.go(toPage: position)
                        } label: {
                            VStack(spacing: 4) {
                                if let image = thumbnails[page] {
                                    thumbnailImage(image)
                                } else {
                                    Rectangle().fill(.quaternary).frame(height: 160)
                                }
                                Text("\(position + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if Library.canEditPages(of: item) {
                                Button("Delete Page", role: .destructive) { deleting = position }
                            }
                        }
                    }
                    .onMove(perform: Library.canEditPages(of: item) ? { from, to in
                        var order = Array(pages.indices)
                        order.move(fromOffsets: from, toOffset: to)
                        library.arrangePages(of: item, order: order)
                    } : nil)
                }
            }
        }
        .task(id: library.fileRevision(of: item)) { load() }
        .confirmationDialog("Delete page \((deleting ?? 0) + 1)?", isPresented: Binding(get: { deleting != nil },
                                                                                       set: { if !$0 { deleting = nil } })) {
            Button("Delete Page", role: .destructive) {
                guard let deleting else { return }
                library.arrangePages(of: item, order: pages.indices.filter { $0 != deleting })
            }
        } message: {
            Text("Highlights on it go too. Revert to Original brings it back.")
        }
    }

    @ViewBuilder
    private func thumbnailImage(_ image: PlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160).shadow(radius: 1)
        #else
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160).shadow(radius: 1)
        #endif
    }

    private func load() {
        guard let document = PDFDocument(url: url) else { return }
        pages = Array(0..<document.pageCount)
        thumbnails = [:]
        for index in pages.prefix(500) {
            if let page = document.page(at: index) {
                thumbnails[index] = page.thumbnail(of: CGSize(width: 140, height: 180), for: .cropBox)
            }
        }
        func nodes(_ parent: PDFOutline) -> [OutlineNode] {
            (0..<parent.numberOfChildren).compactMap { index in
                guard let child = parent.child(at: index) else { return nil }
                let page = child.destination?.page.map { document.index(for: $0) }
                let children = nodes(child)
                return OutlineNode(title: child.label ?? "Untitled", page: page, children: children.isEmpty ? nil : children)
            }
        }
        outline = document.outlineRoot.map(nodes) ?? []
    }
}
