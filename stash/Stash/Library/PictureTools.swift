import CoreGraphics
import Foundation
import ImageIO
import StashCore
import UniformTypeIdentifiers

/// Rotating, flipping, cropping and resizing pictures in place (the first
/// change keeps the original, for *Revert to Original*), and converting
/// them to another format as a new document.
extension Library {
    enum PictureChange {
        case rotateLeft, rotateRight, flipHorizontal, flipVertical
        case crop(x: Int, y: Int, width: Int, height: Int)
        case fit(maxDimension: Int)
    }

    enum PictureFormat: String, CaseIterable, Identifiable {
        case jpeg, png, heic
        var id: String { rawValue }
        var name: String { rawValue == "heic" ? "HEIC" : rawValue.uppercased() }
        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            }
        }
    }

    /// A picture that can be changed: stored here, and in a format that can be written back.
    static func canEditPicture(_ item: Item) -> Bool {
        guard Self.canMarkUp(item), let type = item.contentType, type.conforms(to: .image), type != .gif, type != .svg else { return false }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(type.identifier)
    }

    func change(_ pictures: [Item], _ change: PictureChange) {
        var failed: [String] = []
        for item in pictures where Self.canEditPicture(item) {
            guard let path = item.storedFilePath, let url = localFile(for: item), let type = item.contentType,
                  let image = Self.uprightImage(at: url), let changed = Self.apply(change, to: image),
                  let data = Self.encode(changed, as: type) else {
                failed.append(item.displayTitle)
                continue
            }
            keepOriginal(of: item)
            do {
                try files.write(data, to: path)
                Task { await fileDidChange(item) }
            } catch {
                failed.append(item.displayTitle)
            }
        }
        if !failed.isEmpty { importError = "Couldn’t change " + failed.map { "“\($0)”" }.joined(separator: ", ") + "." }
    }

    /// Copies in another format, beside the originals and linked to them.
    func convert(_ pictures: [Item], to format: PictureFormat) {
        var made: [Item] = []
        for item in pictures where Self.isPicture(item) {
            guard let url = localFile(for: item), let image = Self.uprightImage(at: url),
                  let data = Self.encode(image, as: format.type),
                  let copy = addDocument(data: data, named: FinderSnapshot.fileName(item.displayTitle, ext: format.type.preferredFilenameExtension ?? format.rawValue),
                                         in: item.category) else {
                importError = "“\(item.displayTitle)” couldn’t be converted to \(format.name)."
                continue
            }
            copy.sourceAddress = item.sourceAddress
            link(copy, to: item)
            made.append(copy)
        }
        save()
        runSearch()
        if let last = made.last { selection = last }
        Task {
            for item in made {
                await fillContentHash(of: item)
                await fillThumbnail(of: item)
                await extractText(from: item)
            }
        }
    }

    /// The picture the right way up (its orientation applied), full size.
    static func uprightImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func apply(_ change: PictureChange, to image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        switch change {
        case .crop(let x, let y, let cropWidth, let cropHeight):
            return image.cropping(to: CGRect(x: x, y: y, width: cropWidth, height: cropHeight))
        case .fit(let maxDimension):
            let size = PictureGeometry.fitting(width: Double(width), height: Double(height), maxDimension: Double(maxDimension))
            guard size.width != width || size.height != height else { return image }
            return draw(width: size.width, height: size.height) { context in
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
        case .rotateLeft, .rotateRight:
            return draw(width: height, height: width) { context in
                if case .rotateRight = change {
                    context.translateBy(x: 0, y: CGFloat(width))
                    context.rotate(by: -.pi / 2)
                } else {
                    context.translateBy(x: CGFloat(height), y: 0)
                    context.rotate(by: .pi / 2)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        case .flipHorizontal, .flipVertical:
            return draw(width: width, height: height) { context in
                if case .flipHorizontal = change {
                    context.translateBy(x: CGFloat(width), y: 0)
                    context.scaleBy(x: -1, y: 1)
                } else {
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(context)
        return context.makeImage()
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
