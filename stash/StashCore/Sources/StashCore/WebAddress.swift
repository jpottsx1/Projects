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

    /// The same for two addresses of the same page: http or https, with or
    /// without "www.", a trailing slash, a #section, or tracking
    /// parameters like `utm_source`. Fragments that look like an app's
    /// route (`#/inbox`, `#!/page`) still count, since they pick the page.
    public static func duplicateKey(for url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        var host = (parts.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = (parts.queryItems ?? [])
            .filter { !isTracking($0.name) }
            .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }
            .sorted()
            .joined(separator: "&")
        let fragment = parts.fragment.flatMap { $0.hasPrefix("/") || $0.hasPrefix("!") ? $0 : nil }
        var key = host
        if let port = url.port, port != 80, port != 443 { key += ":\(port)" }
        key += path
        if !query.isEmpty { key += "?" + query }
        if let fragment { key += "#" + fragment }
        return key
    }

    private static func isTracking(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_")
            || ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "ref_src", "_hsenc", "_hsmi"].contains(name)
    }

    /// "www.example.com" -> "example.com", for showing under a link's title.
    public static func displayHost(of url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
