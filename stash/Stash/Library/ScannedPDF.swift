import CoreGraphics
import CoreText
import Foundation
import Vision

/// Turns photographed pages into a PDF you can search and select text in:
/// each page is the picture, with the words Vision reads from it laid
/// invisibly on top, where they appear -- as a scanner's "searchable PDF".
enum ScannedPDF {
    /// Letter width; each page keeps its picture's proportions.
    private static let pageWidth: CGFloat = 612

    static func make(pages: [CGImage]) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
            for image in pages {
                let scale = pageWidth / CGFloat(max(image.width, 1))
                var box = CGRect(x: 0, y: 0, width: pageWidth, height: CGFloat(image.height) * scale)
                context.beginPage(mediaBox: &box)
                context.draw(image, in: box)
                for line in recognizedLines(in: image) {
                    draw(line.text, in: line.box.applying(CGAffineTransform(scaleX: box.width, y: box.height)), on: context)
                }
                context.endPage()
            }
            context.closePDF()
            return data as Data
        }.value
    }

    /// Words read from a picture, each line with its box as fractions of
    /// the picture, origin at the bottom left (as PDF pages count).
    static func recognizedLines(in image: CGImage) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return (text, observation.boundingBox)
        }
    }

    /// Invisible text, stretched to cover the words in the picture, so
    /// selecting it selects them.
    private static func draw(_ text: String, in rect: CGRect, on context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = CGAffineTransform(scaleX: rect.width / CGFloat(width), y: 1)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
