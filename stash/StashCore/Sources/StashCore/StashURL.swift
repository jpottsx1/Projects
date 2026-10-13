import Foundation

/// Stash's own addresses, for links to items from other apps, and for
/// automation (Shortcuts, Keyboard Maestro, Drafts) in the x-callback-url
/// style:
///
/// - `stash://item?id=UUID` -- open an item (what *Copy Item Link* copies)
/// - `stash://open?title=Title` -- open an item by title, as `[[links]]` do
/// - `stash://new-note?title=…&text=…`
/// - `stash://save-link?url=…&title=…`
/// - `stash://add-to-today?text=…`, `stash://today`
/// - `stash://search?query=…`
/// - `stash://x-callback-url/new-note?…&x-success=…&x-error=…` -- any of the
///   above, then back to the app that asked, with `id` and `link` added
public enum StashURL {
    public static let scheme = "stash"

    public enum Action: Equatable {
        case item(UUID)
        case title(String)
        case newNote(title: String, text: String)
        case saveLink(URL, title: String?)
        case addToToday(String)
        case today
        case search(String)
    }

    public struct Request: Equatable {
        public var action: Action
        /// Where to go afterwards, for x-callback-url requests.
        public var success: URL?
        public var error: URL?
    }

    public static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil { values[item.name] = item.value ?? "" }
        var name = (components.host ?? "").lowercased()
        var path = components.path.split(separator: "/").map(String.init)
        if name == "x-callback-url", !path.isEmpty { name = path.removeFirst().lowercased() }
        let success = values["x-success"].flatMap(URL.init(string:))
        let error = values["x-error"].flatMap(URL.init(string:))
        func request(_ action: Action) -> Request { Request(action: action, success: success, error: error) }

        switch name {
        case "item":
            // stash://item?id=… or stash://item/…
            guard let id = (values["id"] ?? path.first).flatMap(UUID.init(uuidString:)) else { return nil }
            return request(.item(id))
        case "open":
            if let id = values["id"].flatMap(UUID.init(uuidString:)) { return request(.item(id)) }
            guard let title = values["title"], !title.isEmpty else { return nil }
            return request(.title(title))
        case "new-note", "add-note":
            return request(.newNote(title: values["title"] ?? "", text: values["text"] ?? ""))
        case "save-link", "add-link":
            guard let address = values["url"], let link = URL(string: address), link.scheme != nil else { return nil }
            return request(.saveLink(link, title: values["title"].flatMap { $0.isEmpty ? nil : $0 }))
        case "add-to-today", "append-today":
            guard let text = values["text"], !text.isEmpty else { return nil }
            return request(.addToToday(text))
        case "today":
            return request(.today)
        case "search":
            return request(.search(values["query"] ?? values["q"] ?? ""))
        default:
            return nil
        }
    }

    /// A link to an item, to paste anywhere.
    public static func itemLink(_ id: UUID) -> URL {
        URL(string: "\(scheme)://item?id=\(id.uuidString)")!
    }

    /// `[Title](stash://item?id=…)`, for Markdown apps.
    public static func markdownLink(title: String, id: UUID) -> String {
        let escaped = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(itemLink(id).absoluteString))"
    }

    /// The x-success address with what was made added: its `id` and `link`.
    public static func callback(_ url: URL, id: UUID?) -> URL {
        guard let id, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "id", value: id.uuidString),
            URLQueryItem(name: "link", value: itemLink(id).absoluteString),
        ]
        return components.url ?? url
    }
}

/// When a smart rule runs besides as items arrive.
public enum RuleSchedule: String, CaseIterable, Identifiable {
    case never, hourly, daily, weekly

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .never: "Never"
        case .hourly: "Every Hour"
        case .daily: "Every Day"
        case .weekly: "Every Week"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .hourly: 3600
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }

    /// Whether it's time to run again.
    public func isDue(lastRun: Date?, now: Date = .now) -> Bool {
        guard let interval else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}
