import SwiftUI
import SwiftData
import StashCore

/// The smart rules: what's done to items as they arrive.
struct RulesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SmartRule.createdAt) private var rules: [SmartRule]
    @State private var editing: SmartRule?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                if rules.isEmpty {
                    ContentUnavailableView {
                        Label("No Rules", systemImage: "wand.and.stars")
                    } description: {
                        Text("A rule files, tags, labels or rates items as they arrive, when they match a search: say, every PDF with “invoice” in it into Finance.")
                    }
                }
                ForEach(rules) { rule in
                    HStack {
                        Toggle(rule.name, isOn: Binding(get: { rule.isEnabled }, set: {
                            rule.isEnabled = $0
                            library.save()
                        }))
                        .labelsHidden()
                        Button {
                            editing = rule
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).foregroundStyle(.primary)
                                Text((rule.query.isEmpty ? "Every item" : rule.query) + " → " + rule.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button("Edit…") { editing = rule }
                        Button("Delete Rule", role: .destructive) { library.delete(rule) }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { library.delete(rules[index]) }
                }
            }
            .navigationTitle("Smart Rules")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { rule in
                RuleEditor(rule: rule)
            }
            .sheet(isPresented: $isCreating) {
                RuleEditor(rule: nil)
            }
        }
        .sheetSize(minWidth: 460, minHeight: 420)
    }
}

/// One rule: what it matches and what it does.
struct RuleEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]
    /// Nil for a new rule, which is only made when it's saved.
    @State private var rule: SmartRule?

    @State private var name: String
    @State private var query: String
    @State private var category: ItemCategory?
    @State private var tags: String
    @State private var labelRaw: Int
    @State private var rating: Int
    @State private var makesFavorite: Bool
    @State private var marksRead: Bool
    @State private var takesOutOfInbox: Bool
    @State private var isEnabled: Bool
    @State private var schedule: RuleSchedule
    @State private var runsAtLaunch: Bool
    @State private var appliedCount: Int?

    init(rule: SmartRule?) {
        _rule = State(initialValue: rule)
        _name = State(initialValue: rule?.name ?? "New Rule")
        _query = State(initialValue: rule?.query ?? "")
        _category = State(initialValue: rule?.category)
        _tags = State(initialValue: rule?.tagsToAdd ?? "")
        _labelRaw = State(initialValue: rule?.labelRaw ?? -1)
        _rating = State(initialValue: rule?.rating ?? -1)
        _makesFavorite = State(initialValue: rule?.makesFavorite ?? false)
        _marksRead = State(initialValue: rule?.marksRead ?? false)
        _takesOutOfInbox = State(initialValue: rule?.takesOutOfInbox ?? false)
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
        _schedule = State(initialValue: rule?.schedule ?? .never)
        _runsAtLaunch = State(initialValue: rule?.runsAtLaunch ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Toggle("On", isOn: $isEnabled)
                }
                Section {
                    TextField("Search", text: $query, prompt: Text("Every item"), axis: .vertical)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Text(matchDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("When an Item Arrives Matching")
                } footer: {
                    Text("Search as in the search field: words, \"phrases\", #tag, kind:pdf, in:Category, label:red… Leave empty for everything that arrives.")
                }
                Section("Then") {
                    Picker("File In", selection: $category) {
                        Text("Leave as It Is").tag(ItemCategory?.none)
                        ForEach(categories.filter { $0.parent == nil }.flatMap(\.flattened)) { category in
                            Text(category.path).tag(Optional(category))
                        }
                    }
                    TextField("Add Tags", text: $tags, prompt: Text("Add tags, separated by commas"))
                        .autocorrectionDisabled()
                    Picker("Label", selection: $labelRaw) {
                        Text("Leave as It Is").tag(-1)
                        ForEach(ItemLabel.allCases) { label in
                            Text(label.name).tag(label.rawValue)
                        }
                    }
                    Picker("Rating", selection: $rating) {
                        Text("Leave as It Is").tag(-1)
                        Text("Unrated").tag(0)
                        ForEach(1...5, id: \.self) { stars in
                            Text(String(repeating: "★", count: stars)).tag(stars)
                        }
                    }
                    Toggle("Add to Favorites", isOn: $makesFavorite)
                    Toggle("Mark as Read", isOn: $marksRead)
                    Toggle("Take Out of Inbox", isOn: $takesOutOfInbox)
                }
                Section {
                    Picker("Also Run", selection: $schedule) {
                        ForEach(RuleSchedule.allCases) { schedule in
                            Text(schedule.name).tag(schedule)
                        }
                    }
                    Toggle("Run When Stash Opens", isOn: $runsAtLaunch)
                    if let last = rule?.lastRunAt {
                        Text("Last run \(last.formatted(.relative(presentation: .named))).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On Everything Already Here")
                } footer: {
                    Text("Besides new arrivals, a rule can go over everything that matches: when Stash opens, or every hour, day or week while it's open, as DEVONthink's scheduled rules do.")
                }
                Section {
                    Button("Apply to Matching Items Now") {
                        appliedCount = library.apply(save(), toExisting: true)
                    }
                    if let appliedCount {
                        Text(appliedCount == 1 ? "Applied to 1 item." : "Applied to \(appliedCount) items.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Rules run on new arrivals by themselves. This runs it on what's already here too.")
                }
                if let rule {
                    Section {
                        Button("Delete Rule", role: .destructive) {
                            library.delete(rule)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? "New Rule" : "Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .sheetSize(minWidth: 440, minHeight: 560)
    }

    private var matchDescription: String {
        let count = library.find(query, limit: .max).count
        return count == 1 ? "1 item here matches now." : "\(count) items here match now."
    }

    /// Saves the rule, making it first if it's new.
    @discardableResult
    private func save() -> SmartRule {
        let rule = self.rule ?? library.newRule()
        self.rule = rule
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.name = trimmed.isEmpty ? "Rule" : trimmed
        rule.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.category = category
        rule.tagsToAdd = tags
        rule.labelRaw = labelRaw
        rule.rating = rating
        rule.makesFavorite = makesFavorite
        rule.marksRead = marksRead
        rule.takesOutOfInbox = takesOutOfInbox
        rule.isEnabled = isEnabled
        rule.schedule = schedule
        rule.runsAtLaunch = runsAtLaunch
        library.save()
        return rule
    }
}
