import Foundation

public enum WebAddress {
    /// A web address from what someone typed or pasted. "example.com/page"
    /// gets https:// in front; anything that isn't an http(s) address with a
    /// host is nil.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if (scheme == "http" || scheme == "https"), url.host?.isEmpty == false { return url }
            if trimmed.contains("://") { return nil }
        }
        guard trimmed.contains("."), let url = URL(string: "https://" + trimmed),
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// "www.example.com" -> "example.com", for showing under a link's title.
    public static func displayHost(of url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
