import Compression
import Foundation
import StashCore

/// Raw DEFLATE, as ZIP files (and so EPUB books) use, for `Zip.Inflate`.
enum Inflater {
    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out -> Int in
            data.withUnsafeBytes { input -> Int in
                guard let target = out.bindMemory(to: UInt8.self).baseAddress,
                      let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(target, size, source, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Zip.Failure.damaged("inflate") }
        return output
    }
}

/// An EPUB book opened for reading: its contents, and its files on request.
final class EPUBDocument: @unchecked Sendable {
    let book: EPUBBook
    private let zip: ZipReader
    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    init(url: URL) throws {
        let zip = try ZipReader(data: try Data(contentsOf: url, options: .alwaysMapped))
        self.zip = zip
        book = try EPUBBook { try zip.data(for: $0, inflate: Inflater.inflate) }
    }

    /// A file inside the book, by its path from the book's root.
    func data(at path: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        let data = try zip.data(for: path, inflate: Inflater.inflate)
        // Chapters and their pictures are asked for again as you page back
        // and forth; keep the small ones.
        if data.count < 2_000_000 { cache[path] = data }
        return data
    }

    /// Every chapter's words, for search.
    func text(limit: Int) -> String {
        var text = ""
        for chapter in book.chapters {
            guard let data = try? data(at: chapter.path) else { continue }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            text += HTMLText.extract(from: html, maxLength: limit).text + "\n"
            if text.count >= limit { break }
        }
        return String(text.prefix(limit))
    }

    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "xht": "application/xhtml+xml"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js": "text/javascript"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "otf": "font/otf"
        case "ttf": "font/ttf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "mp3": "audio/mpeg"
        case "mp4", "m4v": "video/mp4"
        case "ncx", "opf", "xml": "application/xml"
        default: "application/octet-stream"
        }
    }
}
