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

    /// Text from a PDF, a text or RTF file, or -- read with the Vision
    /// framework -- an image. Empty for anything else.
    static func text(fromFileAt url: URL, type: UTType?) async -> String {
        await Task.detached(priority: .utility) {
            let text: String
            if type?.conforms(to: .pdf) == true {
                text = PDFDocument(url: url)?.string ?? ""
            } else if type?.conforms(to: .rtf) == true {
                text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
            } else if type?.conforms(to: .plainText) == true {
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            } else if type?.conforms(to: .image) == true {
                text = TextExtractor.recognizeText(inImageAt: url)
            } else {
                text = ""
            }
            return String(text.prefix(TextExtractor.maxLength))
        }.value
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
