import CoreGraphics
import Foundation
import ImageIO
import StashCore
import UniformTypeIdentifiers

/// Saving pictures from the web at their biggest, as Eagle does: the page's
/// own larger versions and the originals behind resized addresses are tried
/// (`ImageUpgrade`), and the one with the most pixels kept, so there's no
/// clicking through to find the full-size picture.
extension Library {
    struct DownloadedImage {
        let file: URL
        let address: URL
        let pixels: Int
        let pageHTML: String?
    }

    /// The biggest version found, in a temporary folder.
    static func biggestImage(for address: URL, page: URL?) async -> DownloadedImage? {
        var html: String?
        if let page {
            var request = URLRequest(url: page, timeoutInterval: 20)
            request.setValue(TextExtractor.userAgent, forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request), response.mimeType?.contains("html") == true {
                html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }
        }
        var best: (data: Data, address: URL, pixels: Int, type: UTType)?
        for candidate in ImageUpgrade.candidates(for: address.absoluteString, html: html, base: page?.absoluteString).prefix(8) {
            guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue(TextExtractor.userAgent, forHTTPHeaderField: "User-Agent")
            if let page { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let size = pixelSize(of: data) else { continue }
            let pixels = size.width * size.height
            let type = response.mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: url.pathExtension) ?? .jpeg
            if pixels > (best?.pixels ?? 0) { best = (data, url, pixels, type) }
        }
        guard let best else { return nil }
        var name = best.address.lastPathComponent.removingPercentEncoding ?? best.address.lastPathComponent
        if name.isEmpty || UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) != true {
            name = (name.isEmpty ? "Picture" : name) + "." + (best.type.preferredFilenameExtension ?? "jpg")
        }
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        guard (try? best.data.write(to: file)) != nil else { return nil }
        return DownloadedImage(file: file, address: best.address, pixels: best.pixels, pageHTML: html)
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The picture at its biggest, as a document, with where it came from and the page's reference.
    @discardableResult
    func saveFullSizeImage(from address: URL, page: URL?, title: String = "", category: ItemCategory? = nil,
                           tags: [String] = []) async -> Item? {
        guard let found = await Self.biggestImage(for: address, page: page),
              let data = try? Data(contentsOf: found.file) else {
            importError = "The picture at \(address.host ?? address.absoluteString) couldn’t be downloaded."
            return nil
        }
        defer { try? FileManager.default.removeItem(at: found.file.deletingLastPathComponent()) }
        guard let item = addDocument(data: data, named: found.file.lastPathComponent, in: category) else { return nil }
        if !title.isEmpty { item.title = title }
        item.sourceAddress = found.address.absoluteString
        if let html = found.pageHTML, let page {
            fillReference(of: item, from: Reference.fromHTML(html, url: page.absoluteString))
        }
        if !tags.isEmpty { addTags(from: tags.joined(separator: ","), to: item) }
        item.isUnread = true
        if item.category == nil { fileArrival(item) }
        save()
        reindex(item)
        arrived(item)
        runSearch()
        Task {
            await fillContentHash(of: item)
            await fillThumbnail(of: item)
            await extractText(from: item)
        }
        return item
    }

    /// A picture already saved, replaced by a bigger version of it if there is one.
    /// Gives whether it was. The first replacement keeps the original, for Revert to Original.
    @discardableResult
    func getFullSizeVersion(of item: Item) async -> Bool {
        guard Self.isPicture(item), Self.canMarkUp(item), let path = item.storedFilePath,
              let address = item.sourceAddress.flatMap(URL.init(string:)), let current = localFile(for: item) else { return false }
        let page = URL(string: reference(of: item).url).flatMap { $0 == address ? nil : $0 }
        let existing = (try? Data(contentsOf: current)).flatMap(Self.pixelSize).map { $0.width * $0.height } ?? 0
        guard let found = await Self.biggestImage(for: address, page: page), found.pixels > existing,
              let data = try? Data(contentsOf: found.file) else { return false }
        defer { try? FileManager.default.removeItem(at: found.file.deletingLastPathComponent()) }
        keepOriginal(of: item)
        let newExtension = found.file.pathExtension
        var newPath = path
        if newExtension.lowercased() != (path as NSString).pathExtension.lowercased() {
            newPath = (path as NSString).deletingPathExtension + "." + newExtension
        }
        guard (try? files.write(data, to: newPath)) != nil else { return false }
        if newPath != path {
            item.storedFilePath = newPath
            item.contentTypeIdentifier = UTType(filenameExtension: newExtension)?.identifier ?? item.contentTypeIdentifier
        }
        item.sourceAddress = found.address.absoluteString
        await fileDidChange(item)
        return true
    }
}
