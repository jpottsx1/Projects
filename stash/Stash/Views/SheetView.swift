import SwiftUI
import UniformTypeIdentifiers
import StashCore

extension Library {
    /// A CSV or TSV document, shown as a table to edit.
    static func isSheet(_ item: Item) -> Bool {
        guard item.kind == .document, let type = item.contentType else { return false }
        return type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText)
    }

    /// Whether its file can be written: not sealed, not in an indexed folder.
    static func canEditFile(_ item: Item) -> Bool {
        item.kind == .document && item.storedFilePath != nil && item.indexedFolder == nil && !item.isSealed
    }

    @discardableResult
    func newSheet() -> Item? {
        var category: ItemCategory?
        if case .category(let shown) = sidebar { category = shown }
        guard let item = addDocument(data: Data(Sheet.blank().text.utf8), named: "Untitled Sheet.csv", in: category) else { return nil }
        save()
        runSearch()
        selection = item
        return item
    }

    func saveSheet(_ sheet: Sheet, of item: Item) {
        guard Self.canEditFile(item), let path = item.storedFilePath else { return }
        do {
            try files.write(Data(sheet.text.utf8), to: path)
            Task { await fileDidChange(item) }
        } catch {
            importError = "“\(item.displayTitle)” couldn’t be saved: \(error.localizedDescription)"
        }
    }
}

/// DEVONthink's sheets: a CSV or TSV file as a table. Click a heading's
/// menu to sort by it or add and delete columns; a row's number for rows.
struct SheetView: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    @State private var sheet = Sheet(rows: [[""]])
    @State private var loaded = false
    @State private var pendingSave: Task<Void, Never>?

    private static let columnWidth: CGFloat = 150
    private static let numberWidth: CGFloat = 44
    private static let shownRows = 5000

    var body: some View {
        let editable = Library.canEditFile(item)
        VStack(spacing: 0) {
            HStack {
                Text("\(max(sheet.rows.count - 1, 0)) rows, \(sheet.columnCount) columns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if editable {
                    Button { change { $0.insertRow() } } label: { Label("Add Row", systemImage: "plus") }
                    Button { change { $0.insertColumn(heading: "Column \($0.columnCount + 1)") } } label: {
                        Label("Add Column", systemImage: "rectangle.split.3x1")
                    }
                } else {
                    Text("Read only").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(1..<min(sheet.rows.count, Self.shownRows + 1), id: \.self) { row in
                            rowView(row, editable: editable)
                        }
                    } header: {
                        headerRow(editable: editable)
                    }
                }
            }
        }
        .task(id: url) {
            guard !loaded else { return }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            let separator: Character = item.contentType?.conforms(to: .tabSeparatedText) == true ? "\t" : ","
            sheet = Sheet(text: text, separator: separator)
            loaded = true
        }
        .onDisappear {
            // Anything still waiting is saved now.
            if pendingSave != nil {
                pendingSave?.cancel()
                library.saveSheet(sheet, of: item)
            }
        }
    }

    private func headerRow(editable: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.numberWidth, height: 1)
            ForEach(0..<sheet.columnCount, id: \.self) { column in
                HStack(spacing: 2) {
                    cell(row: 0, column: column, editable: editable)
                        .font(.headline)
                    Menu {
                        Button("Sort A to Z (or Smallest First)") { change { $0.sort(byColumn: column, ascending: true) } }
                        Button("Sort Z to A (or Largest First)") { change { $0.sort(byColumn: column, ascending: false) } }
                        if editable {
                            Divider()
                            Button("Add Column After") { change { $0.insertColumn(after: column) } }
                            Button("Delete Column", role: .destructive) { change { $0.deleteColumn(column) } }
                                .disabled(sheet.columnCount < 2)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
                .frame(width: Self.columnWidth)
            }
        }
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func rowView(_ row: Int, editable: Bool) -> some View {
        HStack(spacing: 0) {
            Text("\(row)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.numberWidth)
                .contextMenu {
                    if editable {
                        Button("Add Row Below") { change { $0.insertRow(after: row) } }
                        Button("Delete Row", role: .destructive) { change { $0.deleteRow(row) } }
                    }
                }
            ForEach(0..<sheet.columnCount, id: \.self) { column in
                cell(row: row, column: column, editable: editable)
                    .frame(width: Self.columnWidth)
            }
        }
        .padding(.vertical, 2)
        .background(row.isMultiple(of: 2) ? Color.secondary.opacity(0.06) : .clear)
    }

    @ViewBuilder
    private func cell(row: Int, column: Int, editable: Bool) -> some View {
        let value = sheet.rows.indices.contains(row) && sheet.rows[row].indices.contains(column) ? sheet.rows[row][column] : ""
        if editable {
            TextField("", text: Binding(get: { value }, set: { new in change { $0.set(new, row: row, column: column) } }))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .padding(.horizontal, 6)
        } else {
            Text(value)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// Changes the table, and saves it a moment after the changes stop.
    private func change(_ edit: (inout Sheet) -> Void) {
        edit(&sheet)
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            library.saveSheet(sheet, of: item)
            pendingSave = nil
        }
    }
}
