import Foundation

// Reading documents. The app turns each page into words with positions (from
// the PDF's own text, or from on-device text recognition), and TextLayout
// turns those words into lines and cells. ReceiptText does the same for plain
// text (test fixtures and stored OCR text), and TextFold is the folding shared
// by extraction and search. It only uses Foundation so it can be unit-tested.

// MARK: - Lines and cells

/// A word on a page. Coordinates are fractions of the page size:
/// x from the left edge, y from the top edge.
struct TextToken: Equatable {
    var text: String
    var page: Int
    var x0: Double
    var x1: Double
    /// Vertical centre.
    var y: Double
    var height: Double
}

/// Words that sit close together on a line, e.g. "SONY WH-1000XM5" or "1,234.56".
struct TextCell: Equatable {
    var text: String
    var x0: Double
    var x1: Double
    var center: Double { (x0 + x1) / 2 }
}

struct TextLine: Equatable {
    var page: Int
    var y: Double
    var cells: [TextCell]
    /// Average height of the line's words, as a fraction of the page height.
    var height: Double = 0
    var text: String { cells.map(\.text).joined(separator: " ") }
}

enum TextLayout {
    /// Groups words into lines (same height on the page) and lines into cells
    /// (words separated by less than about one character width).
    static func lines(from tokens: [TextToken]) -> [TextLine] {
        var result: [TextLine] = []
        let byPage = Dictionary(grouping: tokens.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }, by: \.page)
        for page in byPage.keys.sorted() {
            var groups: [(y: Double, height: Double, tokens: [TextToken])] = []
            for t in byPage[page]!.sorted(by: { $0.y < $1.y }) {
                if let last = groups.last,
                   abs(t.y - last.y) < 0.5 * min(max(t.height, 0.001), max(last.height, 0.001)) {
                    var g = last
                    g.tokens.append(t)
                    let n = Double(g.tokens.count)
                    g.y = (g.y * (n - 1) + t.y) / n
                    g.height = (g.height * (n - 1) + t.height) / n
                    groups[groups.count - 1] = g
                } else {
                    groups.append((t.y, t.height, [t]))
                }
            }
            for g in groups {
                let words = g.tokens.sorted { $0.x0 < $1.x0 }
                var cells: [TextCell] = []
                let gapLimit = 0.9 * g.height
                for w in words {
                    if var last = cells.last, w.x0 - last.x1 < gapLimit {
                        last.text += " " + w.text
                        last.x1 = max(last.x1, w.x1)
                        cells[cells.count - 1] = last
                    } else {
                        cells.append(TextCell(text: w.text, x0: w.x0, x1: w.x1))
                    }
                }
                result.append(TextLine(page: page, y: g.y, cells: cells, height: g.height))
            }
        }
        return result
    }
}

// MARK: - Plain text

/// Plain text as lines, for fixtures and for text stored without positions.
/// A tab or a run of two or more spaces separates cells; a single space stays
/// inside a cell. Every character is 1/48 of the page width.
enum ReceiptText {
    /// Characters across the page.
    static let columns = 48.0
    /// Height given to every line.
    static let lineHeight = 0.02

    /// One line per non-blank line of `text`, all on page 0, spread evenly down it.
    static func lines(from text: String) -> [TextLine] {
        let rows = text.split(whereSeparator: { $0.isNewline })
            .map { splitCells(String($0)) }
            .filter { !$0.isEmpty }
        let n = Double(rows.count)
        var result: [TextLine] = []
        for (i, cells) in rows.enumerated() {
            result.append(TextLine(page: 0, y: Double(i) / n, cells: cells, height: lineHeight))
        }
        return result
    }

    /// Cells joined by two spaces and lines by '\n', so `lines(from:)` reads the
    /// same cells back. Stored as the item's OCR text.
    static func plainText(_ lines: [TextLine]) -> String {
        lines.map { $0.cells.map(\.text).joined(separator: "  ") }.joined(separator: "\n")
    }

    private static func splitCells(_ line: String) -> [TextCell] {
        let chars = Array(line)
        var cells: [TextCell] = []
        var start: Int? = nil   // first character of the current cell
        var end = 0             // one past its last non-blank character
        var i = 0
        while i < chars.count {
            guard isBlank(chars[i]) else {
                if start == nil { start = i }
                i += 1
                end = i
                continue
            }
            var j = i
            var hasTab = false
            while j < chars.count, isBlank(chars[j]) {
                if chars[j] == "\t" { hasTab = true }
                j += 1
            }
            if let s = start, hasTab || j - i >= 2 {
                cells.append(cell(chars, from: s, to: end))
                start = nil
            }
            i = j
        }
        if let s = start {
            cells.append(cell(chars, from: s, to: end))
        }
        return cells
    }

    private static func cell(_ chars: [Character], from s: Int, to e: Int) -> TextCell {
        TextCell(text: String(chars[s..<e]),
                 x0: min(Double(s) / columns, 1),
                 x1: min(Double(e) / columns, 1))
    }

    /// Spaces and tabs (including no-break and thin spaces), not line breaks.
    private static func isBlank(_ c: Character) -> Bool {
        c.isWhitespace && !c.isNewline
    }
}

// MARK: - Folding

/// Text folded for matching: lowercase, no accents, one space between words.
/// Keyword lists are stored already folded, so matching is a plain comparison.
enum TextFold {
    /// "Müller Crème STRASSE Straße" -> "muller creme strasse strasse".
    static func fold(_ s: String) -> String {
        var replaced = ""
        replaced.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "ß", "ẞ": replaced += "ss"
            case "æ", "Æ": replaced += "ae"
            case "œ", "Œ": replaced += "oe"
            case "’", "‘": replaced += "'"
            case "\u{00A0}", "\u{202F}", "\u{2009}": replaced += " "
            default: replaced.append(c)
            }
        }
        let folded = replaced
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The German spelling without umlauts, folded: "Müller" -> "mueller".
    /// Works on the original text, before the accents are gone.
    static func umlautVariant(_ s: String) -> String {
        var replaced = ""
        replaced.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "ä": replaced += "ae"
            case "ö": replaced += "oe"
            case "ü": replaced += "ue"
            case "Ä": replaced += "Ae"
            case "Ö": replaced += "Oe"
            case "Ü": replaced += "Ue"
            default: replaced.append(c)
            }
        }
        return fold(replaced)
    }

    /// Folded words: letters and digits, split on everything else.
    static func words(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { String($0) }
    }

    /// True when `word` (a folded word or phrase) appears in `folded` with no
    /// letter or digit directly before or after it: "coop" is not in "cooper street".
    static func containsWord(_ folded: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var from = folded.startIndex
        while from < folded.endIndex,
              let r = folded.range(of: word, options: .literal, range: from..<folded.endIndex) {
            let before = folded[..<r.lowerBound].last
            let after = folded[r.upperBound...].first
            if !isWordCharacter(before) && !isWordCharacter(after) { return true }
            from = folded.index(after: r.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c = c else { return false }
        return c.isLetter || c.isNumber
    }
}
