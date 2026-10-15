import SwiftUI
import PDFKit
import StashCore

/// Merge, split, make from pictures, and imprint: in item menus.
struct PDFToolMenu: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        let pdfs = items.filter(\.isPDF)
        let pictures = items.filter(Library.isPicture)
        let stampable = pdfs.filter(Library.canMarkUp)
        if !pdfs.isEmpty || !pictures.isEmpty {
            Menu("PDF") {
                if pdfs.count > 1 {
                    Button("Merge \(pdfs.count) PDFs") { library.mergePDFs(pdfs) }
                }
                if pdfs.count == 1 {
                    Button("Split…") { library.splittingPDF = pdfs[0] }
                }
                if !pictures.isEmpty {
                    Button(pictures.count == 1 ? "Make PDF from Picture" : "Make PDF from \(pictures.count) Pictures") {
                        library.makePDF(fromPictures: pictures)
                    }
                }
                if !stampable.isEmpty {
                    Button("Imprint…") { library.imprintingItems = stampable }
                        .help("Stamp a header, footer, page numbers or a watermark on every page")
                }
            }
        }
    }
}

/// The sheets the PDF tools ask with.
struct PDFToolSheets: ViewModifier {
    @Bindable var library: Library

    func body(content: Content) -> some View {
        content
            .sheet(item: $library.splittingPDF) { item in
                SplitPDFSheet(item: item)
            }
            .sheet(isPresented: Binding(get: { library.imprintingItems != nil }, set: { if !$0 { library.imprintingItems = nil } })) {
                ImprintSheet(items: library.imprintingItems ?? [])
            }
            .sheet(isPresented: $library.isManagingBackups) {
                AutoBackupView()
            }
            .sheet(isPresented: $library.isManagingMirror) {
                MirrorView()
            }
            .sheet(item: $library.croppingPicture) { item in
                CropSheet(item: item)
            }
            .sheet(isPresented: Binding(get: { library.resizingPictures != nil }, set: { if !$0 { library.resizingPictures = nil } })) {
                ResizeSheet(items: library.resizingPictures ?? [])
            }
    }
}

/// Into single pages, or ranges typed as `1-3, 5, 8-`.
struct SplitPDFSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var everyPage = true
    @State private var ranges = ""
    @State private var pageCount = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Split Into", selection: $everyPage) {
                        Text("Single Pages").tag(true)
                        Text("Page Ranges").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if !everyPage {
                        TextField("Pages", text: $ranges, prompt: Text("1-3, 5, 8-"))
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(summary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Split “\(item.displayTitle)”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") {
                        if let chosen { library.splitPDF(item, into: chosen) }
                        dismiss()
                    }
                    .disabled(chosen == nil)
                }
            }
        }
        .sheetSize(minWidth: 380, minHeight: 260)
        .onAppear {
            pageCount = library.localFile(for: item).flatMap(PDFDocument.init(url:))?.pageCount ?? 0
        }
    }

    private var chosen: [ClosedRange<Int>]? {
        if everyPage { return pageCount > 1 ? PageRanges.singlePages(pageCount) : nil }
        return PageRanges.parse(ranges, pageCount: pageCount)
    }

    private var summary: String {
        guard pageCount > 0 else { return "The PDF couldn’t be read." }
        guard let chosen else { return "It has \(pageCount) pages. Type pages and ranges between 1 and \(pageCount)." }
        return "Makes \(chosen.count) PDFs from its \(pageCount) pages, beside it and linked from it."
    }
}

/// DEVONthink's Imprinter: text on every page.
struct ImprintSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let items: [Item]
    @AppStorage("imprintText") private var text = "Page {page} of {pages}"
    @AppStorage("imprintPosition") private var position = Imprint.Position.bottomCenter.rawValue
    @AppStorage("imprintSize") private var fontSize = 10.0
    @AppStorage("imprintOpacity") private var opacity = 1.0
    @AppStorage("imprintColor") private var color = 0
    @AppStorage("imprintSkipsFirst") private var skipsFirstPage = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text", text: $text, axis: .vertical)
                } footer: {
                    Text("{page} and {pages} for page numbers, {title} for the document's title, {date} for today. For a watermark, put large text across the middle and make it see-through.")
                }
                Section {
                    Picker("Position", selection: $position) {
                        ForEach(Imprint.Position.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: 6...96, step: 2)
                    Picker("Color", selection: $color) {
                        Text("Black").tag(0)
                        ForEach(ItemLabel.allCases.filter { $0 != .none }) { Text($0.name).tag($0.rawValue) }
                    }
                    HStack {
                        Text("Opacity")
                        Slider(value: $opacity, in: 0.1...1)
                    }
                    Toggle("Leave the First Page Alone", isOn: $skipsFirstPage)
                } footer: {
                    Text(items.count == 1
                         ? "“\(items[0].displayTitle)” is changed; Revert to Original puts it back."
                         : "These \(items.count) PDFs are changed; Revert to Original puts each back.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Imprint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Imprint") {
                        library.imprint(items, with: Imprint(
                            text: text, position: Imprint.Position(rawValue: position) ?? .bottomCenter,
                            fontSize: fontSize, opacity: opacity, color: color, skipsFirstPage: skipsFirstPage))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .sheetSize(minWidth: 420, minHeight: 460)
    }
}
