import Foundation

// Text that powers search or leaves the app. SearchText builds each item's
// pre-folded search blob and matches queries against it; ItemCSV writes
// 'ReceiptVault CSV v1' with LocalLedger's escaping and Money.plain amounts;
// EvidenceSummary lays out the evidence PDF cover as styled lines. Amounts are
// written as Money.plain plus the ISO code and dates as ISO days, so the output
// is the same on every device. It only uses Foundation so it can be unit-tested.

// MARK: - Search

/// A parsed search: words that must all appear as word prefixes, plus
/// optional bounds on the total in minor units.
struct SearchQuery: Equatable {
    var words: [String]
    var minMinor: Int64?
    var maxMinor: Int64?
    /// Nothing to filter on, so every item matches.
    var isEmpty: Bool { words.isEmpty && minMinor == nil && maxMinor == nil }
}

/// Search over a blob that is folded once, when the item is saved: case,
/// accents, 'ß' and German umlaut spellings, so Müller = Muller = Mueller.
/// The blob starts and ends with a space and has one space between tokens,
/// so a word prefix is a plain `contains(" " + word)`.
enum SearchText {
    /// OCR text beyond this many characters is left out of the blob.
    static let maxOCRCharacters = 20_000

    /// Trimmed from both ends of every token. ’ and ‘ are already ' after folding.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?()[]{}\"'«»“”„")

    /// Signs that start a lower or an upper amount bound: '>500', '<= 20'.
    private static let lowerSigns = [">=", "≥", ">"]
    private static let upperSigns = ["<=", "≤", "<"]

    /// Currency markers allowed around an amount in a query ('>£500', '<20chf').
    private static let currencyMarks = ["£", "€", "$", "chf", "gbp", "eur", "usd"]

    /// Folded month names in English, German, French and Italian, January first.
    /// Arrays, not sets, so a repeated name can never crash at launch.
    private static let monthNames: [[String]] = [
        ["january", "januar", "janvier", "gennaio", "janner", "jaenner"],
        ["february", "februar", "fevrier", "febbraio"],
        ["march", "marz", "maerz", "mars", "marzo"],
        ["april", "avril", "aprile"],
        ["may", "mai", "maggio"],
        ["june", "juni", "juin", "giugno"],
        ["july", "juli", "juillet", "luglio"],
        ["august", "aout", "agosto"],
        ["september", "septembre", "settembre"],
        ["october", "oktober", "octobre", "ottobre"],
        ["november", "novembre"],
        ["december", "dezember", "decembre", "dicembre"],
    ]

    /// Folded words split on whitespace, with punctuation trimmed from both
    /// ends: "Müller, Zürich (CH)" -> ["muller", "zurich", "ch"].
    static func tokens(_ s: String) -> [String] {
        TextFold.fold(s)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: SearchText.edgePunctuation) }
            .filter { !$0.isEmpty }
    }

    /// ' ' + the tokens of every part, plus their umlaut spellings when they
    /// differ ("Müller" also gives "mueller"), joined by ' ' + ' '. A token
    /// that is already in the blob is not repeated.
    static func blob(_ parts: [String]) -> String {
        var seen = Set<String>()
        var words: [String] = []
        for part in parts {
            let plain = SearchText.tokens(part)
            let variant = SearchText.tokens(TextFold.umlautVariant(part))
            let all = variant == plain ? plain : plain + variant
            for w in all {
                if seen.insert(w).inserted { words.append(w) }
            }
        }
        return " " + words.joined(separator: " ") + " "
    }

    /// The ways an amount is typed: 24900 -> ["249.00", "249,00", "249"].
    /// The whole-number form is only given for whole amounts; refunds are
    /// found by their size.
    static func amountTerms(_ minor: Int64) -> [String] {
        let value = minor == Int64.min ? Int64.max : abs(minor)
        let plain = Money.plain(value)
        let comma = plain.replacingOccurrences(of: ".", with: ",")
        if value % 100 == 0 {
            return [plain, comma, String(value / 100)]
        }
        return [plain, comma]
    }

    /// The ways a day is typed: "2025-03-12", "12.03.2025", "12/03/2025",
    /// "2025", "12.3.2025" (when it differs) and the month's folded names in
    /// English, German, French and Italian.
    static func dateTerms(_ d: DayDate) -> [String] {
        let dd = SearchText.pad(d.day)
        let mm = SearchText.pad(d.month)
        let yyyy = String(d.year)
        var terms = [d.iso, "\(dd).\(mm).\(yyyy)", "\(dd)/\(mm)/\(yyyy)", yyyy]
        let short = "\(d.day).\(d.month).\(yyyy)"
        if !terms.contains(short) { terms.append(short) }
        if (1...12).contains(d.month) {
            for name in SearchText.monthNames[d.month - 1] where !terms.contains(name) {
                terms.append(name)
            }
        }
        return terms
    }

    /// Reads a search field. '>500' sets a minimum of 50000, '<20' a maximum
    /// of 2000 and '50-200' both ('> 500' with a space works too). Every
    /// other token becomes a word. "2025-03" stays a word, because a side
    /// with a leading zero, or a range that runs backwards, is not an amount.
    static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery(words: [], minMinor: nil, maxMinor: nil)
        let parts = SearchText.tokens(raw)
        var i = 0
        while i < parts.count {
            let t = parts[i]
            let isLower = SearchText.lowerSigns.contains(t)
            let isUpper = SearchText.upperSigns.contains(t)
            if isLower || isUpper {
                // A sign on its own: take the amount after it, or drop it while
                // the user is still typing.
                if i + 1 < parts.count, let value = SearchText.amount(parts[i + 1]) {
                    if isLower { query.minMinor = value } else { query.maxMinor = value }
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if let value = SearchText.bound(t, signs: SearchText.lowerSigns) {
                query.minMinor = value
            } else if let value = SearchText.bound(t, signs: SearchText.upperSigns) {
                query.maxMinor = value
            } else if let r = SearchText.amountRange(t) {
                query.minMinor = r.low
                query.maxMinor = r.high
            } else {
                query.words.append(t)
            }
            i += 1
        }
        return query
    }

    /// True when every word starts a token of `blob` and the total is within
    /// the bounds. Bounds need a total, so an item without one never matches
    /// them; like amount terms, they compare the total's size, so a 600.00
    /// refund is not found by '<20'. A word also matches the total's own
    /// amount terms, so amounts are found even in a blob built without them
    /// (and with a currency marker: '£249' finds a 249.00 total).
    /// An empty query matches everything.
    static func matches(_ q: SearchQuery, blob: String, totalMinor: Int64?) -> Bool {
        if q.isEmpty { return true }
        if q.minMinor != nil || q.maxMinor != nil {
            guard let signed = totalMinor else { return false }
            let total: Int64 = signed == Int64.min ? Int64.max : abs(signed)
            if let low = q.minMinor, total < low { return false }
            if let high = q.maxMinor, total > high { return false }
        }
        let totalTerms: [String] = totalMinor.map { SearchText.amountTerms($0) } ?? []
        for w in q.words {
            if blob.contains(" " + w) { continue }
            let bare: String = SearchText.withoutCurrency(w)
            if !bare.isEmpty, totalTerms.contains(where: { $0.hasPrefix(bare) }) { continue }
            return false
        }
        return true
    }

    // MARK: Helpers

    private static func pad(_ n: Int) -> String {
        n >= 0 && n < 10 ? "0\(n)" : "\(n)"
    }

    /// The amount after the first matching sign: '>500' -> 50000. Nil when no
    /// sign matches or the rest is not an amount.
    private static func bound(_ t: String, signs: [String]) -> Int64? {
        for sign in signs where t.hasPrefix(sign) {
            guard t.count > sign.count else { return nil }
            return SearchText.amount(String(t.dropFirst(sign.count)))
        }
        return nil
    }

    /// '50-200' (or with an en dash) -> 5000...20000. Nil unless both sides are
    /// amounts and the low side comes first.
    private static func amountRange(_ t: String) -> (low: Int64, high: Int64)? {
        let sides = t.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "–" })
        guard sides.count == 2,
              let low = SearchText.amount(String(sides[0])),
              let high = SearchText.amount(String(sides[1])),
              low <= high else { return nil }
        return (low: low, high: high)
    }

    /// A typed amount in minor units: "500", "12.50", "12,5", "1'000", "1.000"
    /// (a thousand), with an optional currency marker. Nil for anything else.
    private static func amount(_ raw: String) -> Int64? {
        var s = SearchText.withoutCurrency(raw)
        guard let first = s.first, first.isASCII, first.isNumber, s.count <= 16,
              s.allSatisfy({ c in (c.isASCII && c.isNumber) || c == "." || c == "," || c == "'" }) else { return nil }
        // "03" reads as a month ("2025-03"), not as money.
        if first == "0", s.count > 1, let second = s.dropFirst().first, second.isNumber { return nil }
        // "1.000" is a thousand, as typed in Germany and Switzerland.
        if !s.contains(","), let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) == 4 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard let value = AmountParser.parse(s), value >= 0 else { return nil }
        return Money.minor(from: value)
    }

    /// A folded token without a leading or trailing currency marker:
    /// '£500' -> '500', '20chf' -> '20'.
    private static func withoutCurrency(_ raw: String) -> String {
        var s = raw
        for mark in SearchText.currencyMarks {
            if s.hasPrefix(mark) { s = String(s.dropFirst(mark.count)) }
            if s.hasSuffix(mark) { s = String(s.dropLast(mark.count)) }
        }
        return s
    }
}

// MARK: - CSV

/// One item as a row of 'ReceiptVault CSV v1'.
struct ItemCSVRow: Equatable {
    var date: DayDate
    var delivered: DayDate?
    var merchant: String
    var title: String
    var kind: ItemKind
    var category: ProductCategory
    var totalMinor: Int64?
    var currency: String
    var vatMinor: Int64?
    var vatRatePermille: Int?
    var taxTag: TaxTag
    var returnBy: DayDate?
    var warrantyUntil: DayDate?
    var legalCoverUntil: DayDate?
    var noticeBy: DayDate?
    var notes: String
    var id: UUID
}

/// 'ReceiptVault CSV v1'. Days are ISO, amounts are Money.plain, the VAT rate
/// is Money.percent, and Claimable holds TaxTag labels ('' for none) exactly
/// as LocalLedger's own CSV does, so LocalLedger can read it later. The
/// header is frozen: add columns at the end, never rename or reorder them.
enum ItemCSV {
    static let header = ["Date", "Delivered", "Merchant", "Title", "Kind", "Category", "Total", "Currency", "VAT", "VAT rate %", "Claimable", "Return by", "Warranty until", "Legal cover until", "Notice by", "Notes", "ID"]

    /// The header and one line per row, sorted by date (rows on the same day
    /// keep their order). Every line, the header included, ends with '\n'.
    static func make(_ rows: [ItemCSVRow]) -> String {
        let sorted = rows.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset
        }.map { $0.element }
        var lines = [ItemCSV.header.joined(separator: ",")]
        for row in sorted {
            lines.append(ItemCSV.columns(row).map(ItemCSV.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// LocalLedger's CSVWriter.escape, plus '\r': a value with a comma, a
    /// quote or a line break is quoted, with quotes doubled. Checked by
    /// Unicode scalar, because "\r\n" is a single Character in Swift.
    static func escape(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The row's values in header order, not yet escaped.
    private static func columns(_ r: ItemCSVRow) -> [String] {
        let total = r.totalMinor.map { Money.plain($0) } ?? ""
        let vat = r.vatMinor.map { Money.plain($0) } ?? ""
        let rate = r.vatRatePermille.map { Money.percent(permille: $0) } ?? ""
        let claimable = r.taxTag == TaxTag.none ? "" : r.taxTag.label
        var cols: [String] = [r.date.iso, ItemCSV.day(r.delivered), r.merchant, r.title, r.kind.label, r.category.label]
        cols.append(contentsOf: [total, r.currency, vat, rate, claimable])
        cols.append(contentsOf: [ItemCSV.day(r.returnBy), ItemCSV.day(r.warrantyUntil), ItemCSV.day(r.legalCoverUntil), ItemCSV.day(r.noticeBy)])
        cols.append(contentsOf: [r.notes, r.id.uuidString])
        return cols
    }

    private static func day(_ d: DayDate?) -> String {
        d?.iso ?? ""
    }
}

// MARK: - Evidence summary

/// A key date on the evidence cover, e.g. 'Legal guarantee ends' with its certainty.
struct EvidenceDate: Equatable {
    var label: String
    var date: DayDate
    var certainty: Certainty
}

/// An original file on the evidence cover. `sha256` is the fingerprint
/// recorded at capture; `matchesCapture` says whether the stored bytes still
/// hash to it. `capturedAt` is the capture time, already formatted with its
/// time zone, and `source` is the FileSource label.
struct EvidenceFile: Equatable {
    var name: String
    var pages: Int
    var sha256: String
    var capturedAt: String
    var source: String
    var matchesCapture: Bool
}

/// Everything the evidence cover shows about one item.
struct EvidenceInput: Equatable {
    var title: String
    var merchant: String
    var kind: ItemKind
    var purchaseDate: DayDate
    var deliveryDate: DayDate?
    var totalMinor: Int64?
    var currency: String
    var vatMinor: Int64?
    var vatRatePermille: Int?
    var items: [ItemLine]
    var jurisdiction: Jurisdiction
    var channel: PurchaseChannel
    var hasIssue: Bool
    var issueNoted: DayDate?
    var dates: [EvidenceDate]
    var notes: String
    var files: [EvidenceFile]
}

enum EvidenceStyle: Equatable {
    case title, heading, body, small
}

/// One paragraph of the evidence cover; the app picks the font from `style`.
struct EvidenceLine: Equatable {
    var style: EvidenceStyle
    var text: String
}

/// The evidence PDF cover as styled lines, so its wording is testable without
/// drawing anything.
enum EvidenceSummary {
    static let integrityNote = "A matching fingerprint shows the file is unchanged since it was saved in ReceiptVault. It does not prove it matches the paper original, and times come from the phone's clock."

    /// Title, details, the amount line ('Total 249.00 GBP (VAT 41.50 at 20%)'),
    /// product lines, key dates with status and certainty, the fault note,
    /// notes, each file with its fingerprint check, the integrity note and the
    /// legal notes. The disclaimer is always the last line.
    static func lines(_ input: EvidenceInput, today: DayDate, notes: [LegalNote], generatedAt: String) -> [EvidenceLine] {
        var out: [EvidenceLine] = []
        func add(_ style: EvidenceStyle, _ text: String) {
            out.append(EvidenceLine(style: style, text: text))
        }

        let title = EvidenceSummary.clean(input.title)
        let merchant = EvidenceSummary.clean(input.merchant)
        if !title.isEmpty {
            add(.title, title)
        } else if !merchant.isEmpty {
            add(.title, merchant)
        } else {
            add(.title, input.kind.label)
        }
        let when = EvidenceSummary.clean(generatedAt)
        add(.small, when.isEmpty ? "Evidence summary prepared with ReceiptVault" : "Evidence summary prepared with ReceiptVault on \(when)")

        // Details
        add(.heading, "Details")
        if !merchant.isEmpty { add(.body, "Merchant: \(merchant)") }
        add(.body, "Document: \(input.kind.label)")
        let dateWord = input.kind == ItemKind.contract ? "Date" : "Purchased"
        add(.body, "\(dateWord): \(input.purchaseDate.iso)")
        if let delivered = input.deliveryDate {
            add(.body, "Delivered: \(delivered.iso)")
        }
        if input.kind != ItemKind.contract {
            add(.body, "Bought: \(input.channel.label)")
        }
        add(.body, "Rules: \(input.jurisdiction.label)")
        add(.body, EvidenceSummary.amountLine(input))

        if !input.items.isEmpty {
            add(.heading, "Items")
            for item in input.items {
                add(.body, EvidenceSummary.itemText(item, currency: input.currency))
            }
        }

        // Key dates
        if !input.dates.isEmpty {
            add(.heading, "Key dates")
            add(.small, "Status as of \(today.iso).")
            let sortedDates = input.dates.sorted { a, b in
                a.date != b.date ? a.date < b.date : a.label < b.label
            }
            for d in sortedDates {
                let label = EvidenceSummary.clean(d.label)
                let name = label.isEmpty ? "Date" : label
                let statusText = EvidenceSummary.status(of: d.date, today: today)
                add(.body, "\(name): \(d.date.iso) (\(statusText)) · Source: \(d.certainty.label)")
            }
        }

        // Fault
        if input.hasIssue {
            add(.heading, "Fault")
            if let noted = input.issueNoted {
                add(.body, "Fault noticed on \(noted.iso).")
            } else {
                add(.body, "A fault has been noted; the date was not recorded.")
            }
        }

        // Notes
        let noteLines = input.notes.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !noteLines.isEmpty {
            add(.heading, "Notes")
            for line in noteLines { add(.body, line) }
        }

        // Original files
        add(.heading, "Original files")
        if input.files.isEmpty {
            add(.body, "No original files are attached.")
        }
        for (i, file) in input.files.enumerated() {
            add(.body, EvidenceSummary.fileText(file, number: i + 1))
            if file.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nothing to compare against, so do not claim the file changed.
                add(.body, "No SHA-256 fingerprint was recorded for this file, so it cannot be checked.")
            } else if file.matchesCapture {
                add(.small, "SHA-256 \(file.sha256), matches the fingerprint taken at capture")
            } else {
                add(.body, "SHA-256 at capture \(file.sha256). WARNING: the file now DOES NOT MATCH this fingerprint, so it has changed since it was saved.")
            }
        }
        add(.small, EvidenceSummary.integrityNote)

        // Legal notes
        if !notes.isEmpty {
            add(.heading, "General information about your rights")
            for note in notes {
                add(.body, note.text)
                let basis = EvidenceSummary.clean(note.basis)
                if !basis.isEmpty {
                    let assumed = note.isAssumption ? " (\(Certainty.assumption.label))" : ""
                    add(.small, "Basis: \(basis)\(assumed)")
                }
            }
        }

        add(.small, LegalNotes.disclaimer)
        return out
    }

    /// How far `date` is from `today`: 'today', 'tomorrow', 'in 5 days',
    /// 'yesterday', '5 days ago'. Beyond 90 days it counts 30-day months:
    /// 'in 4 months', '4 months ago'.
    static func status(of date: DayDate, today: DayDate) -> String {
        let n = RVCalendar.daysBetween(today, date)
        switch n {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...90: return "in \(n) days"
        case -90 ... -2: return "\(-n) days ago"
        default: return n > 0 ? "in \(n / 30) months" : "\((-n) / 30) months ago"
        }
    }

    // MARK: Helpers

    /// 'Total 249.00 GBP (VAT 41.50 at 20%)'; the VAT part is left out, or
    /// shortened, when it is not known.
    private static func amountLine(_ input: EvidenceInput) -> String {
        let rate: String? = input.vatRatePermille.map { Money.percent(permille: $0) + "%" }
        let at = rate.map { " at " + $0 } ?? ""
        guard let total = input.totalMinor else {
            if let vat = input.vatMinor {
                return "Total not recorded (VAT \(EvidenceSummary.money(vat, input.currency))\(at))"
            }
            return "Total not recorded"
        }
        var line = "Total " + EvidenceSummary.money(total, input.currency)
        if let vat = input.vatMinor {
            line += " (VAT \(Money.plain(vat))\(at))"
        } else if let r = rate {
            line += " (VAT rate \(r))"
        }
        return line
    }

    /// '249.00 GBP', or just '249.00' without a currency.
    private static func money(_ minor: Int64, _ currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? Money.plain(minor) : "\(Money.plain(minor)) \(code)"
    }

    /// '2 × USB-C cable · 19.98 GBP'.
    private static func itemText(_ item: ItemLine, currency: String) -> String {
        let cleaned = EvidenceSummary.clean(item.name)
        let name = cleaned.isEmpty ? "Item" : cleaned
        var text = item.quantity > 1 ? "\(item.quantity) × \(name)" : name
        if let amount = item.amountMinor {
            text += " · " + EvidenceSummary.money(amount, currency)
        }
        return text
    }

    /// '1. Receipt.jpg · 1 page · Camera scan · saved 12 Mar 2025, 14:32 (Europe/London)'.
    private static func fileText(_ file: EvidenceFile, number: Int) -> String {
        let cleaned = EvidenceSummary.clean(file.name)
        let name = cleaned.isEmpty ? "File" : cleaned
        var parts: [String] = ["\(number). \(name)"]
        if file.pages > 0 {
            parts.append(file.pages == 1 ? "1 page" : "\(file.pages) pages")
        }
        let source = EvidenceSummary.clean(file.source)
        if !source.isEmpty { parts.append(source) }
        let captured = EvidenceSummary.clean(file.capturedAt)
        if !captured.isEmpty { parts.append("saved \(captured)") }
        return parts.joined(separator: " · ")
    }

    /// One line of text: trimmed, with line breaks turned into spaces.
    private static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
