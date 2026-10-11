import Foundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Small pictures of items for the list and the grid: a document's first
/// page or the picture itself, a saved page's top. Kept on the item as a
/// small JPEG, so they sync and are drawn without opening the file.
enum Thumbnails {
    static let size = CGSize(width: 480, height: 480)

    /// A JPEG of `image`, no bigger than `size` across.
    static func jpeg(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let longest = CGFloat(max(image.width, image.height))
        let scale = min(1, size.width / max(longest, 1))
        let resized = scale < 1 ? resize(image, scale: scale) ?? image : image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func resize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Quick Look's picture of a file: a PDF's first page, a photo, a
    /// document's first page, or nil for files it can only show as an icon.
    static func make(forFileAt url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return jpeg(thumbnail.cgImage)
    }

    // MARK: - Showing

    private static let cache = NSCache<NSString, CGImageBox>()

    /// The item's thumbnail, decoded once and then kept while there's room.
    static func image(for item: Item) -> CGImage? {
        guard let data = item.thumbnailData else { return nil }
        let key = "\(item.uuid.uuidString)-\(data.count)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}

/// An item's thumbnail filling its frame, or nothing if it has none.
struct ThumbnailImage: View {
    let item: Item

    var body: some View {
        if let image = Thumbnails.image(for: item) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        }
    }
}
