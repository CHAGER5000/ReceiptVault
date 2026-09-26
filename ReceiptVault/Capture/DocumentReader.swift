import Foundation
import PDFKit
import Vision
import UIKit

/// Turns PDFs, scans and photos into positioned words for ReceiptExtractor.
/// Everything happens on the phone: PDF text is read with PDFKit, and images
/// are read with Apple's Vision text recognition, which runs on-device.
enum DocumentReader {
    struct Output {
        var lines: [TextLine]
        var pages: Int
        /// True when at least one page had to be read from an image.
        var usedOCR: Bool
    }

    /// Scanned PDF pages read with text recognition: the first 8 and the last 2.
    /// The shop, date, total and terms are there, and a long scan stays quick.
    private static let leadingOCRPages = 8
    private static let trailingOCRPages = 2

    /// PDFs from shops and e-mail usually contain their text, which is read exactly.
    /// Pages without text (scanned PDFs) are read with text recognition.
    static func read(pdf url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else { throw AppError.message("That PDF could not be opened.") }
            if doc.isLocked {
                throw AppError.message("That PDF is password-protected. Open it in Files, remove the password and try again.")
            }
            let count = doc.pageCount
            var tokens: [TextToken] = []
            var usedOCR = false
            for i in 0..<count {
                // A rendered page is a large image; release it before the next page.
                try autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let pageTokens = textTokens(page: page, index: i)
                    if pageTokens.count < 8, recognises(page: i, of: count), let image = render(page) {
                        let recognised = try recognise(image, page: i)
                        if recognised.isEmpty {
                            // Keep the text layer's few words when nothing could be recognised.
                            tokens += pageTokens
                        } else {
                            usedOCR = true
                            tokens += recognised
                        }
                    } else {
                        // A page with its text, or a page outside the recognised ones:
                        // whatever text it has is kept rather than dropped.
                        tokens += pageTokens
                    }
                }
                progress(Double(i + 1) / Double(max(count, 1)))
            }
            return Output(lines: TextLayout.lines(from: tokens), pages: count, usedOCR: usedOCR)
        }.value
    }

    /// Camera scans and photos. The images are drawn upright as CGImages first,
    /// so no UIImage crosses into the background task.
    static func read(images: [UIImage], progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let cgImages = images.compactMap(upright)
        return try await Task.detached(priority: .userInitiated) {
            var tokens: [TextToken] = []
            for (i, image) in cgImages.enumerated() {
                tokens += try autoreleasepool { try recognise(image, page: i) }
                progress(Double(i + 1) / Double(max(cgImages.count, 1)))
            }
            return Output(lines: TextLayout.lines(from: tokens), pages: cgImages.count, usedOCR: true)
        }.value
    }

    /// True for page indexes 0..<8 and the last 2 pages of the document.
    private static func recognises(page index: Int, of count: Int) -> Bool {
        index < DocumentReader.leadingOCRPages || index >= count - DocumentReader.trailingOCRPages
    }

    // MARK: PDF text

    /// Words with their positions, built from each character's bounds.
    private static func textTokens(page: PDFPage, index: Int) -> [TextToken] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let ns = string as NSString
        var tokens: [TextToken] = []
        var text = ""
        var rect = CGRect.null

        func flush() {
            if !text.isEmpty, !rect.isNull, rect.height > 0 {
                tokens.append(TextToken(
                    text: text, page: index,
                    x0: Double((rect.minX - bounds.minX) / bounds.width),
                    x1: Double((rect.maxX - bounds.minX) / bounds.width),
                    y: Double(1 - (rect.midY - bounds.minY) / bounds.height),
                    height: Double(rect.height / bounds.height)))
            }
            text = ""
            rect = .null
        }

        for i in 0..<ns.length {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
                continue
            }
            let r = page.characterBounds(at: i)
            if r.isEmpty || r.height <= 0 { continue }
            if !rect.isNull {
                let sameLine = abs(r.midY - rect.midY) < rect.height * 0.5
                let close = r.minX - rect.maxX < rect.height * 0.35 && r.minX >= rect.minX - rect.height
                if !(sameLine && close) { flush() }
            }
            text += ch
            rect = rect.isNull ? r : rect.union(r)
        }
        flush()
        return tokens
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let size = page.bounds(for: .mediaBox).size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = 2400 / max(size.width, size.height)
        let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
        return image.cgImage
    }

    // MARK: Text recognition

    private static func recognise(_ image: CGImage, page: Int) throws -> [TextToken] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" merchant names and numbers; keep what is printed.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "de-DE", "fr-FR", "it-IT"]
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

        var tokens: [TextToken] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            let whole = observation.boundingBox
            let length = max(string.count, 1)
            for range in wordRanges(string) {
                let word = String(string[range])
                var box: CGRect
                if let b = try? candidate.boundingBox(for: range)?.boundingBox, b.width > 0 {
                    box = b
                } else {
                    // Fall back to the word's share of the line.
                    let start = string.distance(from: string.startIndex, to: range.lowerBound)
                    let end = string.distance(from: string.startIndex, to: range.upperBound)
                    box = CGRect(x: whole.minX + whole.width * CGFloat(start) / CGFloat(length), y: whole.minY,
                                 width: whole.width * CGFloat(end - start) / CGFloat(length), height: whole.height)
                }
                // Vision uses a bottom-left origin.
                tokens.append(TextToken(text: word, page: page, x0: Double(box.minX), x1: Double(box.maxX),
                                        y: Double(1 - box.midY), height: Double(whole.height)))
            }
        }
        return tokens
    }

    private static func wordRanges(_ s: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let st = start { ranges.append(st..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = s.index(after: i)
        }
        if let st = start { ranges.append(st..<s.endIndex) }
        return ranges
    }

    /// Photos can carry a rotation flag; draw them upright first.
    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let drawn = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return drawn.cgImage
    }
}
