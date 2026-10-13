import Foundation

/// Searching the web for an image, as Google Lens, Bing, TinEye and Yandex
/// do. They can only fetch an image from a web address, never a file on
/// this device: an image with an address is searched for by it; one
/// without is copied, for pasting into the site's search page.
public enum ImageSearch {
    public enum Engine: String, CaseIterable, Identifiable {
        case googleLens, bing, tinEye, yandex

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .googleLens: "Google Lens"
            case .bing: "Bing Visual Search"
            case .tinEye: "TinEye"
            case .yandex: "Yandex Images"
            }
        }

        /// The results for the image at `address`; nil unless it's a web address.
        public func searchURL(forImageAt address: String) -> URL? {
            guard let image = URL(string: address), let scheme = image.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", image.host != nil else { return nil }
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encoded = image.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            switch self {
            case .googleLens: return URL(string: "https://lens.google.com/uploadbyurl?url=" + encoded)
            case .bing: return URL(string: "https://www.bing.com/images/search?view=detailv2&iss=sbi&q=imgurl:" + encoded)
            case .tinEye: return URL(string: "https://tineye.com/search?url=" + encoded)
            case .yandex: return URL(string: "https://yandex.com/images/search?rpt=imageview&url=" + encoded)
            }
        }

        /// Where to paste an image that has no web address.
        public var pasteURL: URL {
            switch self {
            case .googleLens: URL(string: "https://images.google.com/")!
            case .bing: URL(string: "https://www.bing.com/visualsearch")!
            case .tinEye: URL(string: "https://tineye.com/")!
            case .yandex: URL(string: "https://yandex.com/images/")!
            }
        }
    }

    /// Whether an address looks like a picture itself (`…/cat.jpg`), rather
    /// than a page.
    public static func isImageAddress(_ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "avif", "svg"]
            .contains(url.pathExtension.lowercased())
    }

    /// The web address a downloaded file came from, from the Mac's "Where
    /// from" record (`com.apple.metadata:kMDItemWhereFroms`, a property list
    /// of addresses: the file's, then the page's). Nil if none is a web address.
    public static func whereFrom(_ plist: Data) -> String? {
        guard let addresses = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String] else { return nil }
        return addresses.first { address in
            guard let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
    }
}
