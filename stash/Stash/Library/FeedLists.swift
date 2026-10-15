import Foundation
import SwiftData
import StashCore

/// Feeds to and from other feed readers, as OPML.
extension Library {
    /// Subscribes to each feed in the list not subscribed to already; a
    /// folder becomes the category its new posts are filed in.
    func importFeeds(_ url: URL) async -> ImportSummary {
        var summary = ImportSummary()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            summary.failed.append(url.lastPathComponent)
            return summary
        }
        let existing = Set(feeds().map(\.urlString))
        for entry in OPML.parse(data) where !existing.contains(entry.url) {
            guard let address = WebAddress.url(from: entry.url) else {
                summary.failed.append(entry.title.isEmpty ? entry.url : entry.title)
                continue
            }
            let feed = Feed(title: entry.title.isEmpty ? WebAddress.displayHost(of: address) : entry.title, url: address)
            context.insert(feed)
            if !entry.folders.isEmpty {
                let category = entry.folders.reduce(nil as ItemCategory?) { parent, name in importCategory(named: name, in: parent) ?? parent }
                feed.categoryID = category?.uuid
            }
            summary.feeds += 1
        }
        save()
        revision += 1
        // Their posts arrive as the feeds are checked.
        Task { await checkFeeds(all: true) }
        return summary
    }

    /// Every feed, as an OPML file in a temporary folder, for saving.
    func exportFeeds() throws -> URL {
        let categories = Dictionary(((try? context.fetch(FetchDescriptor<ItemCategory>())) ?? []).map { ($0.uuid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let list = feeds().map { feed in
            OPML.Feed(title: feed.title, url: feed.urlString,
                      folders: feed.categoryID.flatMap { categories[$0] }.map { [$0.name] } ?? [])
        }
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Stash Feeds.opml")
        try OPML.write(list).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
