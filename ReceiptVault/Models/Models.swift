import Foundation
import SwiftData

// The SwiftData schema: [VaultItem, StoredFile, Deadline].
// Every stored property has a default, enums are stored as String raw values
// behind typed wrappers, money is Int64 minor units and calendar days are
// Dates at UTC midnight (RVCalendar.date(_:) / RVCalendar.day(_:)). Stored
// names and raw values are frozen once released. Fetch with
// FetchDescriptor<T>() and filter in Swift: there is no #Predicate anywhere.

@Model
final class VaultItem {
    // Identity and kind
    var id: UUID = UUID()
    var kindRaw: String = ItemKind.receipt.rawValue
    var title: String = ""
    var merchant: String = ""

    // Dates (UTC midnight)
    var purchaseDate: Date = Date()
    var deliveryDate: Date? = nil

    // Amounts, in minor units of `currency`
    var totalMinor: Int64? = nil
    var currency: String = "GBP"
    var vatMinor: Int64? = nil
    /// 200 = 20.0 %, 81 = 8.1 %.
    var vatRatePermille: Int? = nil

    // Classification
    var jurisdictionRaw: String = Jurisdiction.englandWales.rawValue
    var channelRaw: String = PurchaseChannel.store.rawValue
    var categoryRaw: String = ProductCategory.otherGoods.rawValue
    var taxTagRaw: String = TaxTag.none.rawValue
    var isUsed: Bool = false

    // Fault
    var hasIssue: Bool = false
    var issueNotedAt: Date? = nil

    // Rule inputs
    var returnDays: Int? = nil
    var returnDaysIsPrinted: Bool = false
    var warrantyMonths: Int? = nil
    var warrantyIsPrinted: Bool = false

    // Contract
    var contractPresetID: String = ""
    /// The first term end, as entered (UTC midnight).
    var termEnd: Date? = nil
    var autoRenews: Bool = true
    var renewalMonths: Int = 12
    var noticeValue: Int = 3
    var noticeUnitRaw: String = NoticePeriod.Unit.months.rawValue
    var cancelled: Bool = false
    var noticeSentAt: Date? = nil

    // Text
    /// One 'name\tqty\tamountMinor' per line; the amount is empty when unknown.
    var itemLines: String = ""
    var notes: String = ""
    var ocrText: String = ""

    // Search and review
    var searchBlob: String = ""
    var needsReview: Bool = false
    /// Comma-separated FillField raw values still marked 'Please check'.
    var checkFields: String = ""

    // Housekeeping
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \StoredFile.item)
    var files: [StoredFile] = []
    @Relationship(deleteRule: .cascade, inverse: \Deadline.item)
    var deadlines: [Deadline] = []

    init(kind: ItemKind, purchaseDay: DayDate) {
        let now = Date()
        self.kindRaw = kind.rawValue
        self.purchaseDate = RVCalendar.date(purchaseDay)
        self.createdAt = now
        self.updatedAt = now
    }

    // MARK: Typed wrappers

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? ItemKind.receipt }
        set { kindRaw = newValue.rawValue }
    }

    var jurisdiction: Jurisdiction {
        get { Jurisdiction(rawValue: jurisdictionRaw) ?? Jurisdiction.englandWales }
        set { jurisdictionRaw = newValue.rawValue }
    }

    var channel: PurchaseChannel {
        get { PurchaseChannel(rawValue: channelRaw) ?? PurchaseChannel.store }
        set { channelRaw = newValue.rawValue }
    }

    var category: ProductCategory {
        get { ProductCategory(rawValue: categoryRaw) ?? ProductCategory.otherGoods }
        set { categoryRaw = newValue.rawValue }
    }

    var taxTag: TaxTag {
        get { TaxTag(rawValue: taxTagRaw) ?? TaxTag.none }
        set { taxTagRaw = newValue.rawValue }
    }

    var notice: NoticePeriod {
        get {
            let unit = NoticePeriod.Unit(rawValue: noticeUnitRaw) ?? NoticePeriod.Unit.months
            return NoticePeriod(value: noticeValue, unit: unit)
        }
        set {
            noticeValue = newValue.value
            noticeUnitRaw = newValue.unit.rawValue
        }
    }

    // MARK: Days

    var purchaseDay: DayDate {
        get { RVCalendar.day(purchaseDate) }
        set { purchaseDate = RVCalendar.date(newValue) }
    }

    var deliveryDay: DayDate? {
        get { deliveryDate.map { RVCalendar.day($0) } }
        set { deliveryDate = newValue.map { RVCalendar.date($0) } }
    }

    /// The first term end, as entered.
    var termEndDay: DayDate? {
        get { termEnd.map { RVCalendar.day($0) } }
        set { termEnd = newValue.map { RVCalendar.date($0) } }
    }

    // MARK: Text lists

    /// The item lines stored in itemLines. Tabs and line breaks in names become
    /// spaces, and lines with neither a name nor an amount are dropped.
    var lines: [ItemLine] {
        get { ModelCoding.itemLines(itemLines) }
        set { itemLines = ModelCoding.itemLinesText(newValue) }
    }

    /// Fields still marked 'Please check' (checkFields).
    var checks: Set<FillField> {
        get { ModelCoding.checkFields(checkFields) }
        set { checkFields = ModelCoding.checkFieldsText(newValue) }
    }

    // MARK: Relationships, sorted

    /// Pages in the order they were added.
    var sortedFiles: [StoredFile] {
        files.sorted { a, b in
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            if a.capturedAt != b.capturedAt { return a.capturedAt < b.capturedAt }
            return a.fileName < b.fileName
        }
    }

    /// Soonest first; the same day keeps the timeline's kind order.
    var sortedDeadlines: [Deadline] {
        deadlines.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.kindOrder != b.kindOrder { return a.kindOrder < b.kindOrder }
            if a.label != b.label { return a.label < b.label }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// The earliest deadline that still reminds, from today on.
    var nextOpenDeadline: Deadline? {
        self.nextOpenDeadline(today: RVCalendar.today())
    }

    /// The earliest deadline with reminders on, not done, on or after `today`.
    func nextOpenDeadline(today: DayDate) -> Deadline? {
        sortedDeadlines.first { d in d.remindersOn && !d.isDone && d.day >= today }
    }
}

@Model
final class StoredFile {
    var id: UUID = UUID()
    /// '<UUID>.jpg' or '<UUID>.pdf', relative to Files/.
    var fileName: String = ""
    /// '<UUID>-t.jpg', relative to Files/; empty when none was made.
    var thumbName: String = ""
    var isPDF: Bool = false
    var pageCount: Int = 1
    var byteCount: Int = 0
    var originalName: String = ""
    /// Lowercase hex SHA-256 of the stored bytes, taken at capture.
    var sha256: String = ""
    var sourceRaw: String = FileSource.files.rawValue
    var capturedAt: Date = Date()
    /// The phone's time zone identifier at capture.
    var capturedTimeZone: String = ""
    var sortIndex: Int = 0
    var item: VaultItem? = nil

    init(saved: SavedFile, source: FileSource, sortIndex: Int) {
        self.fileName = saved.fileName
        self.thumbName = saved.thumbName
        self.isPDF = saved.isPDF
        self.pageCount = saved.pageCount
        self.byteCount = saved.byteCount
        self.originalName = saved.originalName
        self.sha256 = saved.sha256
        self.sourceRaw = source.rawValue
        self.capturedAt = Date()
        self.capturedTimeZone = TimeZone.current.identifier
        self.sortIndex = sortIndex
    }

    var source: FileSource {
        get { FileSource(rawValue: sourceRaw) ?? FileSource.files }
        set { sourceRaw = newValue.rawValue }
    }

    /// The original in the vault's Files/ folder.
    var url: URL { FileVault.url(fileName) }
}

@Model
final class Deadline {
    var id: UUID = UUID()
    var kindRaw: String = DeadlineKind.custom.rawValue
    /// UTC midnight of the day.
    var date: Date = Date()
    /// The name of a custom date; empty for rule dates.
    var label: String = ""
    var remindersOn: Bool = true
    /// Lead times in days before the date, e.g. '30,14,3'.
    var offsetsText: String = "7"
    var isDone: Bool = false
    var basis: String = ""
    var certaintyRaw: String = Certainty.user.rawValue
    var item: VaultItem? = nil

    init(kind: DeadlineKind, day: DayDate) {
        self.kindRaw = kind.rawValue
        self.date = RVCalendar.date(day)
    }

    var kind: DeadlineKind {
        get { DeadlineKind(rawValue: kindRaw) ?? DeadlineKind.custom }
        set { kindRaw = newValue.rawValue }
    }

    var day: DayDate {
        get { RVCalendar.day(date) }
        set { date = RVCalendar.date(newValue) }
    }

    /// Lead times in days before the date (offsetsText).
    var offsets: [Int] {
        get { ModelCoding.offsets(offsetsText) }
        set { offsetsText = ModelCoding.offsetsText(newValue) }
    }

    var certainty: Certainty {
        get { Certainty(rawValue: certaintyRaw) ?? Certainty.user }
        set { certaintyRaw = newValue.rawValue }
    }

    /// The label of a custom date ('Custom date' when it has none); otherwise
    /// the kind's name.
    var displayLabel: String {
        let kind = self.kind
        guard kind == DeadlineKind.custom else { return kind.label }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.label : trimmed
    }

    /// Position of the kind in DeadlineKind.allCases, for stable sorting.
    var kindOrder: Int {
        DeadlineKind.allCases.firstIndex(of: kind) ?? DeadlineKind.allCases.count
    }
}

// MARK: - Text encodings

/// The plain-text encodings behind the list-like model properties, so the
/// store holds only Strings and numbers (no Codable-struct attributes).
enum ModelCoding {
    /// Tabs and line breaks separate fields and lines in itemLines.
    private static let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))

    /// A name that is safe inside itemLines: tabs and line breaks become
    /// spaces, and the ends are trimmed.
    static func cleanName(_ name: String) -> String {
        name.components(separatedBy: ModelCoding.separators)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// One 'name\tqty\tamountMinor' per line; the amount is empty when unknown.
    /// Lines with neither a name nor an amount are dropped.
    static func itemLinesText(_ lines: [ItemLine]) -> String {
        var rows: [String] = []
        for line in lines {
            let name = ModelCoding.cleanName(line.name)
            if name.isEmpty && line.amountMinor == nil { continue }
            let amount = line.amountMinor.map { String($0) } ?? ""
            rows.append("\(name)\t\(line.quantity)\t\(amount)")
        }
        return rows.joined(separator: "\n")
    }

    /// Reads itemLines. A missing or unreadable quantity is 1; a missing or
    /// unreadable amount is nil. Names are trimmed, and blank lines and lines
    /// with neither a name nor an amount are skipped, so reading and writing
    /// again gives the same text.
    static func itemLines(_ text: String) -> [ItemLine] {
        var result: [ItemLine] = []
        for row in text.components(separatedBy: .newlines) {
            if row.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts: [String] = row.components(separatedBy: "\t")
            let name: String = ModelCoding.cleanName(parts.first ?? "")
            var quantity = 1
            if parts.count > 1, let q = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                quantity = q
            }
            var amount: Int64? = nil
            if parts.count > 2 {
                amount = Int64(parts[2].trimmingCharacters(in: .whitespaces))
            }
            if name.isEmpty && amount == nil { continue }
            result.append(ItemLine(name: name, quantity: quantity, amountMinor: amount))
        }
        return result
    }

    /// Comma-separated raw values, in FillField.allCases order.
    static func checkFieldsText(_ fields: Set<FillField>) -> String {
        FillField.allCases.filter { fields.contains($0) }.map { $0.rawValue }.joined(separator: ",")
    }

    /// Reads checkFields; unknown values are ignored.
    static func checkFields(_ text: String) -> Set<FillField> {
        Set(text.split(separator: ",").compactMap { part in
            FillField(rawValue: part.trimmingCharacters(in: .whitespaces))
        })
    }

    /// '30,14,3'.
    static func offsetsText(_ offsets: [Int]) -> String {
        offsets.map { String($0) }.joined(separator: ",")
    }

    /// Reads offsetsText; parts that are not whole numbers are ignored.
    static func offsets(_ text: String) -> [Int] {
        text.split(separator: ",").compactMap { part in
            Int(part.trimmingCharacters(in: .whitespaces))
        }
    }
}
