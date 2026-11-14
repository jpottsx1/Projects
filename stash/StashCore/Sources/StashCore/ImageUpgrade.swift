import Foundation

/// Finding the biggest version of a picture, as Eagle does when saving one:
/// what the page offers (`srcset`, `<picture>` sources, the full-size
/// picture a thumbnail links to, `data-` attributes for lazy loading), and
/// the original behind a resized address on sites known for resizing
/// (WordPress, Wikimedia, Pinterest, Twitter/X, Imgur, Google, Shopify,
/// Amazon, Reddit, Squarespace, Cloudinary, Unsplash, Medium, Substack).
/// Candidates come best guess first; the app tries them in turn and keeps
/// the largest that loads as a picture.
public enum ImageUpgrade {
    /// Candidates for the picture at `address`: likely originals first, the address itself last.
    public static func candidates(for address: String, html: String? = nil, base: String? = nil) -> [String] {
        var found: [String] = []
        if let html { found += fromPage(html, image: address, base: base ?? address) }
        found += rewrites(of: address)
        found.append(address)
        var seen: Set<String> = []
        return found.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - From the page

    /// Larger versions the page itself names for this picture.
    static func fromPage(_ html: String, image address: String, base: String) -> [String] {
        let target = key(address)
        var results: [String] = []
        let tagPattern = try! NSRegularExpression(pattern: "<(img|source|a)\\b[^>]*>", options: [.caseInsensitive])
        let string = html as NSString
        var lastLink: String?
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: string.length)) {
            let tag = string.substring(with: match.range)
            let name = string.substring(with: match.range(at: 1)).lowercased()
            let attributes = HTMLText.attributes(of: tag)
            if name == "a" {
                lastLink = attributes["href"].flatMap { resolve($0, base: base) }
                continue
            }
            var sources = [attributes["src"], attributes["data-src"], attributes["data-original"], attributes["data-lazy-src"]].compactMap { $0 }
            let sets = [attributes["srcset"], attributes["data-srcset"]].compactMap { $0 }
            sources += sets.flatMap { srcset($0).map(\.url) }
            guard sources.compactMap({ resolve($0, base: base) }).contains(where: { key($0) == target }) else { continue }
            // This tag is the picture: the biggest it offers, then any full-size one it names, then where it links.
            for set in sets {
                if let best = srcset(set).max(by: { $0.size < $1.size }), let url = resolve(best.url, base: base) { results.append(url) }
            }
            for key in ["data-orig-file", "data-large-file", "data-full", "data-full-src", "data-original", "data-zoom-image", "data-hi-res-src"] {
                if let value = attributes[key], let url = resolve(value, base: base) { results.append(url) }
            }
            if let link = lastLink, isPictureAddress(link) { results.append(link) }
        }
        return results
    }

    /// A `srcset`'s candidates, sized by width (`800w`) or density (`2x`, as thousands).
    public static func srcset(_ value: String) -> [(url: String, size: Double)] {
        value.split(separator: ",").compactMap { part in
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let url = pieces.first, !url.isEmpty else { return nil }
            var size = 1.0
            if pieces.count > 1, let descriptor = pieces.last, let number = Double(descriptor.dropLast()) {
                size = descriptor.hasSuffix("x") ? number * 1000 : number
            }
            return (url, size)
        }
    }

    // MARK: - Known ways of resizing

    /// The address of the original behind a resized one, best guesses first.
    public static func rewrites(of address: String) -> [String] {
        guard var components = URLComponents(string: address), let host = components.host?.lowercased() else { return [] }
        var results: [String] = []
        let path = components.path

        func with(path newPath: String? = nil, query: [URLQueryItem]?? = .none) -> String? {
            var copy = components
            if let newPath { copy.path = newPath }
            if case .some(let items) = query { copy.queryItems = items?.isEmpty == true ? nil : items }
            return copy.string
        }

        // Wikimedia: /thumb/a/ab/File.jpg/220px-File.jpg → /a/ab/File.jpg
        if host.hasSuffix("wikimedia.org"), path.contains("/thumb/") {
            var parts = path.components(separatedBy: "/")
            if let index = parts.firstIndex(of: "thumb") {
                parts.remove(at: index)
                parts.removeLast()
                if let url = with(path: parts.joined(separator: "/")) { results.append(url) }
            }
        }
        // Pinterest: /236x/ → /originals/
        if host.hasSuffix("pinimg.com"), let range = path.range(of: #"^/\d+x(\d+)?/"#, options: .regularExpression) {
            results.append(with(path: path.replacingCharacters(in: range, with: "/originals/")) ?? "")
        }
        // Twitter/X: ?name=small → name=orig
        if host == "pbs.twimg.com" {
            var items = (components.queryItems ?? []).filter { $0.name != "name" }
            items.append(URLQueryItem(name: "name", value: "orig"))
            results.append(with(query: .some(items)) ?? "")
        }
        // Imgur: abcdefgh.jpg (a size letter on a 7-character id) → abcdefg.jpg
        if host == "i.imgur.com", let range = path.range(of: #"^/([A-Za-z0-9]{7})[sbtmlh](\.\w+)$"#, options: .regularExpression) {
            let name = String(path[range])
            results.append(with(path: "/" + name.dropFirst().prefix(7) + name.drop { $0 != "." }) ?? "")
        }
        // Google (Blogger, Photos, YouTube art): =w300-h200 or /s320/ → =s0 or /s0/
        if host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com") || host.hasSuffix("bp.blogspot.com") {
            if let range = path.range(of: #"=[a-z0-9\-]+$"#, options: .regularExpression) {
                results.append(with(path: path.replacingCharacters(in: range, with: "=s0")) ?? "")
            }
            if let range = path.range(of: #"/[swh]\d+(-[a-z0-9-]+)?/"#, options: .regularExpression) {
                results.append(with(path: path.replacingCharacters(in: range, with: "/s0/")) ?? "")
            }
        }
        // Amazon: Name._SX300_SY200_.jpg → Name.jpg
        if host.contains("media-amazon.com") || host.contains("images-amazon.com"),
           let range = path.range(of: #"\._[A-Z0-9_,]+_\."#, options: .regularExpression) {
            results.append(with(path: path.replacingCharacters(in: range, with: ".")) ?? "")
        }
        // Reddit: preview.redd.it → i.redd.it, no resizing.
        if host == "preview.redd.it" {
            var copy = components
            copy.host = "i.redd.it"
            copy.query = nil
            results.append(copy.string ?? "")
        }
        // Cloudinary: /upload/w_300,h_200,c_fill/ → /upload/
        if host.contains("cloudinary.com"), let range = path.range(of: #"/upload/[a-z]{1,2}_[^/]+/"#, options: .regularExpression) {
            results.append(with(path: path.replacingCharacters(in: range, with: "/upload/")) ?? "")
        }
        // Medium: /max/800/ or /resize:fit:800/ → none
        if host.hasSuffix("medium.com"), let range = path.range(of: #"/(max/\d+|resize:[a-z]+:\d+(:\d+)?|fit/c/\d+/\d+)/"#, options: .regularExpression) {
            results.append(with(path: path.replacingCharacters(in: range, with: "/")) ?? "")
        }
        // Substack: the original behind its image proxy.
        if host == "substackcdn.com", let range = address.range(of: "https%3A%2F%2F") {
            results.append(address[range.lowerBound...].removingPercentEncoding ?? "")
        }
        // WordPress and many others: Name-300x200.jpg → Name.jpg; Shopify: Name_300x.jpg → Name.jpg
        if let range = path.range(of: #"-\d{2,5}x\d{2,5}(?=\.\w+$)"#, options: .regularExpression) {
            results.append(with(path: path.replacingCharacters(in: range, with: "")) ?? "")
        }
        if host.contains("shopify"), let range = path.range(of: #"_(\d+x\d*|\d*x\d+|small|medium|large|grande|compact)(@\dx)?(?=\.\w+$)"#, options: .regularExpression) {
            results.append(with(path: path.replacingCharacters(in: range, with: "")) ?? "")
        }
        // Squarespace: ?format=300w → format=2500w
        if host.contains("squarespace"), components.queryItems?.contains(where: { $0.name == "format" }) == true {
            let items = (components.queryItems ?? []).map { $0.name == "format" ? URLQueryItem(name: "format", value: "2500w") : $0 }
            results.append(with(query: .some(items)) ?? "")
        }
        // Size settings in the query (w, h, width, resize, fit, quality): without them.
        let sizeNames: Set<String> = ["w", "h", "width", "height", "resize", "fit", "size", "quality", "q", "dpr", "crop", "auto", "fm", "ixlib", "cs"]
        if let items = components.queryItems, items.contains(where: { sizeNames.contains($0.name.lowercased()) }) {
            results.append(with(query: .some(items.filter { !sizeNames.contains($0.name.lowercased()) })) ?? "")
        }
        return results.filter { !$0.isEmpty && $0 != address }
    }

    // MARK: - Helpers

    static func resolve(_ value: String, base: String) -> String? {
        let trimmed = HTMLText.decodeEntities(value.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }
        return URL(string: trimmed, relativeTo: URL(string: base))?.absoluteURL.absoluteString
    }

    /// Two addresses of the same picture, compared without their query.
    static func key(_ address: String) -> String {
        guard let components = URLComponents(string: address) else { return address }
        return (components.host ?? "") + components.path
    }

    public static func isPictureAddress(_ address: String) -> Bool {
        let path = URLComponents(string: address)?.path.lowercased() ?? ""
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "tif", "tiff", "bmp"].contains((path as NSString).pathExtension)
    }
}
