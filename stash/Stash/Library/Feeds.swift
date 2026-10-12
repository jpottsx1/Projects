import Foundation
#if os(iOS)
import BackgroundTasks
#endif
import SwiftData
import StashCore

/// Web feeds: subscribing, and checking for new posts, which arrive as
/// unread links under the feed in the sidebar and are read like any link.
extension Library {
    enum FeedError: LocalizedError {
        case badAddress
        case noFeed
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .badAddress: "That doesn’t look like a web address."
            case .noFeed: "There’s no feed there. Try the address of the site’s feed, often ending in /feed or /rss."
            case .unreachable(let reason): reason
            }
        }
    }

    /// How often feeds are checked while Stash is open, in minutes.
    static var feedCheckMinutes: Int {
        get { UserDefaults.standard.object(forKey: "feedCheckMinutes") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "feedCheckMinutes") }
    }

    /// The posts a new subscription starts with.
    static let firstPostCount = 10
    /// The most posts taken from one check, for a feed that's been away a long time.
    static let postsPerCheck = 50

    func feeds() -> [Feed] {
        (try? context.fetch(FetchDescriptor<Feed>(sortBy: [SortDescriptor(\.title)]))) ?? []
    }

    // MARK: - Subscribing

    /// Subscribes to a feed, given its address or the address of a site
    /// that says where its feed is, and shows it.
    @discardableResult
    func subscribe(to address: String) async throws -> Feed {
        guard let url = WebAddress.url(from: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FeedError.badAddress
        }
        let (feedURL, parsed) = try await Self.findFeed(at: url)
        if let existing = feeds().first(where: { $0.urlString == feedURL.absoluteString }) {
            sidebar = .feed(existing)
            return existing
        }
        let feed = Feed(title: parsed.title.isEmpty ? WebAddress.displayHost(of: feedURL) : parsed.title, url: feedURL)
        feed.siteURLString = parsed.siteURL?.absoluteString
        context.insert(feed)
        // Filed where you're looking, like anything else added.
        if case .category(let category) = sidebar { feed.categoryID = category.uuid }
        save()
        take(parsed, into: feed)
        sidebar = .feed(feed)
        return feed
    }

    /// The feed at an address: there, or wherever the page there says, or
    /// at one of the usual places on the site.
    private static func findFeed(at url: URL) async throws -> (URL, ParsedFeed) {
        let (data, finalURL) = try await fetch(url)
        if let feed = FeedParser.parse(data, from: finalURL) { return (finalURL, feed) }
        var candidates = FeedParser.feedLinks(inHTML: String(decoding: data, as: UTF8.self), base: finalURL)
        if candidates.isEmpty {
            candidates = ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"]
                .compactMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
        }
        for candidate in candidates.prefix(6) {
            guard let (data, found) = try? await fetch(candidate),
                  let feed = FeedParser.parse(data, from: found) else { continue }
            return (found, feed)
        }
        throw FeedError.noFeed
    }

    private static func fetch(_ url: URL) async throws -> (Data, URL) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Stash/1.0 (feed reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, */*;q=0.8",
                         forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FeedError.unreachable("The site answered “\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))”.")
            }
            return (data, response.url ?? url)
        } catch let error as FeedError {
            throw error
        } catch {
            throw FeedError.unreachable(error.localizedDescription)
        }
    }

    // MARK: - Checking

    /// Checks the feeds not checked for a while, or all of them.
    func checkFeeds(all: Bool = false) async {
        let interval = TimeInterval(max(Self.feedCheckMinutes, 5) * 60)
        for feed in feeds() {
            if !all, let last = feed.lastCheckedAt, Date.now.timeIntervalSince(last) < interval { continue }
            await check(feed)
        }
    }

    func check(_ feed: Feed) async {
        guard let url = feed.url, !checkingFeeds.contains(feed.uuid) else { return }
        checkingFeeds.insert(feed.uuid)
        defer { checkingFeeds.remove(feed.uuid) }
        do {
            let (data, found) = try await Self.fetch(url)
            guard feed.modelContext != nil, !feed.isDeleted else { return }
            guard let parsed = FeedParser.parse(data, from: found) else { throw FeedError.noFeed }
            feed.lastError = ""
            take(parsed, into: feed)
        } catch {
            guard feed.modelContext != nil, !feed.isDeleted else { return }
            feed.lastError = error.localizedDescription
        }
        feed.lastCheckedAt = .now
        save()
    }

    /// Adds the posts not seen before, newest first, and fetches their pages.
    private func take(_ parsed: ParsedFeed, into feed: Feed) {
        let seen = feed.seen
        let isFirst = feed.seenIDs.isEmpty
        let fresh = parsed.entries
            .filter { !seen.contains($0.id) && $0.link != nil }
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            .prefix(isFirst ? Self.firstPostCount : Self.postsPerCheck)
        if !parsed.title.isEmpty, feed.title.isEmpty { feed.title = parsed.title }

        var added: [Item] = []
        for entry in fresh {
            guard let link = entry.link, !hasLink(link) else { continue }
            added.append(addPost(entry, link: link, from: feed))
        }
        feed.markSeen(parsed.entries.map(\.id))
        save()
        guard !added.isEmpty else { return }
        // One page at a time: each is loaded in a web view.
        Task {
            for item in added where isAlive(item) {
                await refreshPage(of: item)
            }
        }
    }

    /// Whether the library has this page already, in the Trash or not: a
    /// post that's been thrown away shouldn't come back.
    private func hasLink(_ url: URL) -> Bool {
        let address = url.absoluteString
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.urlString == address })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private func addPost(_ entry: ParsedFeed.Entry, link: URL, from feed: Feed) -> Item {
        let item = Item(kind: .link, title: entry.title.isEmpty ? WebAddress.displayHost(of: link) : entry.title)
        item.urlString = link.absoluteString
        item.summary = entry.summary
        item.createdAt = entry.published ?? .now
        item.modifiedAt = item.createdAt
        item.isUnread = true
        item.feedEntryID = entry.id
        if !entry.html.isEmpty { item.extractedText = HTMLText.extract(from: entry.html).text }
        context.insert(item)
        item.feed = feed
        // Posts live under their feed, not in the Inbox.
        if let id = feed.categoryID {
            item.category = (try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.uuid == id })))?.first
        }
        reindex(item)
        arrived(item)
        return item
    }

    /// Checks feeds now, then every few minutes while Stash is open; each
    /// feed waits its interval between checks.
    func startCheckingFeeds() {
        guard feedTimer == nil else { return }
        feedTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkFeeds()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    // MARK: - Managing

    func markAllRead(in feed: Feed) {
        setUnread((feed.items ?? []).filter(\.isUnread), false)
    }

    func rename(_ feed: Feed, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        feed.title = trimmed
        save()
    }

    func file(_ feed: Feed, in category: ItemCategory?) {
        feed.categoryID = category?.uuid
        save()
    }

    /// Stops following a feed. Its posts stay in the library; those never
    /// opened go to the Trash.
    func unsubscribe(_ feed: Feed, keepingUnread: Bool = false) {
        let posts = feed.items ?? []
        if sidebar == .feed(feed) { sidebar = .all }
        if !keepingUnread { moveToTrash(posts.filter { $0.isUnread && !$0.isTrashed && $0.body.isEmpty && ($0.highlights ?? []).isEmpty }) }
        context.delete(feed)
        save()
    }
}

#if os(iOS)
/// Checking feeds while Stash isn't open: iOS wakes it now and then (as
/// often as it sees fit, at most as often as feeds are set to be checked).
enum FeedRefresh {
    static let identifier = "com.jpottsx1.stash.feeds"

    /// Asks to be woken again; called as Stash goes into the background.
    @MainActor
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(Library.feedCheckMinutes, 15) * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func run() async {
        schedule()
        let library = StashStore.shared.library
        guard !library.feeds().isEmpty else { return }
        await library.checkFeeds()
    }
}
#endif
