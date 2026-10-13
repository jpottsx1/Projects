import Foundation
import SwiftData
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where something dropped on the Sorter goes.
enum ArrivalTarget {
    case inbox
    case category(ItemCategory)
}

/// Links to items, Stash's URL scheme, the Sorter, scheduled rules and
/// the concordance.
extension Library {
    // MARK: - Item links and the URL scheme

    func copyItemLink(_ item: Item) {
        copyToClipboard(StashURL.itemLink(item.uuid).absoluteString)
    }

    func copyMarkdownLink(_ item: Item) {
        copyToClipboard(StashURL.markdownLink(title: item.displayTitle, id: item.uuid))
    }

    /// Carries out a `stash://` request from another app, then goes back to
    /// it if it asked (x-callback-url).
    func perform(_ request: StashURL.Request) {
        var made: Item?
        var succeeded = true
        switch request.action {
        case .item(let id):
            if let item = items(withIDs: [id]).first { show(item); made = item } else { succeeded = false }
        case .title(let title):
            // As a [[link]] does: open it, or make it if there's none yet.
            if let item = item(titled: title) { show(item); made = item } else { made = newNote(titled: title) }
        case .newNote(let title, let text):
            let item = captureNote(title: title, text: text)
            show(item)
            made = item
        case .saveLink(let url, let title):
            guard let web = WebAddress.url(from: url.absoluteString) else { succeeded = false; break }
            let item = captureLink(web)
            if let title { item.title = title; save() }
            show(item)
            made = item
        case .addToToday(let text):
            made = appendToToday(text)
        case .today:
            made = openToday()
        case .search(let query):
            sidebar = .all
            searchText = query
        }
        if succeeded, let success = request.success {
            Self.openExternally(StashURL.callback(success, id: made?.uuid))
        } else if !succeeded, let error = request.error {
            Self.openExternally(error)
        }
    }

    static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Sorter

    /// Things dropped on the Sorter: into that category (or the Inbox),
    /// without changing what the main window shows.
    func importDropped(_ providers: [NSItemProvider], into target: ArrivalTarget) async {
        arrivalTarget = target
        defer { arrivalTarget = nil }
        await importDropped(providers)
        runSearch()
    }

    /// A note jotted in the Sorter.
    func jot(_ text: String, into target: ArrivalTarget) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = String(trimmed.prefix { $0 != "\n" }.prefix(60))
        let item = Item(kind: .note, title: firstLine)
        item.body = trimmed
        arrivalTarget = target
        insert(item, select: false)
        arrivalTarget = nil
        arrived(item)
        runSearch()
    }

    // MARK: - Scheduled rules

    func startRunningRules() {
        guard ruleTimer == nil else { return }
        runRules(atLaunch: true)
        ruleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard !Task.isCancelled else { return }
                self?.runRules(atLaunch: false)
            }
        }
    }

    /// Rules that run when Stash opens, or whose time has come round.
    func runRules(atLaunch: Bool) {
        let rules = ((try? context.fetch(FetchDescriptor<SmartRule>(predicate: #Predicate { $0.isEnabled }))) ?? [])
            .sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) }
        for rule in rules where (atLaunch && rule.runsAtLaunch) || rule.schedule.isDue(lastRun: rule.lastRunAt) {
            apply(rule, toExisting: true)
        }
    }

    // MARK: - Concordance

    /// The words in these items, worked out away from the main thread.
    func concordance(of items: [Item]) async -> [Concordance.Word] {
        let texts = items.filter { !$0.isTrashed && !$0.isTemplate }.map { item in
            item.isLocked ? item.title : [item.title, item.body, item.summary, item.extractedText].joined(separator: "\n")
        }
        return await Task.detached(priority: .userInitiated) { Concordance.words(in: texts) }.value
    }
}
