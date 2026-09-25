import Foundation

// MARK: - Money

/// Amounts are stored as integer minor units (pence, cents, Rappen) so sums
/// are exact. All supported currencies have two decimal places.
enum Money {
    static let supportedCurrencies = ["GBP", "CHF", "EUR", "USD"]

    static func minor(from value: Decimal) -> Int64 {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func decimal(fromMinor minor: Int64) -> Decimal {
        Decimal(minor) / 100
    }

    /// "1234.50" style, for CSV exports and form fields.
    static func plain(_ minor: Int64) -> String {
        let sign = minor < 0 ? "-" : ""
        let a = minor.magnitude
        let frac = a % 100
        return "\(sign)\(a / 100).\(frac < 10 ? "0" : "")\(frac)"
    }

    /// Display only. ICU output differs between macOS and iOS, so tests never assert it.
    static func format(_ minor: Int64, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: localeID(for: currency))
        return f.string(from: NSDecimalNumber(decimal: decimal(fromMinor: minor))) ?? "\(plain(minor)) \(currency)"
    }

    /// VAT rates are stored in permille: 200 -> "20", 81 -> "8.1", 25 -> "2.5", 0 -> "0".
    static func percent(permille: Int) -> String {
        let sign = permille < 0 ? "-" : ""
        let a = permille.magnitude
        let tenths = a % 10
        return tenths == 0 ? "\(sign)\(a / 10)" : "\(sign)\(a / 10).\(tenths)"
    }

    private static func localeID(for currency: String) -> String {
        switch currency {
        case "CHF": return "de_CH"
        case "EUR": return "en_IE"
        case "USD": return "en_US"
        default: return "en_GB"
        }
    }
}

// MARK: - AmountParser

/// Parses amounts as they appear in UK, Swiss and euro-zone statements:
/// "£1,234.56", "-12.30", "12.30 DR", "(12.30)", "1'234.50", "1.234,56", "12.30-".
enum AmountParser {
    static func parse(_ raw: String) -> Decimal? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        var negative = false

        let upper = s.uppercased()
        if upper.hasSuffix("DR") || upper.hasSuffix("DB") {
            negative = true
            s = String(s.dropLast(2))
        } else if upper.hasSuffix("CR") {
            s = String(s.dropLast(2))
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }

        // Keep digits, separators and signs only (drops £, €, CHF, spaces).
        let allowed = Set("0123456789.,-+'’")
        s = String(s.filter { allowed.contains($0) })
        if s.hasPrefix("+") { s.removeFirst() }
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() }
        if s.hasSuffix("-") { negative.toggle(); s.removeLast() }
        s = s.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        if s.isEmpty || s.contains("-") || s.contains("+") { return nil }

        let lastDot = s.lastIndex(of: ".")
        let lastComma = s.lastIndex(of: ",")
        var normalized: String
        switch (lastDot, lastComma) {
        case let (d?, c?):
            if d > c { // 1,234.56
                normalized = s.replacingOccurrences(of: ",", with: "")
            } else {   // 1.234,56
                normalized = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            }
        case (nil, let c?):
            let commas = s.filter { $0 == "," }.count
            let after = s.distance(from: s.index(after: c), to: s.endIndex)
            if commas == 1 && after != 3 { // 12,5 or 12,50 -> decimal comma
                normalized = s.replacingOccurrences(of: ",", with: ".")
            } else {                       // 1,234 or 1,234,567 -> thousands
                normalized = s.replacingOccurrences(of: ",", with: "")
            }
        case (_?, nil):
            let dots = s.filter { $0 == "." }.count
            normalized = dots > 1 ? s.replacingOccurrences(of: ".", with: "") : s
        case (nil, nil):
            normalized = s
        }

        guard isPlainNumber(normalized),
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -value : value
    }

    private static func isPlainNumber(_ s: String) -> Bool {
        var seenDot = false
        var digits = 0
        for ch in s {
            if ch == "." {
                if seenDot { return false }
                seenDot = true
            } else if ch.isASCII && ch.isNumber {
                digits += 1
            } else {
                return false
            }
        }
        return digits > 0
    }
}

// MARK: - Receipt amounts

/// An amount read from a receipt. `minor` is signed: negative when `isNegative`.
struct ReceiptAmount: Equatable {
    var minor: Int64
    var currency: String?
    var isNegative: Bool
}

/// Reads amount tokens as printed on UK, Swiss and euro-zone receipts:
/// "£12.50", "12.50 A", "CHF 1'249.00", "1 249,00 €", "Fr. 12.–", "5.00-".
/// Exactly two decimals are required, which keeps dates, times, phone numbers,
/// quantities and rates out.
enum ReceiptAmountParser {
    /// Currency markers stripped from a token, longest first where they overlap.
    private static let markers = ["SFr.", "Fr.", "US$", "USD", "CHF", "GBP", "EUR", "£", "€", "$"]

    /// Letters (and '*') printed after an amount to show its VAT rate.
    private static let vatCodes = "ABCDESZ*"

    /// Swiss whole amounts: "12.–", "12.-", "12,--" -> "12.00".
    private static let swissDash = try! NSRegularExpression(pattern: #"(\d)[.,][-–—]{1,2}(?!\d)"#)

    /// Space thousands separators are accepted only with a decimal comma.
    private static let amountShape = try! NSRegularExpression(
        pattern: #"^-?(?:\d{1,3}(?:[,'’.]\d{3})+|\d{1,3}(?: \d{3})+(?=,)|\d+)[.,]\d{2}-?$"#)

    /// Currency markers in running text; "Fr."/"SFr." are checked for a following amount.
    private static let currencyMarker = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:SFr\.|Fr\.|US\$|USD|CHF|GBP|EUR)(?!\p{L})|(?<!\p{L})\$|£|€"#,
        options: [.caseInsensitive])

    /// Narrow and thin spaces become plain spaces; the Swiss dash becomes ".00".
    /// Runs before any sign handling, so "12.-" is never read as negative.
    static func normalise(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
        let range = NSRange(location: 0, length: (spaced as NSString).length)
        return swissDash.stringByReplacingMatches(in: spaced, range: range, withTemplate: "$1.00")
    }

    /// ISO 4217 code for a printed currency marker, or nil.
    static func currencyCode(forSymbol s: String) -> String? {
        switch s.trimmingCharacters(in: .whitespaces).uppercased() {
        case "£", "GBP": return "GBP"
        case "€", "EUR": return "EUR"
        case "CHF", "FR.", "SFR.": return "CHF"
        case "$", "US$", "USD": return "USD"
        default: return nil
        }
    }

    /// One amount token (it may contain spaces, as in "CHF 1'249.00" or "1 249,00 €").
    static func parse(_ token: String, fromOCR: Bool = false) -> ReceiptAmount? {
        var s = normalise(token)
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.contains("%") || s.contains(":") { return nil }

        // Record the first currency marker, then strip them all.
        var currency: String? = nil
        var firstAt = s.endIndex
        for m in markers {
            if let r = s.range(of: m, options: .caseInsensitive), r.lowerBound < firstAt {
                firstAt = r.lowerBound
                currency = currencyCode(forSymbol: m)
            }
        }
        for m in markers {
            s = s.replacingOccurrences(of: m, with: "", options: .caseInsensitive)
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // A trailing VAT code after a space or digit: "12.50 A", "12.50*".
        if s.count >= 2, let last = s.last, vatCodes.contains(last) {
            let prev = s[s.index(s.endIndex, offsetBy: -2)]
            if prev == " " || (prev.isASCII && prev.isNumber) {
                s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }

        if fromOCR && !matchesShape(s) && s.filter({ $0.isNumber }).count >= 2 {
            let fixed = fixSlips(s)
            if matchesShape(fixed) { s = fixed }
        }
        guard matchesShape(s) else { return nil }

        let signFirst = s.hasPrefix("-")
        let signLast = s.hasSuffix("-")
        if signFirst && signLast { return nil }

        // Thousands and decimal separators must differ ("1.249.00" is not money).
        let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let separator = body[body.index(body.endIndex, offsetBy: -3)]
        if body.dropLast(3).contains(separator) { return nil }

        guard let value = AmountParser.parse(s) else { return nil }
        return ReceiptAmount(minor: Money.minor(from: value), currency: currency, isNegative: signFirst || signLast)
    }

    /// The amount at the end of a line and the label before it. Tries the last
    /// 3, then 2, then 1 whitespace tokens; the longest that parses wins.
    static func trailing(in line: String, fromOCR: Bool = false) -> (amount: ReceiptAmount, label: String)? {
        let tokens = whitespaceTokens(line)
        guard !tokens.isEmpty else { return nil }
        for k in stride(from: min(3, tokens.count), through: 1, by: -1) {
            let candidate = tokens.suffix(k).joined(separator: " ")
            if let amount = parse(candidate, fromOCR: fromOCR) {
                return (amount: amount, label: labelText(tokens.dropLast(k)))
            }
        }
        return nil
    }

    /// Every amount in the line, in reading order.
    static func all(in line: String, fromOCR: Bool = false) -> [ReceiptAmount] {
        let tokens = whitespaceTokens(line)
        var found: [ReceiptAmount] = []
        var i = 0
        while i < tokens.count {
            var used = 1
            for k in stride(from: min(3, tokens.count - i), through: 1, by: -1) {
                let candidate = tokens[i..<(i + k)].joined(separator: " ")
                if let amount = parse(candidate, fromOCR: fromOCR) {
                    found.append(amount)
                    used = k
                    break
                }
            }
            i += used
        }
        return found
    }

    /// ISO codes of every currency marker, in order of appearance (repeats kept,
    /// so callers can take the majority). "Fr."/"SFr." count only when an amount
    /// follows, so "Fr. 12.03.2025" (Freitag) is not francs.
    static func currencies(in text: String) -> [String] {
        let s = normalise(text)
        let ns = s as NSString
        var codes: [String] = []
        for m in currencyMarker.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let marker = ns.substring(with: m.range)
            guard let code = currencyCode(forSymbol: marker) else { continue }
            if marker.lowercased().hasSuffix("fr.") {
                let end = NSMaxRange(m.range)
                let rest = ns.substring(with: NSRange(location: end, length: min(40, ns.length - end)))
                guard amountFollows(rest) else { continue }
            }
            codes.append(code)
        }
        return codes
    }

    // MARK: Helpers

    private static func matchesShape(_ s: String) -> Bool {
        amountShape.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Common text-recognition slips, fixed only in pieces that already hold a digit.
    private static func fixSlips(_ s: String) -> String {
        let pieces = s.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            guard piece.contains(where: { $0.isNumber }) else { return String(piece) }
            return String(piece.map { c -> Character in
                switch c {
                case "O", "o": return "0"
                case "l", "I", "|", "i": return "1"
                case "S": return "5"
                case "B": return "8"
                default: return c
                }
            })
        }
        return pieces.joined(separator: " ")
    }

    private static func whitespaceTokens(_ line: String) -> [String] {
        normalise(line).split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    /// The label before an amount, trimmed, without a trailing ':'.
    private static func labelText(_ parts: ArraySlice<String>) -> String {
        var t = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(":") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// True when `rest` starts, after at most one space, with an amount of one or two tokens.
    private static func amountFollows(_ rest: String) -> Bool {
        var s = Substring(rest)
        if let f = s.first, f.isWhitespace { s = s.dropFirst() }
        guard let c = s.first, c.isASCII, c.isNumber else { return false }
        let pieces = s.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        let trim = CharacterSet(charactersIn: ".,;)")
        let first = String(pieces[0]).trimmingCharacters(in: trim)
        if parse(first) != nil { return true }
        guard pieces.count > 1 else { return false }
        let second = String(pieces[1]).trimmingCharacters(in: trim)
        return parse(first + " " + second) != nil
    }
}
