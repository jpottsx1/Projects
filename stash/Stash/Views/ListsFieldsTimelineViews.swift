import SwiftData
import SwiftUI
import StashCore

// MARK: - Lists

/// The Lists part of the sidebar.
struct ListsSection: View {
    @Environment(Library.self) private var library
    @Query(sort: \ItemList.name) private var lists: [ItemList]
    @State private var renaming: ItemList?
    @State private var isNaming = false
    @State private var nameDraft = ""

    var body: some View {
        Section("Lists") {
            ForEach(lists) { list in
                Label(list.name, systemImage: "list.bullet.rectangle")
                    .badge((list.items ?? []).filter { !$0.isTrashed }.count)
                    .tag(SidebarSelection.list(list))
                    .contextMenu {
                        Button("Rename…") {
                            nameDraft = list.name
                            renaming = list
                        }
                        Button("Export…") {
                            library.exportRequest = .items(list.orderedItems.filter { !$0.isTrashed }, name: list.name)
                        }
                        Divider()
                        Button("Delete List", role: .destructive) { library.delete(list) }
                    }
            }
            // The alerts hang off this button: a sidebar section can't show one.
            Button {
                nameDraft = ""
                isNaming = true
            } label: {
                Label("New List", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .alert("New List", isPresented: $isNaming) {
                TextField("Name", text: $nameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Make") {
                    if let list = library.newList(named: nameDraft) { library.sidebar = .list(list) }
                }
            }
            .alert("Rename List", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $nameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let renaming { library.rename(renaming, to: nameDraft) } }
            }
        }
    }
}

/// Add to List, Remove from List and Read Later, for items' menus.
struct ListMenus: View {
    @Environment(Library.self) private var library
    @Query(sort: \ItemList.name) private var lists: [ItemList]
    let items: [Item]

    var body: some View {
        let queued = !items.isEmpty && items.allSatisfy { $0.readLaterAt != nil }
        Button(queued ? "Remove from Read Later" : "Read Later") { library.setReadLater(items, !queued) }
        Menu("Add to List") {
            ForEach(lists) { list in
                Button(list.name) { library.add(items, to: list) }
                    .disabled(items.allSatisfy { ($0.lists ?? []).contains(list) })
            }
            if !lists.isEmpty { Divider() }
            Button("New List…") { library.newListItems = items }
        }
        if case .list(let list) = library.sidebar {
            Button("Remove from “\(list.name)”") { library.remove(items, from: list) }
        }
    }
}

/// Asked for a new list's name from a menu, which can't show an alert itself.
struct NewListPrompt: ViewModifier {
    @Environment(Library.self) private var library
    @State private var nameDraft = ""

    func body(content: Content) -> some View {
        content.alert("New List", isPresented: Binding(get: { library.newListItems != nil },
                                                       set: { if !$0 { library.newListItems = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { nameDraft = "" }
            Button("Make") {
                library.newList(named: nameDraft, adding: library.newListItems ?? [])
                nameDraft = ""
            }
        } message: {
            Text("The \(library.newListItems?.count == 1 ? "item goes" : "items go") in it.")
        }
    }
}

// MARK: - Fields

/// Your own fields, in the side panel: a control for each.
struct FieldsSection: View {
    @Environment(Library.self) private var library
    @Query(sort: \FieldDefinition.order) private var fields: [FieldDefinition]
    let item: Item
    @State private var isEditing = false

    var body: some View {
        Section {
            if fields.isEmpty {
                Text("Add fields of your own: a price, a due date, a status.")
                    .foregroundStyle(.secondary)
            }
            ForEach(fields) { field in
                FieldEditor(field: field, items: [item])
            }
            Button("Edit Fields…") { isEditing = true }
                .buttonStyle(.borderless)
        } header: {
            Text("Fields")
        }
        .sheet(isPresented: $isEditing) { FieldDefinitionsView() }
    }
}

/// One field's value, edited in the way its kind needs.
struct FieldEditor: View {
    @Environment(Library.self) private var library
    let field: FieldDefinition
    let items: [Item]
    @State private var draft = ""

    private var stored: String { items.first.map { library.value(of: field, for: $0) } ?? "" }

    var body: some View {
        switch field.kind {
        case .text, .number:
            LabeledContent(field.name) {
                TextField(field.kind == .number ? "Number" : "Text", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                    .onAppear { draft = stored }
                    .onChange(of: stored) { draft = stored }
                    .onDisappear(perform: commit)
                    .accessibilityIdentifier("field-\(field.name)")
                    #if os(iOS)
                    .keyboardType(field.kind == .number ? .decimalPad : .default)
                    #endif
            }
        case .date:
            let date = CustomField.date(from: stored)
            LabeledContent(field.name) {
                if let date {
                    DatePicker("", selection: Binding(get: { date }, set: { set(CustomField.storedDate($0)) }),
                               displayedComponents: .date)
                        .labelsHidden()
                    Button {
                        set("")
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Set Date") { set(CustomField.storedDate(.now)) }
                        .buttonStyle(.borderless)
                }
            }
        case .yesNo:
            Toggle(field.name, isOn: Binding(get: { stored == "true" }, set: { set($0 ? "true" : "false") }))
        case .choice:
            Picker(field.name, selection: Binding(get: { stored }, set: { set($0) })) {
                Text("None").tag("")
                ForEach(field.choiceList, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private func commit() {
        guard draft != stored else { return }
        set(draft.trimmingCharacters(in: .whitespaces))
    }

    private func set(_ value: String) {
        library.setValue(value, of: field, for: items)
    }
}

/// Adding, naming, ordering and deleting fields.
struct FieldDefinitionsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FieldDefinition.order) private var fields: [FieldDefinition]
    @State private var newName = ""
    @State private var newKind: CustomField.Kind = .text
    @State private var deleting: FieldDefinition?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields) { field in
                        FieldDefinitionRow(field: field) { deleting = field }
                    }
                    .onMove { library.moveFields(from: $0, to: $1) }
                } footer: {
                    Text("Search a field by its name: Price:>20, Due:2026-11, Done:yes. Write a space in a name as _.")
                }
                Section("New Field") {
                    TextField("Name", text: $newName)
                        .accessibilityIdentifier("newFieldName")
                    Picker("Kind", selection: $newKind) {
                        ForEach(CustomField.Kind.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .accessibilityIdentifier("newFieldKind")
                    Button("Add Field") {
                        library.newField(named: newName, kind: newKind)
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Fields")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetSize(minWidth: 440, minHeight: 420)
        .confirmationDialog("Delete the field “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Field", role: .destructive) { if let deleting { library.delete(deleting) } }
        } message: {
            Text("Its value is taken off every item.")
        }
    }
}

private struct FieldDefinitionRow: View {
    @Environment(Library.self) private var library
    @Bindable var field: FieldDefinition
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $field.name)
                    .onSubmit { library.save() }
                Text(field.kind.name)
                    .foregroundStyle(.secondary)
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            if field.kind == .choice {
                TextField("Choices, separated by commas", text: Binding(
                    get: { field.choiceList.joined(separator: ", ") },
                    set: { field.choiceList = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                    .font(.callout)
            }
        }
    }
}

// MARK: - Timeline

/// What was added or changed each day: a month's calendar, with a dot for
/// each busy day, and the chosen day's items below.
struct LibraryTimeline: View {
    @Environment(Library.self) private var library
    let items: [Item]
    @State private var month = Date.now
    @State private var day = Calendar.current.startOfDay(for: .now)
    @AppStorage("timelineShowsChanges") private var showsChanges = false

    private var calendar: Calendar { .current }

    private func date(of item: Item) -> Date { showsChanges ? item.modifiedAt : item.createdAt }

    var body: some View {
        let live = items.filter { !$0.isTrashed && !$0.isTemplate }
        let counts = CalendarMonth.counts(of: live.map(date(of:)), calendar: calendar)
        let chosen = live.filter { calendar.isDate(date(of: $0), inSameDayAs: day) }
            .sorted { date(of: $0) > date(of: $1) }
        VStack(spacing: 0) {
            header
            monthGrid(counts: counts)
                .padding(.horizontal)
            Divider().padding(.top, 8)
            List(selection: Binding(get: { library.listSelection }, set: { library.select($0) })) {
                Section(day.formatted(date: .complete, time: .omitted)) {
                    if chosen.isEmpty {
                        Text(showsChanges ? "Nothing changed this day." : "Nothing added this day.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(chosen) { item in
                        ItemRow(item: item).tag(item)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Label("Previous Month", systemImage: "chevron.left")
            }
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .frame(minWidth: 140)
            Button {
                shiftMonth(1)
            } label: {
                Label("Next Month", systemImage: "chevron.right")
            }
            Spacer()
            Button("Today") {
                month = .now
                day = calendar.startOfDay(for: .now)
            }
            Picker("Show", selection: $showsChanges) {
                Text("Added").tag(false)
                Text("Changed").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding()
    }

    private func monthGrid(counts: [Date: Int]) -> some View {
        let weeks = CalendarMonth.weeks(of: month, calendar: calendar)
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(CalendarMonth.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                GridRow {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date, count: counts[calendar.startOfDay(for: date)] ?? 0)
                        } else {
                            Color.clear.frame(height: 34)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date, count: Int) -> some View {
        let isChosen = calendar.isDate(date, inSameDayAs: day)
        let isToday = calendar.isDateInToday(date)
        return Button {
            day = calendar.startOfDay(for: date)
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isChosen ? Color.white : isToday ? Color.accentColor : Color.primary)
                Circle()
                    .fill(count > 0 ? (isChosen ? Color.white : Color.accentColor) : .clear)
                    .frame(width: count > 4 ? 7 : 5, height: count > 4 ? 7 : 5)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isChosen ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(date.formatted(date: .long, time: .omitted)), \(count) items")
    }

    private func shiftMonth(_ by: Int) {
        month = calendar.date(byAdding: .month, value: by, to: month) ?? month
    }
}

// MARK: - In the side panel

/// The lists an item's in, and the reading queue.
struct ListsAndReadingSection: View {
    @Environment(Library.self) private var library
    @Query(sort: \ItemList.name) private var lists: [ItemList]
    let item: Item

    var body: some View {
        Section {
            let mine = (item.lists ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !mine.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(mine) { list in
                        HStack(spacing: 3) {
                            Text(list.name)
                            Button {
                                library.remove([item], from: list)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            Menu("Add to List") {
                ForEach(lists) { list in
                    Button(list.name) { library.add([item], to: list) }
                        .disabled((item.lists ?? []).contains(list))
                }
                if lists.isEmpty { Text("Make lists in the sidebar.") }
            }
            .menuStyle(.borderlessButton)
            Toggle("Read Later", isOn: Binding(get: { item.readLaterAt != nil }, set: { library.setReadLater([item], $0) }))
            if item.readingProgress > 0 {
                LabeledContent("Read") {
                    ProgressView(value: item.readingProgress).frame(maxWidth: 120)
                }
            }
        } header: {
            Text("Lists & Reading")
        }
    }
}
