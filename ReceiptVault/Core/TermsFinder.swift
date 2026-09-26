import Foundation

// Printed terms. Receipts, warranty cards and contracts often print the terms
// that decide an item's dates: "2 Jahre Garantie", "returns within 28 days",
// "Kündigungsfrist 3 Monate", "reconduction tacite". TermsFinder reads them in
// English, German, French and Italian, number words included, and the planner
// marks what it finds 'From document'. It only uses Foundation so it can be
// unit-tested.
//
// Matching works on folded words (TextFold). A count ("24", "zwei", "deux") must
// be followed within three words by a unit ("Monate", "ans") AND sit near a
// keyword ("Garantie"), so "2 Jahre alt", "garantiert frisch" and "30 days" on
// their own give nothing. Keyword lists are stored already folded.

/// Terms printed on a document. Nil means not printed, or not recognised.
struct PrintedTerms: Equatable {
    var warrantyMonths: Int? = nil
    var returnDays: Int? = nil
    var notice: NoticePeriod? = nil
    var termStart: DayDate? = nil
    var termEnd: DayDate? = nil
    var autoRenews: Bool? = nil
    var renewalMonths: Int? = nil
}

enum TermsFinder {
    // MARK: - Finders

    /// Every printed term in `text` (a whole document, lines separated by '\n').
    /// Folds the text, then runs every finder.
    static func find(in text: String) -> PrintedTerms {
        let folded = TermsFinder.foldedLines(text)
        var terms = PrintedTerms()
        terms.warrantyMonths = TermsFinder.warrantyMonths(folded)
        terms.returnDays = TermsFinder.returnDays(folded)
        terms.notice = TermsFinder.notice(folded)
        let span = TermsFinder.term(text)
        terms.termStart = span.start
        terms.termEnd = span.end
        if let r = TermsFinder.renewal(folded) {
            terms.autoRenews = r.autoRenews
            terms.renewalMonths = r.months
        }
        return terms
    }

    /// Warranty length in months: "2 years warranty", "garantie: 24 monate",
    /// "zwei jahre herstellergarantie", "garantie de deux ans", "3-year guarantee",
    /// "garanzia 2 anni". Days count from 30 ("90 days warranty" is 3 months).
    /// Money-back, price and freshness guarantees are ignored.
    static func warrantyMonths(_ folded: String) -> Int? {
        TermsFinder.nearest(TermsFinder.scan(folded), rule: TermsFinder.warrantyRule,
                            unitRank: { $0 == .year || $0 == .month ? 0 : 1 },
                            convert: TermsFinder.warrantyValue)
    }

    /// The shop's return period in days: "returns within 28 days", "umtausch/ruckgabe
    /// innerhalb von 30 tagen", "retour/echange sous 30 jours", "reso entro 14 giorni".
    /// Weeks count 7 days and months 30.
    static func returnDays(_ folded: String) -> Int? {
        TermsFinder.nearest(TermsFinder.scan(folded), rule: TermsFinder.returnRule,
                            unitRank: { $0 == .month ? 1 : 0 },
                            convert: TermsFinder.returnValue)
    }

    /// A contract's notice period, in the unit printed: "kundigungsfrist 3 monate",
    /// "notice period of 30 days", "30 days' notice", "preavis de 3 mois",
    /// "frist von drei monaten", "kundigungsfrist 6 wochen".
    static func notice(_ folded: String) -> NoticePeriod? {
        TermsFinder.nearest(TermsFinder.scan(folded), rule: TermsFinder.noticeRule,
                            unitRank: { _ in 0 },
                            convert: TermsFinder.noticeValue)
    }

    /// The contract or cover period: a pair of dates after a term label
    /// ("Vertragsdauer 01.01.2025 – 31.12.2025", "period of cover", "durée"), or one
    /// date after an end label ("valid until", "gültig bis", "échéance", "expiry",
    /// "Ablauf"). A start label with a printed length ("Laufzeit 12 Monate") gives
    /// the end as well. The dates may sit on the line below a label that ends its line.
    static func term(_ text: String) -> (start: DayDate?, end: DayDate?) {
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { TermsFinder.termLine(String($0)) }
            .filter { !$0.isEmpty }
        var rangeStart: DayDate? = nil
        var rangeEnd: DayDate? = nil
        var rangeDone = false
        var lengthMonths: Int? = nil
        var labelStart: DayDate? = nil
        var labelEnd: DayDate? = nil

        for i in lines.indices {
            let next: String? = i + 1 < lines.count ? lines[i + 1] : nil
            if !rangeDone, let hit = TermsFinder.label(TermsFinder.rangeKeys, in: lines[i], next: next) {
                let ns = hit.line as NSString
                let dates = hit.dates
                if dates.count >= 2 && TermsFinder.isRange(dates[0], dates[1], in: ns) {
                    rangeStart = min(dates[0].date, dates[1].date)
                    rangeEnd = max(dates[0].date, dates[1].date)
                    rangeDone = true
                } else if let first = dates.first {
                    // One date: "Laufzeit bis 31.12.2025" or "Laufzeit ab (dem) 01.01.2025".
                    // Only the two words before the date count, and none after a
                    // notice or payment word ("12 Monate, Kündigung bis 30.09.2025").
                    let leadText = ns.substring(with: NSRange(location: hit.keyEnd, length: first.location - hit.keyEnd))
                    let leadWords = TermsFinder.plainWords(leadText)
                    let blocked = leadWords.contains(where: { w in
                        TermsFinder.noticeSingles.contains(w) || TermsFinder.paymentWords.contains(w)
                    })
                    let lead: Set<String> = blocked ? Set<String>() : Set(leadWords.suffix(2))
                    if !lead.isDisjoint(with: TermsFinder.untilWords) {
                        rangeEnd = first.date
                        rangeDone = true
                    } else if !lead.isDisjoint(with: TermsFinder.fromWords) {
                        rangeStart = first.date
                        rangeDone = true
                    }
                }
                if lengthMonths == nil {
                    lengthMonths = TermsFinder.monthsOfTerm(ns.substring(from: hit.keyEnd))
                }
            }
            if labelStart == nil, let hit = TermsFinder.label(TermsFinder.startKeys, in: lines[i], next: next),
               let first = hit.dates.first, TermsFinder.leadCount(hit, first) <= 3 {
                labelStart = first.date
            }
            if labelEnd == nil, let hit = TermsFinder.label(TermsFinder.untilKeys, in: lines[i], next: next),
               let first = hit.dates.first, TermsFinder.leadCount(hit, first) <= 4 {
                labelEnd = first.date
            }
        }

        var start = rangeStart ?? labelStart
        var end = rangeEnd ?? labelEnd
        if end == nil, let s = start, let m = lengthMonths {
            end = RVCalendar.periodEnd(from: s, months: m)
        }
        if let s = start, let e = end, s > e { start = nil }
        return (start: start, end: end)
    }

    /// Automatic renewal: "verlangert sich stillschweigend um ein weiteres jahr"
    /// gives (true, 12), "renews automatically", "reconduction tacite" and
    /// "rinnovo tacito" give (true, nil). A negated statement ("keine automatische
    /// Verlängerung", "sans tacite reconduction", "endet automatisch") gives
    /// (false, nil). Nil when renewal is not mentioned.
    static func renewal(_ folded: String) -> (autoRenews: Bool, months: Int?)? {
        let words = TermsFinder.scan(folded)
        for i in words.indices {
            let text = words[i].text
            if TermsFinder.endWords.contains(text) {
                if TermsFinder.hasAutoWord(near: i, in: words) { return (autoRenews: false, months: nil) }
                continue
            }
            var lo = i
            var hi = i
            if !TermsFinder.selfRenewing.contains(text) {
                guard TermsFinder.renewWords.contains(text) else { continue }
                // "extended warranty", "verlängert sich die Garantie um 1 Jahr": not a renewal.
                if TermsFinder.isAboutWarranty(i, in: words) { continue }
                guard let j = TermsFinder.partner(of: i, in: words) else { continue }
                lo = min(i, j)
                hi = max(i, j)
            }
            if TermsFinder.isNegated(lo, hi, in: words) { return (autoRenews: false, months: nil) }
            return (autoRenews: true, months: TermsFinder.renewalMonths(lo, hi, in: words))
        }
        return nil
    }

    /// Number words, folded: English one to twelve, German, French and Italian,
    /// plus a few common larger ones. Built from pairs, so a word listed twice
    /// ("six") cannot crash.
    static let numberWords: [String: Int] = {
        let pairs: [(String, Int)] = [
            ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6),
            ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10), ("eleven", 11), ("twelve", 12),
            ("fourteen", 14), ("fifteen", 15), ("twenty", 20), ("thirty", 30), ("forty", 40),
            ("fifty", 50), ("sixty", 60), ("seventy", 70), ("eighty", 80), ("ninety", 90),
            ("ein", 1), ("eine", 1), ("einen", 1), ("einem", 1), ("einer", 1), ("eines", 1),
            ("zwei", 2), ("drei", 3), ("vier", 4), ("funf", 5), ("fuenf", 5), ("sechs", 6),
            ("sieben", 7), ("acht", 8), ("neun", 9), ("zehn", 10), ("zwolf", 12), ("zwoelf", 12),
            ("vierzehn", 14), ("dreissig", 30), ("sechzig", 60), ("neunzig", 90),
            ("un", 1), ("une", 1), ("deux", 2), ("trois", 3), ("quatre", 4), ("cinq", 5),
            ("six", 6), ("sept", 7), ("huit", 8), ("dix", 10), ("douze", 12), ("quatorze", 14),
            ("quinze", 15), ("trente", 30), ("soixante", 60),
            ("uno", 1), ("una", 1), ("due", 2), ("tre", 3), ("quattro", 4), ("cinque", 5),
            ("sei", 6), ("sette", 7), ("otto", 8), ("dieci", 10), ("dodici", 12),
            ("quattordici", 14), ("quindici", 15), ("trenta", 30), ("sessanta", 60), ("novanta", 90),
        ]
        var m: [String: Int] = [:]
        for (word, value) in pairs { m[word] = value }
        return m
    }()

    // MARK: - Words

    /// A folded word or run of digits, with what separates it from the word before.
    private struct Word {
        var text: String
        /// A count: up to four digits, or a number word.
        var number: Int?
        var isDigits: Bool
        /// Part of a longer number or code (2.5, 249.00, 12:30, 1'000, 2-3, XM5),
        /// so not a count.
        var glued: Bool
        /// The separator before it: 0 for a space, 1 for a comma, 3 for a sentence
        /// end or line break.
        var gap: Int
    }

    private enum CharKind { case letter, digit, other }

    private static func kind(of c: Character) -> CharKind {
        if c.isASCII && c.isNumber { return .digit }
        if c.isLetter { return .letter }
        return .other
    }

    private static let numberJoiners: Set<Character> = Set(Array(".,:/'-"))
    private static let sentenceEnds: Set<Character> = Set(Array(".!?;\n•|"))

    /// Each line folded on its own, so line breaks still separate sentences.
    private static func foldedLines(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { TextFold.fold(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Splits folded text into words and digit runs ("3-year" is "3", "year";
    /// "24monate" is "24", "monate"). Folds again first, which changes nothing
    /// in text that is already folded.
    private static func scan(_ text: String) -> [Word] {
        let chars = Array(TermsFinder.foldedLines(text))
        var result: [Word] = []
        var separator: [Character] = []
        var i = 0
        while i < chars.count {
            let run = TermsFinder.kind(of: chars[i])
            if run == .other {
                separator.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < chars.count && TermsFinder.kind(of: chars[j]) == run { j += 1 }
            let piece = String(chars[i..<j])
            let digits = run == .digit
            var word = Word(text: piece, number: nil, isDigits: digits, glued: false, gap: 0)
            if digits {
                word.number = piece.count <= 4 ? Int(piece) : nil
            } else {
                word.number = TermsFinder.numberWords[piece]
            }
            if let last = result.last {
                if digits && last.isDigits && separator.count == 1 && TermsFinder.numberJoiners.contains(separator[0]) {
                    word.glued = true
                    result[result.count - 1].glued = true
                } else {
                    word.gap = TermsFinder.weight(of: separator)
                    if digits && separator.isEmpty { word.glued = true } // digits straight after letters: a code
                }
            }
            result.append(word)
            separator.removeAll()
            i = j
        }
        return result
    }

    private static func weight(of separator: [Character]) -> Int {
        if separator.contains(where: { TermsFinder.sentenceEnds.contains($0) }) { return 3 }
        return separator.contains(",") ? 1 : 0
    }

    /// Letters-and-digits words of an already folded string.
    private static func plainWords(_ s: String) -> [String] {
        s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { String($0) }
    }

    private static func wordSet(_ words: [String]) -> Set<String> { Set(words) }

    private static func phrases(_ list: [String]) -> [[String]] {
        list.map { phrase in phrase.split(separator: " ").map { String($0) } }
    }

    private static func singles(_ keys: [[String]]) -> Set<String> {
        Set(keys.filter { $0.count == 1 }.map { $0[0] })
    }

    // MARK: - Lengths

    private enum TimeUnit { case day, week, month, year }

    /// A count and its unit, e.g. "24 Monate", with their word positions.
    private struct TermLength {
        var value: Int
        var unit: TimeUnit
        var numberIndex: Int
        var unitIndex: Int
    }

    private static let unitWords: [String: TimeUnit] = {
        let lists: [(TimeUnit, [String])] = [
            (.year, ["year", "years", "yr", "yrs", "jahr", "jahre", "jahren", "jahres",
                     "an", "ans", "annee", "annees", "anno", "anni"]),
            (.month, ["month", "months", "mth", "mths", "monat", "monate", "monaten", "monats",
                      "mt", "mte", "mois", "mese", "mesi"]),
            (.week, ["week", "weeks", "wk", "wks", "woche", "wochen", "semaine", "semaines",
                     "settimana", "settimane"]),
            (.day, ["day", "days", "tag", "tage", "tagen", "tages", "jour", "jours",
                    "giorno", "giorni", "gg"]),
        ]
        var m: [String: TimeUnit] = [:]
        for (unit, words) in lists { for w in words { m[w] = unit } }
        return m
    }()

    /// Short or ambiguous units that need the count right before them ("un an").
    private static let adjacentUnits = TermsFinder.wordSet(["an", "tag", "gg", "yr", "wk", "mt", "mte"])
    /// Units that take the article "a" as one ("a month's notice").
    private static let singularUnits = TermsFinder.wordSet(["year", "month", "week", "day"])
    private static let tensWords = TermsFinder.wordSet(["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"])
    private static let halfWords = TermsFinder.wordSet(["half", "halbes", "halben", "halbe", "demi", "mezzo"])
    /// "2 Jahre alt", "2 years ago", "2 anni fa".
    private static let ageAfter = TermsFinder.wordSet(["alt", "alte", "alter", "altes", "old", "ago", "aged", "fa",
                                                       "gereift", "matured", "affine", "stagionato"])
    /// "unter 3 Jahren", "ab 3 Jahren", "seit 2 Jahren", "vor 2 Jahren".
    private static let ageBefore = TermsFinder.wordSet(["under", "unter", "moins", "sotto", "age", "ages", "aged", "alter",
                                                        "ab", "vor", "seit", "since", "depuis", "kinder", "children",
                                                        "enfants", "bambini"])

    /// Every count followed within three words by a unit, except ages.
    private static func durations(_ words: [Word]) -> [TermLength] {
        var result: [TermLength] = []
        for u in words.indices {
            guard let unit = TermsFinder.unitWords[words[u].text],
                  let d = TermsFinder.length(endingAt: u, unit: unit, in: words),
                  !TermsFinder.isAge(d, in: words) else { continue }
            result.append(d)
        }
        return result
    }

    /// The count that belongs to the unit word at `u`: the nearest count within
    /// three words before it, with no sentence break or other unit between.
    private static func length(endingAt u: Int, unit: TimeUnit, in words: [Word]) -> TermLength? {
        let unitText = words[u].text
        let reach = TermsFinder.adjacentUnits.contains(unitText) ? 1 : 3
        var j = u - 1
        while j >= 0 && u - j <= reach {
            if words[j + 1].gap >= 3 { return nil }
            let w = words[j]
            if TermsFinder.unitWords[w.text] != nil { return nil }
            if TermsFinder.halfWords.contains(w.text) {
                return unit == .year ? TermLength(value: 6, unit: .month, numberIndex: j, unitIndex: u) : nil
            }
            if j == u - 1 && w.text == "a" && TermsFinder.singularUnits.contains(unitText) {
                if j > 0 && words[j].gap < 3 && TermsFinder.halfWords.contains(words[j - 1].text) {
                    return unit == .year ? TermLength(value: 6, unit: .month, numberIndex: j - 1, unitIndex: u) : nil
                }
                return TermLength(value: 1, unit: unit, numberIndex: j, unitIndex: u)
            }
            if let n = w.number {
                if w.glued || n <= 0 { return nil }
                // "twenty-eight days"
                if (1...9).contains(n) && j > 0 && w.gap == 0 && TermsFinder.tensWords.contains(words[j - 1].text),
                   let tens = words[j - 1].number {
                    return TermLength(value: tens + n, unit: unit, numberIndex: j - 1, unitIndex: u)
                }
                return TermLength(value: n, unit: unit, numberIndex: j, unitIndex: u)
            }
            j -= 1
        }
        return nil
    }

    private static func isAge(_ d: TermLength, in words: [Word]) -> Bool {
        let after = d.unitIndex + 1
        if after < words.count && words[after].gap < 3 && TermsFinder.ageAfter.contains(words[after].text) { return true }
        let before = d.numberIndex - 1
        return before >= 0 && words[d.numberIndex].gap < 3 && TermsFinder.ageBefore.contains(words[before].text)
    }

    private static func warrantyValue(_ d: TermLength) -> Int? {
        let months: Int
        switch d.unit {
        case .year: months = d.value * 12
        case .month: months = d.value
        case .week, .day:
            let days = d.unit == .week ? d.value * 7 : d.value
            months = days % 365 == 0 ? days / 365 * 12 : days / 30
        }
        return (1...360).contains(months) ? months : nil
    }

    private static func returnValue(_ d: TermLength) -> Int? {
        let days: Int
        switch d.unit {
        case .day: days = d.value
        case .week: days = d.value * 7
        case .month: days = d.value * 30
        case .year: return nil
        }
        return (1...365).contains(days) ? days : nil
    }

    private static func noticeValue(_ d: TermLength) -> NoticePeriod? {
        switch d.unit {
        case .day: return (1...365).contains(d.value) ? NoticePeriod(value: d.value, unit: .days) : nil
        case .week: return (1...52).contains(d.value) ? NoticePeriod(value: d.value, unit: .weeks) : nil
        case .month: return (1...24).contains(d.value) ? NoticePeriod(value: d.value, unit: .months) : nil
        case .year: return (1...2).contains(d.value) ? NoticePeriod(value: d.value * 12, unit: .months) : nil
        }
    }

    // MARK: - Keywords

    /// How keywords link to lengths for one kind of term.
    private struct Rule {
        var keys: [[String]]
        /// Words just before or after a keyword that change its meaning
        /// ("money back guarantee", "Tiefpreis-Garantie").
        var modifiers: Set<String> = []
        /// Words between a keyword and a length that break the link.
        var blockers: Set<String> = []
        /// Keywords too general to trust in a sentence that has a weak blocker.
        var weakKeys: Set<String> = []
        var weakBlockers: Set<String> = []
    }

    private struct KeyMatch {
        var start: Int
        var end: Int
    }

    /// Words between keyword and length (a comma adds 1, a sentence or line break 3).
    private static let maxDistance = 4

    private static let warrantyKeys: [[String]] = TermsFinder.phrases([
        "warranty", "warranties", "guarantee", "guarantees", "guaranty",
        "garantie", "garanties", "herstellergarantie", "werksgarantie", "vollgarantie", "neugarantie",
        "garantiezeit", "garantiedauer", "garantiefrist", "garantieleistung", "garantieanspruch",
        "garantieverlangerung", "garantieverlaengerung", "garantiekarte", "garantieschein", "garantiezertifikat",
        "garanzia", "garanzie",
    ])

    private static let returnKeys: [[String]] = TermsFinder.phrases([
        "return", "returns", "returned", "returnable", "exchange", "exchanges", "exchanged", "money back",
        "refund", "refunds",
        "umtausch", "umtauschen", "umtauschrecht", "umtauschfrist", "ruckgabe", "rueckgabe",
        "ruckgaberecht", "rueckgaberecht", "ruckgabefrist", "rueckgabefrist", "zuruckgeben", "zurueckgeben",
        "retoure", "retouren", "geld zuruck", "geld zurueck",
        "retour", "retours", "retourner", "echange", "echanges", "echanger", "satisfait ou rembourse",
        "reso", "resi", "restituzione", "cambio", "soddisfatti o rimborsati",
    ])

    private static let noticeKeys: [[String]] = TermsFinder.phrases([
        "notice", "cancellation period", "termination period",
        "kundigungsfrist", "kuendigungsfrist", "kundigung", "kuendigung", "kundigen", "kuendigen",
        "gekundigt", "gekuendigt", "kundbar", "kuendbar", "kundigungstermin", "frist", "monatsende", "quartalsende",
        "preavis", "resiliation", "resilier", "resiliable", "resilie", "denonciation",
        "preavviso", "disdetta", "disdire",
    ])

    private static let warrantySingles = TermsFinder.singles(TermsFinder.warrantyKeys)
    private static let returnSingles = TermsFinder.singles(TermsFinder.returnKeys)
    private static let noticeSingles = TermsFinder.singles(TermsFinder.noticeKeys)

    /// Payment, delivery and statutory withdrawal periods, which are not notice.
    private static let paymentWords = TermsFinder.wordSet([
        "zahlbar", "zahlung", "zahlungen", "zahlungsfrist", "zahlungsziel", "payment", "payable", "paid",
        "paiement", "pagamento", "lieferfrist", "lieferung", "lieferzeit", "delivery", "livraison", "consegna",
        "widerruf", "widerrufsrecht", "widerrufsfrist", "retractation", "recesso",
    ])
    /// Minimum terms, which are not notice.
    private static let termWords = TermsFinder.wordSet([
        "laufzeit", "mindestlaufzeit", "vertragslaufzeit", "vertragsdauer", "duration", "duree", "durata", "term",
    ])
    /// Complaint periods ("Reklamationen innerhalb einer Frist von 8 Tagen"), which are not notice.
    private static let complaintWords = TermsFinder.wordSet([
        "reklamation", "reklamationen", "beanstandung", "beanstandungen", "mangel", "mangelruge", "mangelruege",
        "complaint", "complaints", "claim", "claims", "reclamation", "reclamations", "reclamo", "reclami",
    ])

    // "money" (not "back") marks a money-back guarantee, so "12 month warranty
    // (back to base)" is still a warranty.
    private static let warrantyRule = Rule(
        keys: TermsFinder.warrantyKeys,
        modifiers: TermsFinder.wordSet([
            "money", "cash", "cashback", "refund", "price", "prix", "preis", "tiefpreis", "bestpreis", "lowest", "match",
            "satisfaction", "satisfait", "satisfied", "rembourse", "geld", "zuruck", "zurueck", "zufriedenheit",
            "soddisfatti", "rimborsati", "frische", "frisch", "freshness", "fraicheur", "freschezza",
        ]),
        blockers: TermsFinder.returnSingles.union(["money", "cash", "cashback", "geld", "zuruck", "zurueck"]))

    private static let returnRule = Rule(
        keys: TermsFinder.returnKeys,
        blockers: TermsFinder.warrantySingles.union([
            "processed", "processing", "bearbeitet", "bearbeitung", "traite", "traites", "traitee",
            "elaborato", "elaborati",
        ]))

    // A renewal word between a notice keyword and a length makes it the renewal
    // period ("wenn nicht gekündigt, automatisch um 12 Monate").
    private static let noticeRule = Rule(
        keys: TermsFinder.noticeKeys,
        blockers: TermsFinder.returnSingles.union(TermsFinder.warrantySingles)
            .union(TermsFinder.paymentWords).union(TermsFinder.termWords)
            .union(TermsFinder.renewWords).union(TermsFinder.autoWords),
        weakKeys: TermsFinder.wordSet(["frist", "monatsende", "quartalsende"]),
        // "Umtausch innerhalb einer Frist von 14 Tagen" is a return period, not notice.
        weakBlockers: TermsFinder.paymentWords.union(TermsFinder.returnSingles)
            .union(TermsFinder.warrantySingles).union(TermsFinder.complaintWords))

    /// Every place a keyword phrase appears, not across a sentence break.
    private static func matches(of keys: [[String]], in words: [Word]) -> [KeyMatch] {
        let byFirst = Dictionary(grouping: keys.filter { !$0.isEmpty }, by: { $0[0] })
        var result: [KeyMatch] = []
        for i in words.indices {
            guard let candidates = byFirst[words[i].text] else { continue }
            for key in candidates where i + key.count <= words.count {
                var ok = true
                for offset in 1..<key.count where words[i + offset].text != key[offset] || words[i + offset].gap >= 3 {
                    ok = false
                    break
                }
                if ok { result.append(KeyMatch(start: i, end: i + key.count - 1)) }
            }
        }
        return result
    }

    /// The length closest to a keyword, converted. Ties go to the preferred unit,
    /// then to a keyword printed before its value ("Kündigungsfrist 3 Monate"),
    /// then to the earliest.
    private static func nearest<T>(_ words: [Word], rule: Rule, unitRank: (TimeUnit) -> Int,
                                   convert: (TermLength) -> T?) -> T? {
        let keys = TermsFinder.matches(of: rule.keys, in: words).filter { key in
            if TermsFinder.isModified(key, in: words, by: rule.modifiers) { return false }
            if rule.weakKeys.contains(words[key.start].text),
               TermsFinder.sentence(around: key, in: words, contains: rule.weakBlockers) { return false }
            return true
        }
        guard !keys.isEmpty else { return nil }
        var bestScore: (Int, Int, Int, Int)? = nil
        var bestValue: T? = nil
        for length in TermsFinder.durations(words) {
            guard let value = convert(length) else { continue }
            for key in keys {
                guard let link = TermsFinder.link(key, length, in: words, blockers: rule.blockers) else { continue }
                let score = (link.distance, unitRank(length.unit), link.before ? 0 : 1, length.numberIndex)
                if let best = bestScore, !(score < best) { continue }
                bestScore = score
                bestValue = value
            }
        }
        return bestValue
    }

    /// How far a keyword is from a length, or nil when it is too far or a
    /// blocker sits between them.
    private static func link(_ key: KeyMatch, _ length: TermLength, in words: [Word],
                             blockers: Set<String>) -> (distance: Int, before: Bool)? {
        let lo: Int
        let hi: Int
        let before: Bool
        if key.end < length.numberIndex {
            lo = key.end + 1
            hi = length.numberIndex - 1
            before = true
        } else if key.start > length.unitIndex {
            lo = length.unitIndex + 1
            hi = key.start - 1
            before = false
        } else {
            return (distance: 0, before: true) // the keyword sits inside the length
        }
        var distance = hi - lo + 1
        guard distance <= TermsFinder.maxDistance else { return nil }
        for k in lo...(hi + 1) {
            // A label may sit on the line above its value, but never after a break.
            if !before && words[k].gap >= 3 { return nil }
            distance += words[k].gap
        }
        guard distance <= TermsFinder.maxDistance else { return nil }
        if lo <= hi {
            for k in lo...hi where blockers.contains(words[k].text) { return nil }
        }
        if !before {
            // "Laufzeit 24 Monate, Kündigung …": the length belongs to the word before it.
            var k = length.numberIndex - 1
            while k >= 0 && k >= length.numberIndex - 2 && words[k + 1].gap == 0 {
                if blockers.contains(words[k].text) { return nil }
                k -= 1
            }
        }
        return (distance: distance, before: before)
    }

    /// True when one of the two words before the keyword, or the word after it,
    /// is a modifier.
    private static func isModified(_ key: KeyMatch, in words: [Word], by modifiers: Set<String>) -> Bool {
        guard !modifiers.isEmpty else { return false }
        var k = key.start
        var steps = 0
        while steps < 2 && k > 0 && words[k].gap < 3 {
            k -= 1
            steps += 1
            if modifiers.contains(words[k].text) { return true }
        }
        let after = key.end + 1
        return after < words.count && words[after].gap < 3 && modifiers.contains(words[after].text)
    }

    /// True when the keyword's sentence (or line) has one of `vocabulary`.
    private static func sentence(around key: KeyMatch, in words: [Word], contains vocabulary: Set<String>) -> Bool {
        guard !vocabulary.isEmpty else { return false }
        var lo = key.start
        while lo > 0 && words[lo].gap < 3 { lo -= 1 }
        var hi = key.end
        while hi + 1 < words.count && words[hi + 1].gap < 3 { hi += 1 }
        for k in lo...hi where vocabulary.contains(words[k].text) { return true }
        return false
    }

    private static func crossesSentence(_ a: Int, _ b: Int, in words: [Word]) -> Bool {
        let lo = min(a, b)
        let hi = max(a, b)
        guard lo < hi else { return false }
        for k in (lo + 1)...hi where words[k].gap >= 3 { return true }
        return false
    }

    // MARK: - Renewal

    private static let renewWords = TermsFinder.wordSet([
        "renew", "renews", "renewed", "renewal", "renewing", "extend", "extends", "extended",
        "verlangert", "verlaengert", "verlangern", "verlaengern", "verlangerung", "verlaengerung",
        "erneuert", "erneuern", "erneuerung",
        "reconduction", "reconduit", "reconduite", "reconduits", "reconductible", "renouvelle", "renouvele",
        "renouvelee", "renouvellement", "renouvelable", "prolonge", "prolongee", "prolongation",
        "rinnovo", "rinnova", "rinnovato", "rinnovata", "rinnovabile", "rinnovi", "proroga", "prorogato",
        "prorogata", "prorogazione",
    ])
    private static let selfRenewing = TermsFinder.wordSet(["autorenew", "autorenews", "autorenewal", "autorenewing"])
    /// "auto" is handled apart: it only counts right before the renewal word.
    private static let autoWords = TermsFinder.wordSet([
        "automatically", "automatic", "tacit", "tacitly",
        "stillschweigend", "stillschweigende", "stillschweigenden", "stillschweigender",
        "automatisch", "automatische", "automatischen", "automatischer",
        "tacite", "tacitement", "automatique", "automatiques", "automatiquement",
        "tacito", "tacita", "tacitamente", "automatico", "automatica", "automaticamente",
    ])
    /// "verlängert sich", "se renouvelle", "si rinnova".
    private static let reflexiveWords = TermsFinder.wordSet(["sich", "se", "si"])
    /// "endet automatisch": the contract ends without renewal.
    private static let endWords = TermsFinder.wordSet(["endet", "ends", "expires", "expire", "terminates",
                                                       "erlischt", "fin", "cesse", "termina", "scade"])
    private static let negations = TermsFinder.wordSet([
        "not", "no", "never", "without", "cannot", "nor", "doesn", "don", "won", "isn",
        "nicht", "kein", "keine", "keinen", "keiner", "ohne", "nie",
        "sans", "ne", "n", "pas", "jamais", "non", "senza",
    ])
    /// "nicht gekündigt" and "if not cancelled" negate the cancellation, not the renewal.
    private static let cancelWords = TermsFinder.wordSet([
        "cancel", "cancels", "cancelled", "canceled", "terminate", "terminated",
        "gekundigt", "gekuendigt", "kundigt", "resilie", "resiliee", "resilier", "denonce", "denoncee",
        "disdetto", "disdetta", "disdetti",
    ])
    private static let yearlyWords = TermsFinder.wordSet([
        "annually", "yearly", "annual", "jahrlich", "jaehrlich", "jahrliche", "jahrlichen", "jahrlicher",
        "annuel", "annuelle", "annuellement", "annuale", "annualmente", "annuo", "annua",
    ])
    private static let monthlyWords = TermsFinder.wordSet([
        "monthly", "monatlich", "monatliche", "monatlichen", "mensuel", "mensuelle", "mensuellement",
        "mensile", "mensilmente",
    ])
    /// "a further year", "for another year", "each year".
    private static let oneMoreWords = TermsFinder.wordSet([
        "a", "another", "further", "additional", "each", "every", "weiteres", "weiteren", "weitere", "jeweils",
        "jedes", "je", "chaque", "autre", "nouvelle", "nouvel", "altro", "ulteriore", "ogni",
    ])
    /// "von Jahr zu Jahr", "d'année en année", "di anno in anno", "year to year".
    private static let periodJoiners = TermsFinder.wordSet(["to", "on", "by", "after", "zu", "en", "in"])
    /// A length right before these is a notice period ("3 Monate vor Ablauf").
    private static let noticeMarkers = TermsFinder.wordSet([
        "vor", "voraus", "before", "prior", "avant", "prima", "advance", "notice", "preavis", "preavviso",
        "kundigungsfrist", "kuendigungsfrist", "frist",
    ])

    /// An automatic or reflexive word that makes the renewal word at `i` automatic.
    /// An automatic word wins over a reflexive one, so the statement spans any
    /// negation between them ("verlängert sich der Vertrag nicht automatisch").
    private static func partner(of i: Int, in words: [Word]) -> Int? {
        let word = words[i].text
        var fallback: Int? = nil
        for step in 1...5 {
            for j in [i - step, i + step] where j >= 0 && j < words.count {
                if TermsFinder.crossesSentence(i, j, in: words) { continue }
                let w = words[j].text
                if w == "auto" {
                    if j == i - 1 { return j }
                    continue
                }
                if TermsFinder.autoWords.contains(w) { return j }
                if fallback != nil { continue }
                // "verlängert sich", "se renouvelle", "si rinnova" (not "le renouvellement se fait").
                if step == 1 && TermsFinder.reflexiveWords.contains(w) && (w == "sich" || j == i - 1) {
                    fallback = j
                } else if w == "unless" && j > i && step <= 3 && word.hasPrefix("renew") && word != "renewal" {
                    // "renews each year unless cancelled"
                    fallback = j
                }
            }
        }
        return fallback
    }

    /// A warranty word up to two words before the renewal word at `i`, or up to
    /// three after it, in the same sentence: a warranty extension.
    private static func isAboutWarranty(_ i: Int, in words: [Word]) -> Bool {
        let lo = max(0, i - 2)
        let hi = min(words.count - 1, i + 3)
        for j in lo...hi where j != i {
            if !TermsFinder.crossesSentence(i, j, in: words) && TermsFinder.warrantySingles.contains(words[j].text) {
                return true
            }
        }
        return false
    }

    private static func hasAutoWord(near i: Int, in words: [Word]) -> Bool {
        for j in [i - 1, i + 1, i + 2] where j >= 0 && j < words.count {
            if !TermsFinder.crossesSentence(i, j, in: words) && TermsFinder.autoWords.contains(words[j].text) {
                return true
            }
        }
        return false
    }

    /// A negation up to two words before the statement, inside it, or right after it.
    private static func isNegated(_ lo: Int, _ hi: Int, in words: [Word]) -> Bool {
        var first = lo
        while first > 0 && lo - first < 2 && words[first].gap < 3 { first -= 1 }
        var last = hi
        if last + 1 < words.count && words[last + 1].gap < 3 { last += 1 }
        for k in first...last where TermsFinder.negations.contains(words[k].text) {
            if k + 1 < words.count && (words[k + 1].isDigits || TermsFinder.cancelWords.contains(words[k + 1].text)) {
                continue // "no 12345" is a number; "nicht gekündigt" negates the cancellation
            }
            return true
        }
        return false
    }

    /// The renewal period in months: inside the statement, after it in the same
    /// sentence, or just before it in the same clause ("um 12 Monate verlängert").
    private static func renewalMonths(_ lo: Int, _ hi: Int, in words: [Word]) -> Int? {
        if hi - lo > 1 {
            for k in (lo + 1)..<hi {
                if let m = TermsFinder.periodMonths(at: k, in: words, earliest: lo + 1) { return m }
            }
        }
        var k = hi + 1
        while k < words.count && k <= hi + 10 && words[k].gap < 3 {
            if let m = TermsFinder.periodMonths(at: k, in: words, earliest: hi + 1) { return m }
            k += 1
        }
        k = lo - 1
        while k >= 0 && k >= lo - 6 && words[k + 1].gap == 0 {
            if let m = TermsFinder.periodMonths(at: k, in: words, earliest: max(0, lo - 8)) { return m }
            k -= 1
        }
        return nil
    }

    /// A renewal period ending at word `k`, in months: "12 Monate", "ein weiteres
    /// Jahr", "jährlich", "de mois en mois". Notice periods are skipped.
    private static func periodMonths(at k: Int, in words: [Word], earliest: Int) -> Int? {
        let text = words[k].text
        if TermsFinder.yearlyWords.contains(text) { return 12 }
        if TermsFinder.monthlyWords.contains(text) { return 1 }
        guard let unit = TermsFinder.unitWords[text], unit == .year || unit == .month else { return nil }
        let perUnit = unit == .year ? 12 : 1
        if let d = TermsFinder.length(endingAt: k, unit: unit, in: words) {
            guard d.numberIndex >= earliest, !TermsFinder.looksLikeNotice(d, in: words) else { return nil }
            let months = d.unit == .year ? d.value * 12 : d.value
            return (1...120).contains(months) ? months : nil
        }
        if k > 0 && words[k].gap < 3 && TermsFinder.oneMoreWords.contains(words[k - 1].text) { return perUnit }
        if k + 2 < words.count && TermsFinder.periodJoiners.contains(words[k + 1].text)
            && TermsFinder.unitWords[words[k + 2].text] == unit {
            return perUnit
        }
        return nil
    }

    private static func looksLikeNotice(_ d: TermLength, in words: [Word]) -> Bool {
        var k = d.unitIndex + 1
        while k < words.count && k <= d.unitIndex + 2 && words[k].gap < 3 {
            if TermsFinder.noticeMarkers.contains(words[k].text) { return true }
            k += 1
        }
        k = d.numberIndex - 1
        while k >= 0 && k >= d.numberIndex - 2 && words[k + 1].gap < 3 {
            if TermsFinder.noticeSingles.contains(words[k].text) { return true }
            k -= 1
        }
        return false
    }

    // MARK: - Term dates

    /// Labels followed by a start and an end date.
    private static let rangeKeys: [String] = [
        "vertragsdauer", "vertragslaufzeit", "mindestlaufzeit", "laufzeit", "versicherungsdauer",
        "versicherungsperiode", "versicherungszeitraum", "vertragszeitraum", "vertragsperiode",
        "gultigkeit", "gueltigkeit", "gultig vom", "gueltig vom",
        "period of cover", "period of insurance", "insurance period", "policy period", "cover period",
        "contract period", "contract term", "term of contract", "valid from",
        "duree", "periode de validite", "periode d assurance", "periode de couverture", "validite",
        "durata", "periodo di copertura", "periodo assicurativo", "periodo di validita", "validita",
    ]
    /// Labels followed by an end date.
    private static let untilKeys: [String] = [
        "valid until", "valid till", "valid through", "valid to", "gultig bis", "gueltig bis",
        "expiry", "expires", "expiration", "end date", "ablauf", "ablaufdatum", "vertragsende",
        "versicherungsende", "enddatum", "echeance", "valable jusqu", "fin du contrat", "fin de contrat",
        "date de fin", "scadenza", "valido fino", "valida fino", "fine del contratto", "data di fine",
    ]
    /// Labels followed by a start date.
    private static let startKeys: [String] = [
        "vertragsbeginn", "versicherungsbeginn", "start date", "commencement date", "date d effet",
        "prise d effet", "debut du contrat", "date de debut", "decorrenza", "data di inizio", "inizio del contratto",
    ]
    private static let fromWords = TermsFinder.wordSet([
        "ab", "vom", "von", "seit", "from", "since", "starting", "effective", "du", "des", "partir",
        "dal", "dall", "dai",
    ])
    private static let untilWords = TermsFinder.wordSet(["bis", "until", "till", "to", "through", "thru",
                                                         "au", "jusqu", "al", "fino"])
    /// Words allowed between the two dates of a range.
    private static let rangeWords = TermsFinder.untilWords.union([
        "a", "und", "and", "et", "e", "zum", "mit", "le", "inkl", "incl", "inklusive", "einschliesslich",
        "including", "inclusive", "inclus", "compris", "incluso",
    ])

    /// A label on a line and the dates after it, or on the next line when the
    /// label ends its line.
    private struct LabelHit {
        var line: String
        /// UTF-16 offset just past the label (0 for the next line).
        var keyEnd: Int
        var dates: [FoundDate]
    }

    /// A line folded for label matching; apostrophes become spaces ("d'effet").
    /// Both are one UTF-16 unit, so DateFinder offsets still apply.
    private static func termLine(_ line: String) -> String {
        TextFold.fold(line).replacingOccurrences(of: "'", with: " ")
    }

    private static func label(_ keys: [String], in line: String, next: String?) -> LabelHit? {
        guard let key = TermsFinder.firstKey(keys, in: line) else { return nil }
        let ns = line as NSString
        let keyEnd = key.location + key.length
        let same = DateFinder.dates(in: line).filter { $0.location >= keyEnd }
        if !same.isEmpty { return LabelHit(line: line, keyEnd: keyEnd, dates: same) }
        let rest = ns.substring(from: keyEnd)
        if let below = next, !rest.contains(where: { $0.isLetter || $0.isNumber }) {
            let found = DateFinder.dates(in: below)
            if let first = found.first {
                let lead = TermsFinder.plainWords((below as NSString).substring(to: first.location))
                if lead.allSatisfy({ TermsFinder.fromWords.contains($0) || TermsFinder.untilWords.contains($0) }) {
                    return LabelHit(line: below, keyEnd: 0, dates: found)
                }
            }
        }
        return LabelHit(line: line, keyEnd: keyEnd, dates: [])
    }

    /// Words between the label and a date.
    private static func leadCount(_ hit: LabelHit, _ date: FoundDate) -> Int {
        guard date.location >= hit.keyEnd else { return Int.max }
        let ns = hit.line as NSString
        return TermsFinder.plainWords(ns.substring(with: NSRange(location: hit.keyEnd, length: date.location - hit.keyEnd))).count
    }

    /// Two dates joined only by a dash or range words ("bis", "au", "to").
    private static func isRange(_ a: FoundDate, _ b: FoundDate, in line: NSString) -> Bool {
        let from = a.location + a.length
        guard b.location >= from else { return false }
        let between = TermsFinder.plainWords(line.substring(with: NSRange(location: from, length: b.location - from)))
        return between.allSatisfy { w in TermsFinder.rangeWords.contains(w) || w.allSatisfy({ $0.isNumber }) }
    }

    /// The year or month length printed right after a term label, in months:
    /// "12 Monate", "des Vertrages: 24 Monate", "mind. 24 Monate". A length
    /// further on, after a comma or after a notice word is not the term's
    /// ("unbefristet, Kündigungsfrist 3 Monate").
    private static func monthsOfTerm(_ text: String) -> Int? {
        let words = TermsFinder.scan(text)
        guard let d = TermsFinder.durations(words).first(where: { $0.unit == .year || $0.unit == .month }),
              d.numberIndex <= 3, !TermsFinder.looksLikeNotice(d, in: words) else { return nil }
        for k in 0..<d.numberIndex {
            if TermsFinder.noticeSingles.contains(words[k].text) { return nil }
            // A comma, or a full stop that does not end a short abbreviation ("ca.", "mind.").
            let gap = words[k + 1].gap
            if gap == 1 || (gap >= 3 && words[k].text.count > 4) { return nil }
        }
        let months = d.unit == .year ? d.value * 12 : d.value
        return (1...120).contains(months) ? months : nil
    }

    /// The earliest word-bounded match of any key (the longest when two start together).
    private static func firstKey(_ keys: [String], in line: String) -> NSRange? {
        var best: NSRange? = nil
        for key in keys {
            guard let r = TermsFinder.wordRange(of: key, in: line) else { continue }
            if let b = best, b.location < r.location || (b.location == r.location && b.length >= r.length) { continue }
            best = r
        }
        return best
    }

    private static func wordRange(of word: String, in s: String) -> NSRange? {
        var from = s.startIndex
        while from < s.endIndex, let r = s.range(of: word, options: .literal, range: from..<s.endIndex) {
            let before = s[..<r.lowerBound].last
            let after = s[r.upperBound...].first
            if !TermsFinder.isWordCharacter(before) && !TermsFinder.isWordCharacter(after) {
                return NSRange(r, in: s)
            }
            from = s.index(after: r.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c = c else { return false }
        return c.isLetter || c.isNumber
    }
}
