import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import PDFKit
import UniformTypeIdentifiers
import Vision
import StashCore

/// The searchable words inside documents and web pages.
enum TextExtractor {
    static let maxLength = 200_000

    /// Text from a PDF, an EPUB book, a text or RTF file, or -- read with the Vision
    /// framework -- an image. Empty for anything else.
    static func text(fromFileAt url: URL, type: UTType?) async -> String {
        await Task.detached(priority: .utility) {
            let text: String
            if type?.conforms(to: .pdf) == true {
                text = TextExtractor.pdfText(at: url)
            } else if type?.conforms(to: .rtf) == true {
                text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
            } else if type?.conforms(to: .plainText) == true {
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            } else if type?.conforms(to: .epub) == true {
                text = (try? EPUBDocument(url: url))?.text(limit: TextExtractor.maxLength) ?? ""
            } else if type?.conforms(to: .image) == true {
                // Its words, then what it's a picture of, so "dog" finds a photo of one.
                text = [TextExtractor.recognizeText(inImageAt: url),
                        TextExtractor.contents(of: VNImageRequestHandler(url: url))].filter { !$0.isEmpty }.joined(separator: "\n")
            } else {
                text = ""
            }
            return String(text.prefix(TextExtractor.maxLength))
        }.value
    }

    /// A PDF's text; for a scan with no text in it, the words read from
    /// its pages' pictures (the first 50 pages).
    private static func pdfText(at url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        let text = document.string ?? ""
        // A couple of characters a page is a scan's page numbers at most.
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 * max(document.pageCount, 1) else {
            return text
        }
        var read: [String] = []
        for index in 0..<min(document.pageCount, 50) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2000 / max(bounds.width, bounds.height, 1)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            #if canImport(UIKit)
            guard let image = page.thumbnail(of: size, for: .mediaBox).cgImage else { continue }
            #else
            guard let image = page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            #endif
            read.append(ScannedPDF.recognizedLines(in: image).map(\.text).joined(separator: "\n"))
        }
        let recognized = read.joined(separator: "\n\n")
        return recognized.count > text.count ? recognized : text
    }

    /// What a picture shows, as words ("dog", "beach", "document"): the
    /// things Vision is fairly sure of. Searched like any other text.
    static func contents(of handler: VNImageRequestHandler) -> String {
        let request = VNClassifyImageRequest()
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? [])
            .filter { $0.confidence > 0.35 }
            .prefix(10)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")
    }

    /// Words in a picture: printed, or written by hand; then what it shows.
    static func recognizeText(inImage data: Data) -> String {
        let shows = contents(of: VNImageRequestHandler(data: data))
        let words = readWords(inImage: data)
        return [words, shows].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func readWords(inImage data: Data) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(data: data).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func recognizeText(inImageAt url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(url: url).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Downloads a web page and pulls out its title, summary and words.
    /// Nil if it can't be fetched or isn't HTML.
    /// The page's text, and its HTML (for its metadata).
    static func pageAndHTML(at url: URL) async -> (PageText, String)? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let download = try? await URLSession.shared.data(for: request),
              download.1.mimeType?.contains("html") == true else { return nil }
        let html = String(data: download.0, encoding: .utf8) ?? String(decoding: download.0, as: UTF8.self)
        return (HTMLText.extract(from: html), html)
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func page(at url: URL) async -> PageText? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Some sites send a stripped-down page, or nothing, to unknown clients.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let download = try? await URLSession.shared.data(for: request),
              download.1.mimeType?.contains("html") == true else { return nil }
        let data = download.0
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return HTMLText.extract(from: html)
    }
}
