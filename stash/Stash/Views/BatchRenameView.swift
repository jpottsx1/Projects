import SwiftUI
import StashCore

/// Renaming several items at once, with the new titles shown before
/// anything changes.
struct BatchRenameView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let items: [Item]

    private enum Kind: String, CaseIterable, Identifiable {
        case replace, add, pattern
        var id: String { rawValue }
        var name: String {
            switch self {
            case .replace: "Find and Replace"
            case .add: "Add Text"
            case .pattern: "New Titles"
            }
        }
    }

    @State private var kind: Kind = .replace
    @State private var find = ""
    @State private var replace = ""
    @State private var ignoringCase = true
    @State private var regex = false
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var pattern = "{title} {n}"
    @State private var start = 1
    @State private var digits = 1

    private var mode: BatchRename.Mode {
        switch kind {
        case .replace: .replace(find: find, replace: replace, ignoringCase: ignoringCase, regex: regex)
        case .add: .add(prefix: prefix, suffix: suffix)
        case .pattern: .pattern(pattern, start: start, digits: digits)
        }
    }

    var body: some View {
        let live = items.filter { !$0.isTrashed }
        let preview = BatchRename.titles(for: live.map(Library.renameSource), mode: mode)
        NavigationStack {
            Form {
                Picker("Rename", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                switch kind {
                case .replace:
                    TextField("Find", text: $find)
                        .accessibilityIdentifier("renameFind")
                    TextField("Replace with", text: $replace)
                        .accessibilityIdentifier("renameReplace")
                    Toggle("Ignore Case", isOn: $ignoringCase)
                    Toggle("Regular Expression", isOn: $regex)
                        .help("$1, $2… in the replacement put back what the brackets matched")
                case .add:
                    TextField("Before", text: $prefix)
                    TextField("After", text: $suffix)
                case .pattern:
                    TextField("Pattern", text: $pattern)
                        .accessibilityIdentifier("renamePattern")
                    Text("{title} the old title · {n} a number · {date} when it was made, or {date:d MMM yyyy} · {kind}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper("Numbers start at \(start)", value: $start, in: 0...100_000)
                    Stepper("At least \(digits) digit\(digits == 1 ? "" : "s")", value: $digits, in: 1...6)
                }
                Section("Preview") {
                    ForEach(Array(zip(live, preview).prefix(8).enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.1)
                                .foregroundStyle(pair.1 == pair.0.displayTitle ? .secondary : .primary)
                            if pair.1 != pair.0.displayTitle {
                                Text(pair.0.displayTitle)
                                    .font(.caption)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if live.count > 8 {
                        Text("and \(live.count - 8) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(live.count == 1 ? "Rename Item" : "Rename \(live.count) Items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        library.rename(live, mode: mode)
                        dismiss()
                    }
                    .disabled(zip(live, preview).allSatisfy { $0.displayTitle == $1 })
                    .accessibilityIdentifier("renameConfirm")
                }
            }
        }
        .sheetSize(minWidth: 480, minHeight: 460)
    }
}

/// Rename and Convert To, for items' menus.
struct BatchMenus: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        let live = items.filter { !$0.isTrashed }
        Button(live.count > 1 ? "Rename Items…" : "Rename…") { library.renamingItems = live }
            .disabled(live.isEmpty)
        Button("Move to Category…") { library.quickOpen = .file(live) }
            .disabled(live.isEmpty)
        Button("Duplicate") { library.duplicate(live) }
            .disabled(!live.contains { !$0.isLocked })
        let convertible = live.filter(Library.canConvert)
        if !convertible.isEmpty {
            Menu("Convert To") {
                ForEach(ConversionFormat.allCases) { format in
                    Button("\(format.name) Document") {
                        Task { await library.convert(convertible, to: format) }
                    }
                }
            }
        }
        PDFToolMenu(items: live)
        let notable = live.filter(Library.canMakeNote(from:))
        if !notable.isEmpty {
            Button(notable.count > 1 ? "Make Notes" : "Make a Note") { library.makeNotes(from: notable) }
                .help("A note with the text of the page, email or document, linked to it")
        }
    }
}
