import Foundation

// Reading receipts, invoices, warranty cards and contracts. ReceiptExtractor turns
// a document's lines into an item's fields: merchant, dates, total, currency, VAT,
// product lines and a few guesses. It is pure and stateless, and every value
// carries a confidence, because blank beats wrong: the form fills a value at 0.5
// or more and captions it 'Please check' below 0.75. Keyword lists live in Lexicon,
// already folded, and are matched word-bounded on folded text (TextFold). It only
// uses Foundation so it can be unit-tested.

// MARK: - Results

/// A value read from a document, how sure the reader is (0...1) and the index of
/// the line it came from.
struct Found<T: Equatable>: Equatable {
    var value: T
    var confidence: Double
    var line: Int? = nil
    /// Sure enough to fill the form.
    var shouldFill: Bool { confidence >= 0.5 }
    /// Filled, but captioned 'Please check'.
    var needsCheck: Bool { confidence < 0.75 }
}

/// A product line: "2 x USB-C CABLE 19.98" is ("USB-C CABLE", 2, 1998).
struct ItemLine: Equatable, Codable {
    var name: String
    var quantity: Int
    var amountMinor: Int64?
}

/// Everything read from one document. Nil means not found.
struct ReceiptFields: Equatable {
    var kind: Found<ItemKind> = Found(value: ItemKind.receipt, confidence: 0.3)
    var merchant: Found<String>? = nil
    var date: Found<DayDate>? = nil
    var deliveryDate: Found<DayDate>? = nil
    var total: Found<Int64>? = nil
    var currency: Found<String>? = nil
    var vat: Found<Int64>? = nil
    var vatRatePermille: Found<Int>? = nil
    /// The VAT was worked out from a printed rate, not read.
    var vatIsCalculated: Bool = false
    var items: [ItemLine] = []
    var jurisdiction: Found<Jurisdiction>? = nil
    var channel: Found<PurchaseChannel>? = nil
    var category: Found<ProductCategory>? = nil
    var terms: PrintedTerms = PrintedTerms()
    var suggestedTitle: String? = nil
    /// The largest amount, offered when no total was found. Never fills the form.
    var totalSuggestion: Int64? = nil

    /// True when the merchant, date or total is missing, too unsure to fill, or
    /// marked 'Please check'. The item then appears under 'Needs a look'.
    var needsReview: Bool {
        let key: [Double?] = [merchant?.confidence, date?.confidence, total?.confidence]
        return key.contains { c in
            guard let c = c else { return true }
            return c < 0.75 // below 0.5 it is not filled, below 0.75 it needs a check
        }
    }

    /// Fields that are filled but still marked 'Please check'.
    var checkFields: Set<FillField> {
        var fields = Set<FillField>()
        if let f = merchant, f.shouldFill, f.needsCheck { fields.insert(.merchant) }
        if let f = date, f.shouldFill, f.needsCheck { fields.insert(.date) }
        if let f = deliveryDate, f.shouldFill, f.needsCheck { fields.insert(.deliveryDate) }
        if let f = total, f.shouldFill, f.needsCheck { fields.insert(.total) }
        if let f = vat, f.shouldFill, f.needsCheck { fields.insert(.vat) }
        return fields
    }
}

/// A form field that 'Pick from document' can fill from a tapped line. Raw values
/// are stored in VaultItem.checkFields, so they are frozen.
enum FillField: String, CaseIterable, Codable {
    case title, merchant, total, vat, date, deliveryDate, notes
    var label: String {
        switch self {
        case .title: return "Title"
        case .merchant: return "Merchant"
        case .total: return "Total"
        case .vat: return "VAT"
        case .date: return "Purchase date"
        case .deliveryDate: return "Delivery date"
        case .notes: return "Notes"
        }
    }
}

/// What a tapped line gives a field.
enum FillValue: Equatable {
    case text(String)
    case amount(minor: Int64, currency: String?)
    case day(DayDate)
}

// MARK: - Extractor

enum ReceiptExtractor {

    // MARK: Documents

    /// Every field of a document, from its lines in reading order.
    static func extract(lines: [TextLine], today: DayDate, fromOCR: Bool) -> ReceiptFields {
        var fields = ReceiptFields()
        guard !lines.isEmpty else { return fields }
        let text = lines.map(\.text).joined(separator: "\n")
        let folded = lines.map { TextFold.fold($0.text) }.joined(separator: "\n")

        let merchant = ReceiptExtractor.findMerchant(lines)
        let totals = ReceiptExtractor.findTotal(lines, fromOCR: fromOCR)
        let vat = ReceiptExtractor.findVAT(lines, total: totals.total?.value, fromOCR: fromOCR)
        let dates = ReceiptExtractor.findDates(lines, today: today)
        let merchantName: String? = (merchant?.shouldFill ?? false) ? merchant?.value : nil

        fields.merchant = merchant
        fields.total = totals.total
        fields.totalSuggestion = totals.suggestion
        fields.currency = ReceiptExtractor.findCurrency(lines, totalLine: totals.total?.line)
        fields.vat = vat.amount
        fields.vatRatePermille = vat.ratePermille
        fields.vatIsCalculated = vat.amount != nil && vat.calculated
        fields.date = dates.purchase
        fields.deliveryDate = dates.delivery
        fields.items = ReceiptExtractor.findItems(lines, before: totals.total?.line, fromOCR: fromOCR)
        fields.kind = ReceiptExtractor.guessKind(folded)
        fields.channel = ReceiptExtractor.guessChannel(folded)
        fields.jurisdiction = ReceiptExtractor.guessJurisdiction(text, currency: fields.currency?.value)
        fields.category = ReceiptExtractor.guessCategory(merchant: merchantName, folded: folded)
        fields.terms = TermsFinder.find(in: text)
        if fields.kind.value == .receipt && (fields.terms.notice != nil || fields.terms.autoRenews == true) {
            fields.kind = Found(value: ItemKind.contract, confidence: 0.6)
        }
        fields.suggestedTitle = ReceiptExtractor.suggestedTitle(fields.items, merchant: merchantName)
        return fields
    }

    /// Plain text (a fixture or stored OCR text) read through ReceiptText.lines.
    static func extract(text: String, today: DayDate, fromOCR: Bool = false) -> ReceiptFields {
        ReceiptExtractor.extract(lines: ReceiptText.lines(from: text), today: today, fromOCR: fromOCR)
    }

    // MARK: Merchant

    /// A known shop anywhere in the text, word-bounded (0.9). Otherwise the tallest
    /// early line in the top quarter of the first page that is mostly letters and
    /// not an address, phone, VAT id, web or e-mail address, date or document word,
    /// without its legal suffix and with ALL CAPS in title case (0.6). Otherwise a
    /// web or e-mail domain (0.55).
    static func findMerchant(_ lines: [TextLine]) -> Found<String>? {
        guard !lines.isEmpty else { return nil }
        let folded = lines.map { TextFold.fold($0.text) }

        for entry in Lexicon.knownMerchants {
            if let i = folded.firstIndex(where: { TextFold.containsWord($0, entry.key) }) {
                return Found(value: entry.name, confidence: 0.9, line: i)
            }
        }

        let firstPage = lines.map(\.page).min() ?? 0
        var candidates: [Int] = []
        var rank = 0
        for (i, line) in lines.enumerated() where line.page == firstPage {
            let early = line.y <= 0.25 || rank < 3
            rank += 1
            if early && ReceiptExtractor.isNameLine(line.text) { candidates.append(i) }
        }
        let tallest = candidates.map { lines[$0].height }.max() ?? 0
        if let i = candidates.first(where: { lines[$0].height >= tallest * 0.9 }) {
            let name = ReceiptExtractor.cleanMerchantName(lines[i].text)
            if ReceiptExtractor.hasLetters(name) { return Found(value: name, confidence: 0.6, line: i) }
        }

        for (i, f) in folded.enumerated() {
            if let name = ReceiptExtractor.domainName(f) { return Found(value: name, confidence: 0.55, line: i) }
        }
        return nil
    }

    // MARK: Total

    /// The amount paid. Lines are scored with Lexicon's strong and normal total
    /// labels (an excluded word such as subtotal, VAT, change or tip rules a line
    /// out), and lower lines score a little more. A total corroborated by a payment
    /// line, subtotal minus discounts, net plus VAT or cash minus change gets 0.92;
    /// a label alone 0.8 (strong) or 0.75. With no label, a card or wallet payment
    /// gives 0.6. Otherwise the largest amount is returned as a suggestion only.
    /// An amount alone on the next line belongs to a label on the line above.
    static func findTotal(_ lines: [TextLine], fromOCR: Bool) -> (total: Found<Int64>?, suggestion: Int64?) {
        let rows = ReceiptExtractor.readRows(lines, fromOCR: fromOCR)
        guard !rows.isEmpty else { return (total: nil, suggestion: nil) }
        let facts = ReceiptExtractor.totalFacts(rows)
        let lastIndex = Double(max(rows.count - 1, 1))

        var best: TotalCandidate? = nil
        for row in rows {
            guard let tier = ReceiptExtractor.totalTier(row.folded) else { continue }
            let inside = ReceiptExtractor.saneAmounts(row.text, fromOCR: fromOCR)
            var amountLine = row.index
            var amount: Int64? = row.amount?.minor ?? inside.last?.minor
            if amount == nil, inside.isEmpty, row.index + 1 < rows.count {
                let next = rows[row.index + 1]
                if ReceiptExtractor.isAmountOnly(next), let a = next.amount {
                    amount = a.minor
                    amountLine = next.index
                }
            }
            guard let value = amount, value > 0 else { continue }
            let corroborated = facts.corroborates(value, except: [row.index, amountLine])
            var score = Double(tier * 2) + Double(amountLine) / lastIndex
            if corroborated { score += 1.5 }
            if inside.count >= 2 { score -= 1.5 } // a table row: net, VAT and gross
            if let b = best, b.score >= score { continue }
            best = TotalCandidate(line: amountLine, amount: value, score: score,
                                  strong: tier == 2, corroborated: corroborated)
        }
        if let b = best {
            let confidence = b.corroborated ? 0.92 : (b.strong ? 0.8 : 0.75)
            return (total: Found(value: b.amount, confidence: confidence, line: b.line), suggestion: nil)
        }

        var payment: Seen? = nil
        for p in facts.payments where p.amount > 0 {
            if let current = payment, current.amount >= p.amount { continue }
            payment = p
        }
        if let p = payment {
            return (total: Found(value: p.amount, confidence: 0.6, line: p.line), suggestion: nil)
        }

        var largest: Int64 = 0
        for row in rows where !ReceiptExtractor.has(row.folded, ReceiptExtractor.cashWords)
            && !ReceiptExtractor.has(row.folded, ReceiptExtractor.changeOnlyWords) {
            for a in ReceiptExtractor.saneAmounts(row.text, fromOCR: fromOCR) where a.minor > largest {
                largest = a.minor
            }
        }
        return (total: nil, suggestion: largest > 0 ? largest : nil)
    }

    // MARK: Currency

    /// The currency printed on the total line (0.95), the majority of the markers
    /// in the document (0.8, or 0.65 on a tie), or hints (0.6): a Swiss UID, Swiss
    /// VAT rates, +41 or a Swiss IBAN for CHF; a GB VAT number, a UK postcode or
    /// +44 for GBP; an EU VAT id for EUR. Nil otherwise (Settings decides).
    static func findCurrency(_ lines: [TextLine], totalLine: Int?) -> Found<String>? {
        if let t = totalLine, t >= 0, t < lines.count {
            var codes = ReceiptAmountParser.currencies(in: lines[t].text)
            if codes.isEmpty, t > 0, ReceiptExtractor.isAmountOnlyText(lines[t].text) {
                codes = ReceiptAmountParser.currencies(in: lines[t - 1].text)
            }
            if let code = codes.first { return Found(value: code, confidence: 0.95, line: t) }
        }

        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in lines {
            for code in ReceiptAmountParser.currencies(in: line.text) {
                if counts[code] == nil { order.append(code) }
                counts[code, default: 0] += 1
            }
        }
        if let top = order.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) {
            let topCount = counts[top] ?? 0
            let tied = order.filter { (counts[$0] ?? 0) == topCount }.count > 1
            return Found(value: top, confidence: tied ? 0.65 : 0.8)
        }

        if let hint = ReceiptExtractor.currencyHint(lines) { return Found(value: hint, confidence: 0.6) }
        return nil
    }

    // MARK: VAT

    /// VAT from lines with vat, mwst, ust, tva or iva (registration-number lines
    /// left out) and from the rows of a VAT table. Rates are read as permille. An
    /// amount that matches total × r / (1000 + r), or net × r / 1000, within
    /// max(2 minor units, 1 %) gives 0.9; several rates are summed (0.75, or 0.9
    /// when a printed VAT total agrees); a known rate fitted to an amount gives 0.7;
    /// only a rate printed gives a calculated amount (0.55). VAT is always less
    /// than the total.
    static func findVAT(_ lines: [TextLine], total: Int64?, fromOCR: Bool)
        -> (amount: Found<Int64>?, ratePermille: Found<Int>?, calculated: Bool) {
        let rows = ReceiptExtractor.readRows(lines, fromOCR: fromOCR)
        let limit = total ?? Int64.max
        let nets: [Int64] = rows.compactMap { (row: Row) -> Int64? in
            guard let a = row.amount, a.minor > 0, a.minor < limit,
                  ReceiptExtractor.has(row.folded, ReceiptExtractor.netWords),
                  !ReceiptExtractor.has(row.folded, Lexicon.totalStrong),
                  !ReceiptExtractor.has(row.folded, ReceiptExtractor.taxLineWords) else { return nil }
            return a.minor
        }

        var found: [VATRow] = []
        var tableEnd = -1
        for row in rows {
            let isTax = ReceiptExtractor.has(row.folded, ReceiptExtractor.taxLineWords)
                && !ReceiptExtractor.isRegistration(row)
            var rate = ReceiptExtractor.percentRates(row.text).first
            var body = row.text
            if !isTax {
                // A row of a VAT table: "A 20.0% 207.50 41.50" or "2.6  35.60  0.90".
                guard row.index <= tableEnd, ReceiptExtractor.isTableRow(row) else { continue }
                if rate == nil, let lead = ReceiptExtractor.leadingRate(row.text) {
                    rate = lead.permille
                    body = lead.rest
                }
                guard rate != nil else { continue }
            }
            let every = ReceiptExtractor.vatAmounts(body, fromOCR: fromOCR)
            if isTax && every.isEmpty && ReceiptExtractor.isTableHeader(row) { tableEnd = row.index + 6 }
            let amounts = every.filter { $0 < limit }
            if let r = rate {
                found.append(ReceiptExtractor.ratedRow(row.index, rate: r, amounts: amounts, total: total, nets: nets))
            } else if !amounts.isEmpty {
                found.append(ReceiptExtractor.ratelessRow(row.index, amounts: amounts, total: total, nets: nets))
            }
        }

        // One row per printed rate; a verified row wins.
        var byRate: [Int: VATRow] = [:]
        var rateOrder: [Int] = []
        var printedRates: [Int] = []
        for row in found where !row.fitted {
            guard let r = row.rate else { continue }
            if !printedRates.contains(r) { printedRates.append(r) }
            guard row.amount != nil else { continue }
            if let existing = byRate[r] {
                if !existing.verified && row.verified { byRate[r] = row }
            } else {
                byRate[r] = row
                rateOrder.append(r)
            }
        }
        let rated = rateOrder.compactMap { byRate[$0] }

        if rated.count >= 2 {
            let sum = rated.reduce(Int64(0)) { $0 + ($1.amount ?? 0) }
            if sum > 0 && sum < limit {
                let printedTotal = found.contains { row in
                    guard row.rate == nil || row.fitted, let a = row.amount else { return false }
                    return abs(a - sum) <= 2
                }
                return (amount: Found(value: sum, confidence: printedTotal ? 0.9 : 0.75, line: rated[0].line),
                        ratePermille: nil, calculated: false)
            }
        }
        if let one = rated.first, let a = one.amount, let r = one.rate {
            return (amount: Found(value: a, confidence: one.verified ? 0.9 : 0.6, line: one.line),
                    ratePermille: Found(value: r, confidence: 0.9, line: one.line), calculated: false)
        }
        if let fit = found.first(where: { $0.fitted }), let a = fit.amount, let r = fit.rate {
            return (amount: Found(value: a, confidence: 0.7, line: fit.line),
                    ratePermille: Found(value: r, confidence: 0.7, line: fit.line), calculated: false)
        }
        if let t = total, printedRates.count == 1 {
            let r = printedRates[0]
            let v = Int64((Double(t) * Double(r) / Double(1000 + r)).rounded())
            if v > 0 && v < t {
                return (amount: Found(value: v, confidence: 0.55),
                        ratePermille: Found(value: r, confidence: 0.9), calculated: true)
            }
        }
        if total == nil, let lone = found.first(where: { $0.rate == nil && $0.amount != nil }), let a = lone.amount {
            return (amount: Found(value: a, confidence: 0.5, line: lone.line), ratePermille: nil, calculated: false)
        }
        return (amount: nil, ratePermille: nil, calculated: false)
    }

    // MARK: Dates

    /// The purchase date and, separately, the delivery date. A purchase-date label
    /// on the same line or the line above scores +3, a nearby time +1, a due, valid-
    /// until or expiry label −5 (and rules the date out). Dates more than 1 day in
    /// the future or more than 15 years old are ignored. Confidence: 0.9 with a
    /// label or time, 0.7 for a single date, 0.5 when there are several.
    static func findDates(_ lines: [TextLine], today: DayDate) -> (purchase: Found<DayDate>?, delivery: Found<DayDate>?) {
        let latest = RVCalendar.adding(days: 1, to: today)
        let oldest = RVCalendar.adding(years: -15, to: today)
        let found = lines.map { DateFinder.dates(in: $0.text) }
        let times = lines.map { ReceiptExtractor.matches(ReceiptExtractor.timeOfDay, $0.text) }
        var purchases: [DateCandidate] = []
        var deliveries: [DateCandidate] = []

        for (i, line) in lines.enumerated() where !found[i].isEmpty {
            let ns = line.text as NSString
            var start = 0
            for d in found[i] {
                let before = ns.substring(with: NSRange(location: start, length: max(0, d.location - start)))
                start = d.location + d.length
                guard d.date <= latest, d.date >= oldest else { continue }
                var label = TextFold.fold(before)
                if !ReceiptExtractor.isDateLabel(label), i > 0, found[i - 1].isEmpty {
                    label = ReceiptExtractor.labelAbove(lines[i - 1], line, location: d.location)
                }
                if ReceiptExtractor.has(label, Lexicon.deliveryDateLabels) {
                    deliveries.append(DateCandidate(date: d.date, line: i, score: 0))
                    continue
                }
                var score = 0
                if ReceiptExtractor.has(label, Lexicon.purchaseDateLabels) { score += 3 }
                if ReceiptExtractor.has(label, Lexicon.negativeDateLabels) { score -= 5 }
                let timeAbove = i > 0 && times[i - 1] && found[i - 1].isEmpty
                let timeBelow = i + 1 < lines.count && times[i + 1] && found[i + 1].isEmpty
                if d.hasTime || timeAbove || timeBelow { score += 1 }
                purchases.append(DateCandidate(date: d.date, line: i, score: score))
            }
        }

        var best: DateCandidate? = nil
        for c in purchases where c.score >= 0 {
            if let b = best, b.score >= c.score { continue }
            best = c
        }
        var purchase: Found<DayDate>? = nil
        if let b = best {
            let distinct = Set(purchases.filter { $0.score >= 0 }.map { $0.date })
            let confidence = b.score >= 1 ? 0.9 : (distinct.count == 1 ? 0.7 : 0.5)
            purchase = Found(value: b.date, confidence: confidence, line: b.line)
        }
        var delivery: Found<DayDate>? = nil
        if let d = deliveries.first {
            delivery = Found(value: d.date, confidence: 0.9, line: d.line)
        }
        return (purchase: purchase, delivery: delivery)
    }

    // MARK: Items

    /// Product lines before the total: lines with letters and a trailing amount,
    /// keyword lines left out. 'n x', 'n @', unit prices and codes of 5 or more
    /// digits are removed; a name on the line above a 'Qty 1  249.00' line is used.
    /// At most 30.
    static func findItems(_ lines: [TextLine], before totalLine: Int?, fromOCR: Bool) -> [ItemLine] {
        let rows = ReceiptExtractor.readRows(lines, fromOCR: fromOCR)
        let end = min(max(totalLine ?? rows.count, 0), rows.count)
        var items: [ItemLine] = []
        for row in rows[0..<end] {
            guard items.count < ReceiptExtractor.maxItems else { break }
            guard let amount = row.amount, !amount.isNegative else { continue }
            guard !ReceiptExtractor.has(row.folded, ReceiptExtractor.itemStopWords),
                  !ReceiptExtractor.isPaymentLabel(row.label),
                  !ReceiptExtractor.isDated(row.label) else { continue }
            let own = ReceiptExtractor.cleanItem(row.label, amount: amount.minor)
            var name = own.name
            var quantity = own.quantity
            if !ReceiptExtractor.hasLetters(name), row.index > 0 {
                // The name on the line above, the quantity and price below it.
                let above = rows[row.index - 1]
                if above.amount == nil,
                   !ReceiptExtractor.has(above.folded, ReceiptExtractor.itemStopWords),
                   !ReceiptExtractor.isDated(above.text) {
                    let named = ReceiptExtractor.cleanItem(above.text, amount: nil)
                    name = named.name
                    if quantity == 1 { quantity = named.quantity }
                }
            }
            guard ReceiptExtractor.hasLetters(name) else { continue }
            items.append(ItemLine(name: name, quantity: quantity, amountMinor: amount.minor))
        }
        return items
    }

    // MARK: Guesses

    /// Warranty card, contract, invoice or (otherwise) receipt, by keywords.
    static func guessKind(_ folded: String) -> Found<ItemKind> {
        guard folded.contains(where: { $0.isLetter }) else { return Found(value: ItemKind.receipt, confidence: 0.3) }
        if ReceiptExtractor.hits(folded, Lexicon.warrantyWords) > 0 {
            return Found(value: ItemKind.warranty, confidence: 0.8)
        }
        let compounds = TextFold.words(folded).filter { w in
            ReceiptExtractor.contractSuffixes.contains { w.count > $0.count && w.hasSuffix($0) }
        }
        let contract = ReceiptExtractor.hits(folded, Lexicon.contractWords) + Set(compounds).count
        if contract > 0 { return Found(value: ItemKind.contract, confidence: contract >= 2 ? 0.8 : 0.6) }
        let invoice = ReceiptExtractor.hits(folded, Lexicon.invoiceWords)
        if invoice > 0 { return Found(value: ItemKind.invoice, confidence: invoice >= 2 ? 0.85 : 0.7) }
        let receipt = ReceiptExtractor.hits(folded, ReceiptExtractor.receiptWords)
        return Found(value: ItemKind.receipt, confidence: receipt > 0 ? 0.7 : 0.5)
    }

    /// Online when order, shipping or delivery words appear (0.6, or 0.7 with
    /// several), otherwise in store (0.5). Nil for text without letters.
    static func guessChannel(_ folded: String) -> Found<PurchaseChannel>? {
        guard folded.contains(where: { $0.isLetter }) else { return nil }
        let online = ReceiptExtractor.hits(folded, Lexicon.onlineWords)
            + ReceiptExtractor.hits(folded, Lexicon.deliveryDateLabels)
        if online > 0 { return Found(value: PurchaseChannel.online, confidence: online >= 2 ? 0.7 : 0.6) }
        return Found(value: PurchaseChannel.store, confidence: 0.5)
    }

    /// Whose rules apply, from the currency; a Scottish postcode area (EH, G, AB…)
    /// with pounds gives Scotland. Without a currency, a UK postcode gives a weak
    /// UK guess.
    static func guessJurisdiction(_ text: String, currency: String?) -> Found<Jurisdiction>? {
        let scottish = ReceiptExtractor.hasScottishPostcode(text)
        switch currency ?? "" {
        case "GBP":
            return scottish ? Found(value: Jurisdiction.scotland, confidence: 0.8)
                : Found(value: Jurisdiction.englandWales, confidence: 0.7)
        case "CHF":
            return Found(value: Jurisdiction.switzerland, confidence: 0.7)
        case "EUR":
            return Found(value: Jurisdiction.eu, confidence: 0.7)
        default:
            if scottish { return Found(value: Jurisdiction.scotland, confidence: 0.5) }
            if ReceiptExtractor.matches(ReceiptExtractor.ukPostcode, text) {
                return Found(value: Jurisdiction.englandWales, confidence: 0.5)
            }
            return nil
        }
    }

    /// The known merchant's category (0.7): grocers give groceries, so no warranty
    /// dates are planned. The merchant's name is tried first, then the text.
    static func guessCategory(merchant: String?, folded: String) -> Found<ProductCategory>? {
        if let name = merchant {
            let key = TextFold.fold(name)
            if let hit = Lexicon.knownMerchants.first(where: { TextFold.fold($0.name) == key }) {
                return Found(value: hit.category, confidence: 0.7)
            }
        }
        if let hit = Lexicon.knownMerchants.first(where: { TextFold.containsWord(folded, $0.key) }) {
            return Found(value: hit.category, confidence: 0.7)
        }
        return nil
    }

    // MARK: Pick from document

    /// Reads a tapped line for a field. Total and VAT: the amount at the end of the
    /// line, otherwise the first amount. Dates: the first date. Title, merchant and
    /// notes: the trimmed text. Nil when the line has nothing for the field.
    static func fill(_ field: FillField, fromLine text: String, fromOCR: Bool) -> FillValue? {
        switch field {
        case .total, .vat:
            let amount = ReceiptAmountParser.trailing(in: text, fromOCR: fromOCR)?.amount
                ?? ReceiptAmountParser.all(in: text, fromOCR: fromOCR).first
            guard let a = amount, ReceiptExtractor.isSane(a.minor) else { return nil }
            let currency = a.currency ?? ReceiptAmountParser.currencies(in: text).first
            return .amount(minor: ReceiptExtractor.positive(a.minor), currency: currency)
        case .date, .deliveryDate:
            guard let d = DateFinder.dates(in: text).first else { return nil }
            return .day(d.date)
        case .title, .merchant, .notes:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .text(t)
        }
    }

    // MARK: - Lines

    /// A line read once: its folded text, and the amount at its end with the
    /// label before it.
    private struct Row {
        var index: Int
        var text: String
        var folded: String
        var amount: ReceiptAmount?
        var label: String
    }

    private static let maxItems = 30
    /// Amounts beyond 1 000 000 000.00 are misreads, and could overflow a sum.
    private static let maxMinor: Int64 = 100_000_000_000

    private static func readRows(_ lines: [TextLine], fromOCR: Bool) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            let text = line.text
            var amount: ReceiptAmount? = nil
            var label = text
            if let t = ReceiptAmountParser.trailing(in: text, fromOCR: fromOCR), ReceiptExtractor.isSane(t.amount.minor) {
                amount = t.amount
                label = t.label
            }
            rows.append(Row(index: i, text: text, folded: TextFold.fold(text), amount: amount, label: label))
        }
        return rows
    }

    private static func isSane(_ minor: Int64) -> Bool {
        minor > -ReceiptExtractor.maxMinor && minor < ReceiptExtractor.maxMinor
    }

    private static func positive(_ minor: Int64) -> Int64 {
        minor < 0 ? 0 &- minor : minor
    }

    private static func saneAmounts(_ text: String, fromOCR: Bool) -> [ReceiptAmount] {
        ReceiptAmountParser.all(in: text, fromOCR: fromOCR).filter { ReceiptExtractor.isSane($0.minor) }
    }

    /// Nothing but an amount (and perhaps a currency marker) on the line.
    private static func isAmountOnly(_ row: Row) -> Bool {
        row.amount != nil && !row.label.contains(where: { $0.isLetter || $0.isNumber })
    }

    private static func isAmountOnlyText(_ text: String) -> Bool {
        guard let t = ReceiptAmountParser.trailing(in: text) else { return false }
        return !t.label.contains(where: { $0.isLetter || $0.isNumber })
    }

    private static func has(_ folded: String, _ words: [String]) -> Bool {
        words.contains { TextFold.containsWord(folded, $0) }
    }

    private static func hits(_ folded: String, _ words: [String]) -> Int {
        words.filter { TextFold.containsWord(folded, $0) }.count
    }

    private static func hasLetters(_ s: String) -> Bool {
        s.filter { $0.isLetter }.count >= 2
    }

    private static func isDated(_ s: String) -> Bool {
        !DateFinder.dates(in: s).isEmpty || ReceiptExtractor.matches(ReceiptExtractor.timeOfDay, s)
    }

    // MARK: - Word lists (folded, word-bounded)

    private static let subtotalWords: [String] = [
        "subtotal", "sub-total", "sub total", "zwischensumme", "sous-total", "sous total", "subtotale",
        "zwischentotal",
    ]
    private static let discountWords: [String] = [
        "discount", "rabatt", "remise", "sconto", "savings", "you saved", "reduction", "promo", "promotion",
        "aktion", "coupon",
    ]
    private static let netWords: [String] = [
        "net", "netto", "nettobetrag", "nettosumme", "ht", "hors taxe", "imponibile", "excl", "exkl", "excluding",
    ]
    private static let cashWords: [String] = [
        "cash", "bar", "bargeld", "especes", "contanti", "tendered", "gegeben", "recu",
    ]
    private static let changeOnlyWords: [String] = [
        "change", "ruckgeld", "rueckgeld", "wechselgeld", "rendu", "monnaie", "resto", "zuruck", "zurueck",
    ]
    /// A total label with one of these includes the VAT ("Total incl. VAT", "TTC").
    private static let inclusiveWords: [String] = [
        "incl", "inkl", "including", "inclusive", "inklusive", "ttc", "inclus", "incluse", "compris", "comprise",
        "incluso", "inclusa", "compreso", "compresa", "included", "enthalten",
    ]
    /// Excluded words that do not rule out a total label marked inclusive.
    private static let taxExclusions: [String] = [
        "vat", "v.a.t", "mwst", "ust", "tva", "iva", "mehrwertsteuer", "umsatzsteuer",
    ]
    private static let totalExclusions: [String] = Lexicon.totalExcluded + ["ht"]
    /// Excluded words that do not rule out a total label with an item count.
    private static let countWords: [String] = ["items", "artikel", "articles", "articoli"]
    /// German compounds that name a contract: "Mietvertrag", "Hausratversicherung".
    private static let contractSuffixes: [String] = ["vertrag", "vertrages", "versicherung", "police", "polizza"]
    /// VAT words without the bare "inkl", which also means "including" a cable.
    private static let taxLineWords: [String] = Lexicon.vatWords.filter { $0 != "inkl" }
    /// VAT-number and other registration lines.
    private static let registrationWords: [String] = [
        "nr", "no", "number", "nummer", "numero", "num", "n°", "reg", "registration", "registered", "uid", "id",
        "idnr", "intracom", "intracommunautaire", "siret", "siren", "tin", "piva", "p.iva", "partita",
    ]
    private static let tableHeaderWords: [String] = [
        "rate", "satz", "taux", "aliquota", "net", "netto", "ht", "brutto", "gross", "imponibile", "code", "codice",
        "base",
    ]
    private static let currencyWords: [String] = ["chf", "eur", "gbp", "usd", "sfr"]
    /// Payment words that also appear in product names ("SD card").
    private static let genericPaymentWords: [String] = ["card", "karte", "carte", "debit", "credit", "ec", "cb"]
    private static let receiptWords: [String] = [
        "receipt", "quittung", "kassenbon", "kassenbeleg", "kassenzettel", "beleg", "ticket", "ticket de caisse",
        "scontrino", "ricevuta", "bon",
    ]
    private static let qtyWords: [String] = [
        "qty", "qte", "quantity", "quantite", "menge", "anz", "anzahl", "quantita", "qta",
    ]
    private static let unitWords: [String] = [
        "stk", "stck", "stuck", "stueck", "pcs", "pc", "pce", "pces", "pz", "pezzi", "ea", "each",
    ]
    private static let codeWords: [String] = ["sku", "ean", "plu", "art.-nr", "art.nr", "art-nr", "artnr", "artikelnr"]
    private static let loneMarks: [String] = ["x", "×", "@", "-", "*", "=", "/"]

    /// Keyword lines that are never product lines.
    private static let itemStopWords: [String] = {
        let lists: [[String]] = [
            Lexicon.totalStrong,
            Lexicon.totalNormal,
            Lexicon.totalExcluded,
            ReceiptExtractor.taxLineWords,
            Lexicon.paymentWords.filter { !ReceiptExtractor.genericPaymentWords.contains($0) },
            Lexicon.changeWords.filter { $0 != "bar" },
            ["balance", "saldo", "solde", "shipping", "versand", "versandkosten", "porto", "delivery", "lieferung",
             "livraison", "frais de port", "spedizione", "tax", "steuer", "paid", "bezahlt", "paye", "pagato"],
        ]
        return lists.flatMap { $0 }
    }()

    // Merchant-line noise.
    private static let phoneWords: [String] = [
        "tel", "telefon", "telephone", "phone", "fon", "fax", "mobile", "mob", "natel", "hotline",
    ]
    private static let strongStreetWords: [String] = [
        "street", "road", "avenue", "lane", "strasse", "gasse", "platz", "allee", "rue", "boulevard", "chemin",
        "quai", "via", "viale", "piazza", "piazzale", "corso", "vicolo",
    ]
    /// Street words that only count next to a house number.
    private static let weakStreetWords: [String] = ["st", "rd", "ave", "ln", "route", "place", "weg", "str"]
    private static let streetSuffixes: [String] = ["strasse", "str", "gasse", "weg", "platz", "allee"]
    private static let noiseWords: [String] = [
        "filiale", "branch", "kasse", "till", "cashier", "kassierer", "caisse", "cassa", "served by", "bedient",
        "operator",
    ]
    /// E-mail providers, never the merchant.
    private static let genericDomains: [String] = [
        "gmail", "googlemail", "outlook", "hotmail", "yahoo", "icloud", "me", "gmx", "web", "bluewin", "sunrise",
        "t-online", "live", "aol", "protonmail", "proton", "orange", "free", "wanadoo", "libero", "mail", "email",
        "example",
    ]
    private static let swissRates: [Int] = [81, 26, 38, 77, 25, 37]
    /// "TOTALE EURO 12,50": the word, which ReceiptAmountParser does not treat as a marker.
    private static let euroWords: [String] = ["euro", "euros"]
    /// Italy's VAT number ("P.IVA"); Ticino receipts print "IVA" with francs.
    private static let italianVATWords: [String] = ["p.iva", "p. iva", "partita iva", "piva"]

    // MARK: - Patterns

    /// Raw-string patterns; one that fails to compile finds nothing rather than crashing.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re = re else { return false }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in ns: NSString) -> String? {
        guard i < m.numberOfRanges else { return nil }
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    /// "20%", "8.1 %", "20,00%" (group 1 is the number). Not part of "100%".
    private static let percentRate = ReceiptExtractor.regex(#"(?<![\d.,])(\d{1,2}(?:[.,]\d{1,3})?)\s?%"#)
    /// "14:32", "9:05", "14h32".
    private static let timeOfDay = ReceiptExtractor.regex(#"(?<![\d:])(?:[01]?\d|2[0-3])[:hH][0-5]\d(?!\d)"#)
    /// "EH1 1YZ", "SW1A 1AA", "G2 3AB" (group 1 is the area).
    private static let ukPostcode = ReceiptExtractor.regex(#"(?<![A-Z0-9])([A-Z]{1,2})([0-9][A-Z0-9]?) ?([0-9][A-Z]{2})(?![A-Z0-9])"#)
    private static let swissUID = ReceiptExtractor.regex(#"CHE[-\s]?\d{3}[.\s]?\d{3}[.\s]?\d{3}"#)
    private static let gbVAT = ReceiptExtractor.regex(#"(?<![A-Z0-9])GB\s?\d{3}\s?\d{4}\s?\d{2}(?!\d)"#)
    private static let euVAT = ReceiptExtractor.regex(#"(?<![A-Z0-9])(?:DE\s?\d{9}|ATU\s?\d{8}|FR\s?[A-Z0-9]{2}\s?\d{9}|IT\s?\d{11}|NL\s?\d{9}B\d{2}|BE\s?0?\d{9}|IE\s?\d{7}[A-Z]{1,2}|ES\s?[A-Z0-9]\d{7}[A-Z0-9]|PT\s?\d{9}|LU\s?\d{8})(?![A-Z0-9])"#)
    private static let swissPhone = ReceiptExtractor.regex(#"(?:\+|(?<!\d)00)\s?41[\s(]*\d"#)
    private static let ukPhone = ReceiptExtractor.regex(#"(?:\+|(?<!\d)00)\s?44[\s(]*\d"#)
    private static let swissIBAN = ReceiptExtractor.regex(#"(?<![A-Z0-9])CH\d{2}\s?\d{4}\s?\d"#)
    private static let longDigits = ReceiptExtractor.regex(#"\d{8,}"#)
    /// A web or e-mail address in folded text.
    private static let urlLike = ReceiptExtractor.regex(#"www\.|https?:|@|[a-z0-9-]\.(?:co\.uk|com|ch|de|fr|it|at|eu|net|org|uk|ie|nl|be|es)(?![\p{L}\d])"#)
    /// "www.johnlewis.com", "mueller-baeckerei.ch" (group 1 is the name).
    private static let webDomain = ReceiptExtractor.regex(#"(?<![\p{L}\d.@-])(?:https?://)?(?:www\.)?([a-z0-9][a-z0-9-]{1,40})\.(?:co\.uk|com|ch|de|fr|it|at|eu|net|org|uk|ie|nl|be|es)(?![\p{L}\d])"#)
    private static let mailDomain = ReceiptExtractor.regex(#"@([a-z0-9][a-z0-9-]{1,40})\.(?:co\.uk|com|ch|de|fr|it|at|eu|net|org|uk|ie|nl|be|es)(?![\p{L}\d])"#)
    /// "2 x 9.99", "2 @ £9.99": the quantity and unit price.
    private static let unitPrice = ReceiptExtractor.regex(#"(?<![\p{L}\d])(\d{1,3})\s?[xX×@]\s?(?:£|€|\$|CHF\s?|EUR\s?|GBP\s?|Fr\.\s?)?\d+[.,]\d{2}(?!\d)"#)
    /// "2 x " or "2x " in front.
    private static let leadingQuantity = ReceiptExtractor.regex(#"^\s*(\d{1,3})\s?[xX×@]\s+"#)
    /// " x2" at the end.
    private static let trailingTimes = ReceiptExtractor.regex(#"\s[xX×]\s?(\d{1,3})\s*$"#)
    /// " 2x" at the end.
    private static let trailingCount = ReceiptExtractor.regex(#"\s(\d{1,3})\s?[xX×]\s*$"#)
    /// A rate printed as a bare number in a VAT table: "2.6", "8.10", "20".
    private static let rateToken = ReceiptExtractor.regex(#"^\d{1,2}(?:[.,]\d{1,2})?%?$"#)
    /// A house number at the start or end: "12 High Street", "Bahnhofstrasse 5".
    private static let houseNumberEdge = ReceiptExtractor.regex(#"^\d{1,4}[a-zA-Z]?\b|\b\d{1,4}[a-zA-Z]?$"#)
    /// An item count in folded text: "3 items", "2 artikel".
    private static let itemCount = ReceiptExtractor.regex(#"(?<![\d.,])\d{1,3}\s?(?:items?|artikel|articles?|articoli)(?![\p{L}\d])"#)

    // MARK: - Total helpers

    private struct TotalCandidate {
        var line: Int
        var amount: Int64
        var score: Double
        var strong: Bool
        var corroborated: Bool
    }

    /// An amount (always positive) and the line it is on.
    private struct Seen {
        var line: Int
        var amount: Int64
    }

    /// The other amounts on a receipt that can confirm a total.
    private struct TotalFacts {
        var payments: [Seen] = []
        var subtotals: [Seen] = []
        var discounts: [Seen] = []
        var nets: [Seen] = []
        var taxes: [Seen] = []
        var cash: [Seen] = []
        var change: [Seen] = []

        /// A payment of the same amount, subtotal minus discounts, net plus VAT or
        /// cash minus change, ignoring the candidate's own lines.
        func corroborates(_ total: Int64, except used: [Int]) -> Bool {
            func others(_ list: [Seen]) -> [Int64] {
                list.filter { !used.contains($0.line) }.map { $0.amount }
            }
            if others(payments).contains(total) || others(cash).contains(total) { return true }
            let discount = others(discounts).reduce(Int64(0), +)
            if others(subtotals).contains(where: { abs($0 - discount - total) <= 1 }) { return true }
            let taxAmounts = others(taxes)
            let taxSum = taxAmounts.reduce(Int64(0), +)
            for net in others(nets) {
                if taxAmounts.contains(where: { abs(net + $0 - total) <= 1 }) { return true }
                if taxAmounts.count > 1 && abs(net + taxSum - total) <= 1 { return true }
            }
            let changes = others(change)
            for given in others(cash) where changes.contains(where: { given - $0 == total }) { return true }
            return false
        }
    }

    private static func totalFacts(_ rows: [Row]) -> TotalFacts {
        var facts = TotalFacts()
        for row in rows {
            guard let a = row.amount, a.minor != 0 else { continue }
            let seen = Seen(line: row.index, amount: ReceiptExtractor.positive(a.minor))
            let f = row.folded
            if ReceiptExtractor.has(f, ReceiptExtractor.discountWords) {
                facts.discounts.append(seen)
            } else if ReceiptExtractor.has(f, ReceiptExtractor.subtotalWords) {
                facts.subtotals.append(seen)
            } else if ReceiptExtractor.has(f, ReceiptExtractor.taxLineWords), !ReceiptExtractor.isRegistration(row),
                      ReceiptExtractor.totalTier(f) == nil {
                facts.taxes.append(seen)
            } else if ReceiptExtractor.has(f, ReceiptExtractor.netWords), !ReceiptExtractor.has(f, Lexicon.totalStrong) {
                facts.nets.append(seen)
            } else if ReceiptExtractor.has(f, ReceiptExtractor.changeOnlyWords) {
                facts.change.append(seen)
            } else if ReceiptExtractor.has(f, ReceiptExtractor.cashWords) {
                facts.cash.append(seen)
            } else if ReceiptExtractor.has(f, Lexicon.paymentWords), !ReceiptExtractor.has(f, Lexicon.totalExcluded) {
                facts.payments.append(seen)
            }
        }
        return facts
    }

    /// 2 for a strong total label, 1 for a normal one, nil for none or an excluded
    /// one. "net" inside "net a payer", or VAT in "Total incl. VAT", does not exclude.
    private static func totalTier(_ folded: String) -> Int? {
        let strong = Lexicon.totalStrong.filter { TextFold.containsWord(folded, $0) }
        let normal = Lexicon.totalNormal.filter { TextFold.containsWord(folded, $0) }
        guard !strong.isEmpty || !normal.isEmpty else { return nil }
        let inclusive = ReceiptExtractor.has(folded, ReceiptExtractor.inclusiveWords)
        let counted = ReceiptExtractor.matches(ReceiptExtractor.itemCount, folded)
        for word in ReceiptExtractor.totalExclusions where TextFold.containsWord(folded, word) {
            if strong.contains(where: { TextFold.containsWord($0, word) }) { continue }
            if inclusive && ReceiptExtractor.taxExclusions.contains(word) { continue }
            if counted && ReceiptExtractor.countWords.contains(word) { continue } // "Total (3 items)"
            return nil
        }
        return strong.isEmpty ? 1 : 2
    }

    // MARK: - Currency helpers

    private static func currencyHint(_ lines: [TextLine]) -> String? {
        let text = lines.map(\.text).joined(separator: "\n")
        var chf = 0
        var gbp = 0
        var eur = 0
        if ReceiptExtractor.matches(ReceiptExtractor.swissUID, text) { chf += 2 }
        if ReceiptExtractor.matches(ReceiptExtractor.swissPhone, text) { chf += 1 }
        if ReceiptExtractor.matches(ReceiptExtractor.swissIBAN, text) { chf += 1 }
        for line in lines where ReceiptExtractor.has(TextFold.fold(line.text), ReceiptExtractor.taxLineWords) {
            for r in ReceiptExtractor.percentRates(line.text) where ReceiptExtractor.swissRates.contains(r) { chf += 1 }
        }
        if ReceiptExtractor.matches(ReceiptExtractor.gbVAT, text) { gbp += 2 }
        if ReceiptExtractor.matches(ReceiptExtractor.ukPostcode, text) { gbp += 1 }
        if ReceiptExtractor.matches(ReceiptExtractor.ukPhone, text) { gbp += 1 }
        if ReceiptExtractor.matches(ReceiptExtractor.euVAT, text) { eur += 2 }
        let folded = TextFold.fold(text)
        if ReceiptExtractor.has(folded, ReceiptExtractor.euroWords) { eur += 2 }
        if ReceiptExtractor.has(folded, ReceiptExtractor.italianVATWords) { eur += 1 }
        let top = max(chf, gbp, eur)
        guard top > 0 else { return nil }
        if chf == top { return "CHF" }
        if gbp == top { return "GBP" }
        return "EUR"
    }

    private static func hasScottishPostcode(_ text: String) -> Bool {
        guard let re = ReceiptExtractor.ukPostcode else { return false }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let area = ReceiptExtractor.group(m, 1, in: ns), Lexicon.scottishPostcodeAreas.contains(area) {
                return true
            }
        }
        return false
    }

    // MARK: - VAT helpers

    /// A VAT line or table row: its printed or fitted rate and the VAT amount chosen.
    private struct VATRow {
        var line: Int
        var rate: Int?
        var amount: Int64?
        /// The amount matched the total, the net or another amount on the row.
        var verified: Bool
        /// No rate was printed; `rate` is a known rate that fits the amount.
        var fitted: Bool = false
    }

    private static func isRegistration(_ row: Row) -> Bool {
        ReceiptExtractor.has(row.folded, ReceiptExtractor.registrationWords)
            || ReceiptExtractor.matches(ReceiptExtractor.longDigits, row.text)
            || ReceiptExtractor.matches(ReceiptExtractor.swissUID, row.text)
            || ReceiptExtractor.matches(ReceiptExtractor.gbVAT, row.text)
    }

    /// A VAT line without amounts that heads a table: "VAT RATE NET VAT", "MWST%".
    private static func isTableHeader(_ row: Row) -> Bool {
        if row.text.contains("%") { return true }
        let words = TextFold.words(row.text)
        return words.contains { ReceiptExtractor.tableHeaderWords.contains($0) }
    }

    /// Numbers and codes only: no word of three or more letters but a currency.
    private static func isTableRow(_ row: Row) -> Bool {
        let words = TextFold.words(row.text).filter { w in
            w.count >= 3 && w.allSatisfy({ $0.isLetter }) && !ReceiptExtractor.currencyWords.contains(w)
        }
        return words.isEmpty
    }

    /// Printed rates in permille, 1...300 (0.1 % to 30 %).
    private static func percentRates(_ text: String) -> [Int] {
        guard let re = ReceiptExtractor.percentRate else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            (m: NSTextCheckingResult) -> Int? in
            guard let number = ReceiptExtractor.group(m, 1, in: ns) else { return nil }
            return ReceiptExtractor.permille(number)
        }
    }

    /// "20" -> 200, "8.1" -> 81, "2,60" -> 26, "5.5%" -> 55. Nil outside 1...300.
    private static func permille(_ s: String) -> Int? {
        let clean = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
        guard let v = Double(clean), v.isFinite, v >= 0, v < 100 else { return nil }
        let p = Int((v * 10).rounded())
        return (1...300).contains(p) ? p : nil
    }

    /// A known rate as the first number of a table row ("2.6  35.60  0.90"),
    /// perhaps after a one-character code ("B 8.10 …"), and the rest of the row.
    private static func leadingRate(_ text: String) -> (permille: Int, rest: String)? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        let codeTrim = CharacterSet(charactersIn: "()[]=:*")
        for skip in 0...1 where tokens.count >= skip + 2 {
            if skip == 1 && tokens[0].trimmingCharacters(in: codeTrim).count != 1 { return nil }
            guard ReceiptExtractor.matches(ReceiptExtractor.rateToken, tokens[skip]),
                  let p = ReceiptExtractor.permille(tokens[skip]),
                  Lexicon.knownVATRatesPermille.contains(p) else { continue }
            var rest = tokens
            rest.removeSubrange(0...skip)
            return (permille: p, rest: rest.joined(separator: " "))
        }
        return nil
    }

    /// The positive amounts on a VAT line, with printed rates taken out first.
    private static func vatAmounts(_ text: String, fromOCR: Bool) -> [Int64] {
        var stripped = text
        if let re = ReceiptExtractor.percentRate {
            let ns = text as NSString
            stripped = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                   withTemplate: " ")
        }
        return ReceiptExtractor.saneAmounts(stripped, fromOCR: fromOCR)
            .map { ReceiptExtractor.positive($0.minor) }
            .filter { $0 > 0 }
    }

    /// VAT included in a gross amount at `rate` permille.
    private static func inclusive(_ gross: Int64, _ rate: Int) -> Double {
        Double(gross) * Double(rate) / Double(1000 + rate)
    }

    /// VAT added to a net amount at `rate` permille.
    private static func exclusive(_ net: Int64, _ rate: Int) -> Double {
        Double(net) * Double(rate) / 1000
    }

    /// max(2 minor units, 1 %).
    private static func tolerance(_ amount: Int64) -> Double {
        max(2, Double(amount) / 100)
    }

    private static func close(_ amount: Int64, _ expected: Double) -> Bool {
        abs(Double(amount) - expected) <= ReceiptExtractor.tolerance(amount)
    }

    /// A row with a printed rate: an amount confirmed by another amount on the row,
    /// the total or the net; otherwise the smallest amount if VAT at that rate
    /// could be so large.
    private static func ratedRow(_ line: Int, rate r: Int, amounts: [Int64], total: Int64?, nets: [Int64]) -> VATRow {
        let sorted = amounts.sorted()
        for (k, a) in sorted.enumerated() {
            for b in sorted[(k + 1)...] where b > a {
                if ReceiptExtractor.close(a, ReceiptExtractor.inclusive(b, r))
                    || ReceiptExtractor.close(a, ReceiptExtractor.exclusive(b, r)) {
                    return VATRow(line: line, rate: r, amount: a, verified: true)
                }
            }
        }
        if let t = total, let a = sorted.first(where: { ReceiptExtractor.close($0, ReceiptExtractor.inclusive(t, r)) }) {
            return VATRow(line: line, rate: r, amount: a, verified: true)
        }
        for n in nets {
            if let a = sorted.first(where: { ReceiptExtractor.close($0, ReceiptExtractor.exclusive(n, r)) }) {
                return VATRow(line: line, rate: r, amount: a, verified: true)
            }
        }
        if let a = sorted.first {
            if let t = total {
                if Double(a) <= ReceiptExtractor.inclusive(t, r) + ReceiptExtractor.tolerance(a) {
                    return VATRow(line: line, rate: r, amount: a, verified: false)
                }
            } else if sorted.count == 1 {
                return VATRow(line: line, rate: r, amount: a, verified: false)
            }
        }
        return VATRow(line: line, rate: r, amount: nil, verified: false)
    }

    /// A row without a rate: the known rate that best fits an amount against the
    /// total, the net or another amount on the row.
    private static func ratelessRow(_ line: Int, amounts: [Int64], total: Int64?, nets: [Int64]) -> VATRow {
        var best: (amount: Int64, rate: Int, miss: Double)? = nil
        func consider(_ a: Int64, _ r: Int, _ expected: Double) {
            let miss = abs(Double(a) - expected)
            guard miss <= ReceiptExtractor.tolerance(a) else { return }
            if let b = best, b.miss <= miss { return }
            best = (amount: a, rate: r, miss: miss)
        }
        let sorted = amounts.sorted()
        for r in Lexicon.knownVATRatesPermille {
            for (k, a) in sorted.enumerated() {
                if let t = total { consider(a, r, ReceiptExtractor.inclusive(t, r)) }
                for n in nets { consider(a, r, ReceiptExtractor.exclusive(n, r)) }
                for b in sorted[(k + 1)...] where b > a {
                    consider(a, r, ReceiptExtractor.inclusive(b, r))
                    consider(a, r, ReceiptExtractor.exclusive(b, r))
                }
            }
        }
        if let b = best {
            return VATRow(line: line, rate: b.rate, amount: b.amount, verified: false, fitted: true)
        }
        return VATRow(line: line, rate: nil, amount: sorted.count == 1 ? sorted[0] : nil, verified: false)
    }

    // MARK: - Date helpers

    private struct DateCandidate {
        var date: DayDate
        var line: Int
        var score: Int
    }

    private static func isDateLabel(_ folded: String) -> Bool {
        ReceiptExtractor.has(folded, Lexicon.purchaseDateLabels)
            || ReceiptExtractor.has(folded, Lexicon.deliveryDateLabels)
            || ReceiptExtractor.has(folded, Lexicon.negativeDateLabels)
    }

    /// The label above a date, folded: the cell nearest the date's cell when both
    /// lines have several cells ("Rechnungsdatum  Lieferdatum" over two dates),
    /// otherwise the whole line.
    private static func labelAbove(_ above: TextLine, _ line: TextLine, location: Int) -> String {
        guard above.cells.count >= 2, line.cells.count >= 2 else { return TextFold.fold(above.text) }
        var start = 0
        var cell = line.cells[0]
        for c in line.cells {
            if location >= start { cell = c }
            start += (c.text as NSString).length + 1
        }
        var nearest = above.cells[0]
        for c in above.cells where abs(c.center - cell.center) < abs(nearest.center - cell.center) {
            nearest = c
        }
        return TextFold.fold(nearest.text)
    }

    // MARK: - Item helpers

    /// A lone card word ("CARD", "Visa debit" is caught by the stop words).
    private static func isPaymentLabel(_ label: String) -> Bool {
        let words = TextFold.words(label).filter { w in w.contains(where: { $0.isLetter }) }
        return !words.isEmpty && words.allSatisfy { ReceiptExtractor.genericPaymentWords.contains($0) }
    }

    /// The product name and quantity in an item label (the text before its amount).
    /// `amount` is the line's amount, if known. The name may come back empty.
    private static func cleanItem(_ label: String, amount: Int64?) -> (name: String, quantity: Int) {
        var s = ReceiptAmountParser.normalise(label)
        var quantity = 1
        for pattern in [ReceiptExtractor.unitPrice, ReceiptExtractor.leadingQuantity,
                        ReceiptExtractor.trailingTimes, ReceiptExtractor.trailingCount] {
            guard let re = pattern else { continue }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            if quantity == 1, let n = Int(ReceiptExtractor.group(m, 1, in: ns) ?? ""), (1...999).contains(n) {
                quantity = n
            }
            s = ns.replacingCharacters(in: m.range, with: " ")
        }

        // Amounts left in the label are unit prices; codes, currencies and rates go.
        let edge = CharacterSet(charactersIn: "#:()[],.")
        var tokens: [String] = []
        var prices: [Int64] = []
        for t in s.split(whereSeparator: { $0.isWhitespace }).map({ String($0) }) {
            if t.contains("%") || ReceiptExtractor.loneMarks.contains(t) { continue }
            if let price = ReceiptAmountParser.parse(t) {
                if price.minor > 0 && ReceiptExtractor.isSane(price.minor) { prices.append(price.minor) }
                continue
            }
            if ReceiptAmountParser.currencyCode(forSymbol: t) != nil { continue }
            let bare = t.trimmingCharacters(in: edge)
            if bare.count >= 5 && bare.allSatisfy({ $0.isASCII && $0.isNumber }) { continue }
            let folded = TextFold.fold(t).trimmingCharacters(in: CharacterSet(charactersIn: ".:#"))
            if ReceiptExtractor.codeWords.contains(folded) { continue }
            tokens.append(t)
        }

        // "Qty 1", "Menge: 2", and "2 Stk." or "1 pcs".
        var i = 0
        while i < tokens.count {
            let word = TextFold.fold(tokens[i]).trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            if ReceiptExtractor.qtyWords.contains(word) {
                if i + 1 < tokens.count, let n = Int(tokens[i + 1]), (1...999).contains(n) {
                    if quantity == 1 { quantity = n }
                    tokens.removeSubrange(i...(i + 1))
                } else {
                    tokens.remove(at: i)
                }
                continue
            }
            if ReceiptExtractor.unitWords.contains(word) {
                if i > 0, let n = Int(tokens[i - 1]), (1...999).contains(n) {
                    if quantity == 1 { quantity = n }
                    tokens.removeSubrange((i - 1)...i)
                    i -= 1
                } else {
                    tokens.remove(at: i)
                }
                continue
            }
            i += 1
        }

        func isCount(_ t: String) -> Bool {
            !t.isEmpty && t.count <= 3 && t.allSatisfy { $0.isASCII && $0.isNumber }
        }
        // "Monitor arm  2  35.00  70.00": a count that times a unit price gives the
        // line amount is the quantity ("iPhone 15  999.00  999.00" keeps its 15).
        if let lineAmount = amount, tokens.count >= 2, let last = tokens.last, isCount(last),
           let n = Int(last), n >= 1, prices.contains(where: { Int64(n) * $0 == lineAmount }) {
            if quantity == 1 { quantity = n }
            tokens.removeLast()
        }
        // "1  Kaffeevollautomat  1": a position number, the name and a quantity of 1;
        // "2 Apple iPhone 15": a quantity in front.
        if tokens.count >= 3, isCount(tokens[0]), tokens[tokens.count - 1] == "1" {
            tokens.removeLast()
            tokens.removeFirst()
        } else if tokens.count >= 2, tokens[0].count <= 2, isCount(tokens[0]),
                  tokens[1].contains(where: { $0.isLetter }) {
            if quantity == 1, let n = Int(tokens[0]), (1...99).contains(n) { quantity = n }
            tokens.removeFirst()
        }

        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—*.,:;#=_|/\\+"))
        let name = tokens.joined(separator: " ").trimmingCharacters(in: trim)
        return (name: name, quantity: quantity)
    }

    /// The most expensive item's name, otherwise the merchant.
    private static func suggestedTitle(_ items: [ItemLine], merchant: String?) -> String? {
        var top: ItemLine? = nil
        for item in items {
            guard let a = item.amountMinor, a > 0 else { continue }
            if let t = top, (t.amountMinor ?? 0) >= a { continue }
            top = item
        }
        return top?.name ?? merchant
    }

    // MARK: - Merchant helpers

    /// Mostly letters, short, and none of: document word, phone, VAT id, address,
    /// postcode, web or e-mail address, date, time, amount or total label.
    private static func isNameLine(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 48 else { return false }
        let visible = text.filter { !$0.isWhitespace }
        let letters = visible.filter { $0.isLetter }.count
        guard letters >= 2, Double(letters) >= 0.6 * Double(visible.count) else { return false }
        let digits = visible.filter { $0.isASCII && $0.isNumber }.count
        if digits >= 2 { return false }
        if digits == 1 && ReceiptExtractor.matches(ReceiptExtractor.houseNumberEdge, text) { return false }

        let folded = TextFold.fold(text)
        let words = TextFold.words(text)
        guard words.count <= 6 else { return false }
        let noise: [[String]] = [
            Lexicon.documentWords, Lexicon.warrantyWords, Lexicon.invoiceWords, ReceiptExtractor.phoneWords,
            ReceiptExtractor.taxLineWords, ReceiptExtractor.strongStreetWords, ReceiptExtractor.noiseWords,
            Lexicon.totalStrong, Lexicon.totalNormal,
        ]
        if noise.contains(where: { ReceiptExtractor.has(folded, $0) }) { return false }
        if words.contains(where: { ReceiptExtractor.isStreetCompound($0) }) { return false }
        if digits == 1 && ReceiptExtractor.has(folded, ReceiptExtractor.weakStreetWords) { return false }
        if TextFold.containsWord(folded, "uid") || ReceiptExtractor.matches(ReceiptExtractor.urlLike, folded) {
            return false
        }
        if ReceiptExtractor.matches(ReceiptExtractor.ukPostcode, text) || ReceiptExtractor.isDated(text) { return false }
        return ReceiptAmountParser.trailing(in: text) == nil
    }

    /// "bahnhofstrasse", "hauptstr", "marktgasse", "rosenweg".
    private static func isStreetCompound(_ word: String) -> Bool {
        ReceiptExtractor.streetSuffixes.contains { word.count > $0.count && word.hasSuffix($0) }
    }

    /// Without decoration, the legal suffix ("GmbH", "AG", "& Co. KG", "Ltd.") and,
    /// for ALL CAPS, in title case: "BÄCKEREI MÜLLER AG" -> "Bäckerei Müller".
    private static func cleanMerchantName(_ raw: String) -> String {
        let decor = CharacterSet.whitespaces.union(.punctuationCharacters).union(.symbols)
        let dots = CharacterSet(charactersIn: ".,;:()")
        let joiners = ["&", "+", "and", "und", "et"]
        var words = raw.trimmingCharacters(in: decor).split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        while words.count > 1 {
            let last = TextFold.fold(words[words.count - 1]).trimmingCharacters(in: dots)
            if last.isEmpty || last == "&" || last == "+" || last == "-" || Lexicon.legalSuffixes.contains(last) {
                words.removeLast()
                continue
            }
            if last == "co" || last == "cie", words.count > 2, joiners.contains(TextFold.fold(words[words.count - 2])) {
                words.removeLast(2)
                continue
            }
            break
        }
        var name = words.joined(separator: " ").trimmingCharacters(in: decor)
        let letters = name.filter { $0.isLetter }
        if letters.count >= 2 && !letters.contains(where: { $0.isLowercase }) {
            name = ReceiptExtractor.titleCased(name)
        }
        return name
    }

    /// "BÄCKEREI MÜLLER" -> "Bäckerei Müller", "E.LECLERC" -> "E.Leclerc", "O'NEILL" -> "O'neill".
    private static func titleCased(_ s: String) -> String {
        var out = ""
        var startOfWord = true
        for c in s {
            if c.isLetter {
                out += startOfWord ? String(c).uppercased() : String(c).lowercased()
                startOfWord = false
            } else {
                out.append(c)
                startOfWord = !(c.isNumber || c == "'" || c == "’")
            }
        }
        return out
    }

    /// The name in a web or e-mail domain, e.g. "mueller-baeckerei.ch" -> "Mueller Baeckerei".
    private static func domainName(_ folded: String) -> String? {
        let ns = folded as NSString
        for pattern in [ReceiptExtractor.webDomain, ReceiptExtractor.mailDomain] {
            guard let re = pattern else { continue }
            for m in re.matches(in: folded, range: NSRange(location: 0, length: ns.length)) {
                guard let label = ReceiptExtractor.group(m, 1, in: ns),
                      !ReceiptExtractor.genericDomains.contains(label) else { continue }
                let parts = label.split(separator: "-").map { (w: Substring) -> String in
                    String(w.prefix(1)).uppercased() + String(w.dropFirst())
                }
                let name = parts.joined(separator: " ")
                if ReceiptExtractor.hasLetters(name) { return name }
            }
        }
        return nil
    }
}
