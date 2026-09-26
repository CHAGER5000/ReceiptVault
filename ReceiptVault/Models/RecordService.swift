import Foundation
import SwiftData

// Every database change and every mapping between the models and Core.
// RecordService is a plain enum (not @MainActor) so View inits can call it;
// it is only ever called on the main thread. It fetches with
// FetchDescriptor<T>() and filters in Swift, saves once per operation and
// rebuilds the item's search blob on every item save.

// MARK: - Form state

/// A dated reminder the user adds to an item ('Boiler service').
struct CustomDate: Equatable, Identifiable {
    var id: UUID
    var label: String
    var date: DayDate
    var remindersOn: Bool
    /// Lead times in days before the date.
    var offsets: [Int]

    init(id: UUID = UUID(), label: String = "", date: DayDate, remindersOn: Bool = true,
         offsets: [Int] = RuleBook.standardOffsets(DeadlineKind.custom)) {
        self.id = id
        self.label = label
        self.date = date
        self.remindersOn = remindersOn
        self.offsets = offsets
    }
}

/// Everything the edit form shows, as plain values. Nothing is written to the
/// item until RecordService.apply, so Close and Cancel change nothing.
struct ItemForm: Equatable {
    var kind: ItemKind = ItemKind.receipt
    var title = ""
    var merchant = ""
    var category: ProductCategory = ProductCategory.otherGoods
    var purchaseDate: DayDate
    var hasDeliveryDate = false
    var deliveryDate: DayDate

    var totalText = ""
    var currency = "GBP"
    var vatText = ""
    var vatRateText = ""
    var jurisdiction: Jurisdiction = Jurisdiction.englandWales
    var channel: PurchaseChannel = PurchaseChannel.store
    var taxTag: TaxTag = TaxTag.none
    var isUsed = false
    var hasIssue = false

    var returnDays: Int? = nil
    var returnDaysIsPrinted = false
    var warrantyMonths: Int? = nil
    var warrantyIsPrinted = false

    var presetID = ""
    var hasTermEnd = false
    var termEnd: DayDate
    var autoRenews = true
    var renewalMonths = 12
    var notice = NoticePeriod(value: 3, unit: .months)
    var cancelled = false
    var noticeSent = false

    var notes = ""
    var lines: [ItemLine] = []
    /// Reminder switches of the rule dates, keyed by DeadlineKind.rawValue.
    var reminders: [String: Bool] = [:]
    var customDates: [CustomDate] = []
    /// Fields still captioned 'Please check'.
    var checks: Set<FillField> = []

    init(today: DayDate) {
        self.purchaseDate = today
        self.deliveryDate = today
        self.termEnd = today
    }

    /// Fills a field from a tapped line (ReceiptExtractor.fill) and removes
    /// its 'Please check'. Notes are appended on a new line; a total with a
    /// supported currency also sets the currency. A text field takes any
    /// value as text; a value that cannot fill an amount or date field (or an
    /// empty text) changes nothing.
    mutating func apply(_ value: FillValue, to field: FillField) {
        switch field {
        case .title:
            guard let t = ItemForm.text(of: value) else { return }
            title = t
        case .merchant:
            guard let t = ItemForm.text(of: value) else { return }
            merchant = t
        case .notes:
            guard let t = ItemForm.text(of: value) else { return }
            let current = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            notes = current.isEmpty ? t : current + "\n" + t
        case .total:
            guard let a = ItemForm.amount(of: value) else { return }
            totalText = FormParsing.text(minor: a.minor)
            if let code = a.currency, Money.supportedCurrencies.contains(code) {
                currency = code
            }
        case .vat:
            guard let a = ItemForm.amount(of: value) else { return }
            vatText = FormParsing.text(minor: a.minor)
        case .date:
            guard case .day(let d) = value else { return }
            purchaseDate = d
        case .deliveryDate:
            guard case .day(let d) = value else { return }
            deliveryDate = d
            hasDeliveryDate = true
        }
        checks.remove(field)
    }

    /// The trimmed text of a value, or nil when it is empty.
    private static func text(of value: FillValue) -> String? {
        let raw: String
        switch value {
        case .text(let t): raw = t
        case .amount(minor: let minor, currency: _): raw = Money.plain(minor)
        case .day(let d): raw = d.iso
        }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// An amount value, or text that reads as one.
    private static func amount(of value: FillValue) -> (minor: Int64, currency: String?)? {
        switch value {
        case .amount(minor: let minor, currency: let currency):
            return (minor: minor, currency: currency)
        case .text(let t):
            guard let minor = FormParsing.minor(t) else { return nil }
            return (minor: minor, currency: ReceiptAmountParser.currencies(in: t).first)
        case .day:
            return nil
        }
    }
}

/// Text fields of the form to and from stored values.
enum FormParsing {
    /// Amounts beyond 1 000 000 000.00 are typing slips, as in ReceiptExtractor.
    private static let limit = Decimal(1_000_000_000)

    /// '1,234.50', '12,5', '£12' -> minor units. Nil when empty or unreadable.
    static func minor(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let value = AmountParser.parse(t) else { return nil }
        guard value < FormParsing.limit, value > -FormParsing.limit else { return nil }
        return Money.minor(from: value)
    }

    /// Money.plain, or '' when there is no amount.
    static func text(minor: Int64?) -> String {
        guard let m = minor else { return "" }
        return Money.plain(m)
    }

    /// '8.1' -> 81, '20' -> 200, '7,7 %' -> 77. Nil when empty, unreadable
    /// or above 100 %.
    static func permille(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("%") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty, s.count <= 8,
              s.allSatisfy({ c in (c.isASCII && c.isNumber) || c == "." }),
              s.filter({ $0 == "." }).count <= 1,
              s.contains(where: { $0.isASCII && $0.isNumber }),
              let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var scaled = value * 10
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let result = NSDecimalNumber(decimal: rounded).intValue
        return (0...1000).contains(result) ? result : nil
    }

    /// Money.percent ('20', '8.1'), or '' when there is no rate.
    static func rateText(_ permille: Int?) -> String {
        guard let p = permille else { return "" }
        return Money.percent(permille: p)
    }
}

// MARK: - Service

enum RecordService {

    // MARK: Rules

    private static var cachedRulesData: Data? = nil
    private static var cachedRules: RuleBook? = nil

    /// The RuleBook stored in the settings (SettingsKeys.rulesJSON), laid over
    /// the defaults. Decoded once per stored value.
    static var rules: RuleBook {
        get {
            let data = UserDefaults.standard.data(forKey: SettingsKeys.rulesJSON)
            if let book = RecordService.cachedRules, data == RecordService.cachedRulesData {
                return book
            }
            let book = RuleBook.decode(data)
            RecordService.cachedRulesData = data
            RecordService.cachedRules = book
            return book
        }
        set {
            let data = newValue.encoded()
            UserDefaults.standard.set(data, forKey: SettingsKeys.rulesJSON)
            RecordService.cachedRulesData = data
            RecordService.cachedRules = RuleBook.decode(data)
        }
    }

    // MARK: Creating

    /// A new item from a document just read. Values at 0.5 or more fill the
    /// item; the rest come from the settings. A missing date is today and
    /// marked 'Please check', and so is a total whose currency was not read
    /// with confidence (the Settings default). Printed terms fill the rule
    /// inputs and the contract terms ('From document'). The title is the
    /// suggested title, else the merchant, else '<Kind> <date>'.
    static func createItem(fields: ReceiptFields, files: [SavedFile], source: FileSource, ocrText: String,
                           context: ModelContext) throws -> VaultItem {
        let today = RVCalendar.today()
        let kind = RecordService.filled(fields.kind) ?? ItemKind.receipt
        let foundDay = RecordService.filled(fields.date)
        let item = VaultItem(kind: kind, purchaseDay: foundDay ?? today)
        context.insert(item)

        let merchant = RecordService.trimmed(RecordService.filled(fields.merchant) ?? "")
        item.merchant = merchant
        item.deliveryDay = RecordService.filled(fields.deliveryDate)
        item.totalMinor = RecordService.filled(fields.total)
        item.currency = RecordService.filled(fields.currency) ?? AppSettings.defaultCurrency
        item.vatMinor = RecordService.filled(fields.vat)
        item.vatRatePermille = RecordService.filled(fields.vatRatePermille)
        item.jurisdiction = RecordService.filled(fields.jurisdiction) ?? AppSettings.defaultJurisdiction
        item.channel = RecordService.filled(fields.channel) ?? AppSettings.defaultChannel
        item.category = RecordService.filled(fields.category) ?? ProductCategory.otherGoods
        item.lines = fields.items
        item.ocrText = ocrText
        RecordService.applyTerms(fields.terms, to: item, onlyWhereEmpty: false)

        let suggested = RecordService.trimmed(fields.suggestedTitle ?? "")
        item.title = suggested.isEmpty
            ? RecordService.fallbackTitle(merchant: merchant, kind: kind, day: item.purchaseDay)
            : suggested

        var checks = fields.checkFields
        if foundDay == nil { checks.insert(FillField.date) }
        // A total whose currency is the Settings default (not read) or unsure
        // is marked 'Please check': the currency picker sits on the total's row.
        if item.totalMinor != nil {
            let currencySure = fields.currency.map { $0.shouldFill && !$0.needsCheck } ?? false
            if !currencySure { checks.insert(FillField.total) }
        }
        item.checks = checks
        item.needsReview = fields.needsReview || foundDay == nil || checks.contains(FillField.total)

        for (index, saved) in files.enumerated() {
            let file = StoredFile(saved: saved, source: source, sortIndex: index)
            RecordService.attachFile(file, to: item, context: context)
        }

        RecordService.sync(item, today: today, book: RecordService.rules, context: context)
        RecordService.rebuildSearch(item)
        try context.save()
        return item
    }

    /// Adds pages to an item. Their text is appended to the OCR text, and
    /// printed terms fill the warranty, return days and contract terms only
    /// where the item has none yet.
    static func addFiles(_ files: [SavedFile], source: FileSource, text: String, to item: VaultItem,
                         context: ModelContext) throws {
        var next = (item.files.map { $0.sortIndex }.max() ?? -1) + 1
        for saved in files {
            let file = StoredFile(saved: saved, source: source, sortIndex: next)
            RecordService.attachFile(file, to: item, context: context)
            next += 1
        }
        let added = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !added.isEmpty {
            item.ocrText = item.ocrText.isEmpty ? added : item.ocrText + "\n\n" + added
            RecordService.applyTerms(TermsFinder.find(in: added), to: item, onlyWhereEmpty: true)
        }
        item.updatedAt = Date()
        RecordService.sync(item, today: RVCalendar.today(), book: RecordService.rules, context: context)
        RecordService.rebuildSearch(item)
        try context.save()
    }

    // MARK: Form

    /// The form for an item, as stored.
    static func form(for item: VaultItem) -> ItemForm {
        var f = ItemForm(today: RVCalendar.today())
        f.kind = item.kind
        f.title = item.title
        f.merchant = item.merchant
        f.category = item.category
        f.purchaseDate = item.purchaseDay
        f.hasDeliveryDate = item.deliveryDate != nil
        f.deliveryDate = item.deliveryDay ?? item.purchaseDay

        f.totalText = FormParsing.text(minor: item.totalMinor)
        f.currency = item.currency
        f.vatText = FormParsing.text(minor: item.vatMinor)
        f.vatRateText = FormParsing.rateText(item.vatRatePermille)
        f.jurisdiction = item.jurisdiction
        f.channel = item.channel
        f.taxTag = item.taxTag
        f.isUsed = item.isUsed
        f.hasIssue = item.hasIssue

        f.returnDays = item.returnDays
        f.returnDaysIsPrinted = item.returnDaysIsPrinted
        f.warrantyMonths = item.warrantyMonths
        f.warrantyIsPrinted = item.warrantyIsPrinted

        f.presetID = item.contractPresetID
        f.hasTermEnd = item.termEnd != nil
        f.termEnd = item.termEndDay ?? RVCalendar.periodEnd(from: item.purchaseDay, months: 12)
        f.autoRenews = item.autoRenews
        f.renewalMonths = item.renewalMonths
        f.notice = item.notice
        f.cancelled = item.cancelled
        f.noticeSent = item.noticeSentAt != nil

        f.notes = item.notes
        f.lines = item.lines
        var reminders: [String: Bool] = [:]
        var custom: [CustomDate] = []
        for row in item.sortedDeadlines {
            if row.kind == DeadlineKind.custom {
                custom.append(CustomDate(id: row.id, label: row.label, date: row.day,
                                         remindersOn: row.remindersOn, offsets: row.offsets))
            } else if reminders[row.kindRaw] == nil {
                reminders[row.kindRaw] = row.remindersOn
            }
        }
        f.reminders = reminders
        f.customDates = custom
        f.checks = item.checks
        return f
    }

    /// What the planner needs from the form. Contract facts only for a
    /// contract with a term end.
    static func facts(_ form: ItemForm) -> PurchaseFacts {
        PurchaseFacts(kind: form.kind,
                      purchaseDate: form.purchaseDate,
                      deliveryDate: form.hasDeliveryDate ? form.deliveryDate : nil,
                      jurisdiction: form.jurisdiction,
                      channel: form.channel,
                      category: form.category,
                      isUsed: form.isUsed,
                      hasIssue: form.hasIssue,
                      totalMinor: FormParsing.minor(form.totalText),
                      warrantyMonths: form.warrantyMonths,
                      warrantyIsPrinted: form.warrantyMonths != nil && form.warrantyIsPrinted,
                      returnDays: form.returnDays,
                      returnDaysIsPrinted: form.returnDays != nil && form.returnDaysIsPrinted,
                      contract: RecordService.contractFacts(form))
    }

    /// What the planner needs from a stored item. Contract facts only for
    /// kind .contract with termEnd set.
    static func facts(for item: VaultItem) -> PurchaseFacts {
        var contract: ContractFacts? = nil
        if item.kind == ItemKind.contract, let end = item.termEndDay {
            contract = ContractFacts(termEnd: end, autoRenews: item.autoRenews, renewalMonths: item.renewalMonths,
                                     notice: item.notice, cancelled: item.cancelled)
        }
        return PurchaseFacts(kind: item.kind,
                             purchaseDate: item.purchaseDay,
                             deliveryDate: item.deliveryDay,
                             jurisdiction: item.jurisdiction,
                             channel: item.channel,
                             category: item.category,
                             isUsed: item.isUsed,
                             hasIssue: item.hasIssue,
                             totalMinor: item.totalMinor,
                             warrantyMonths: item.warrantyMonths,
                             warrantyIsPrinted: item.warrantyIsPrinted,
                             returnDays: item.returnDays,
                             returnDaysIsPrinted: item.returnDaysIsPrinted,
                             contract: contract)
    }

    /// The live 'Dates we will track' preview.
    static func preview(_ form: ItemForm, today: DayDate) -> [PlannedDeadline] {
        DeadlinePlanner.plan(RecordService.facts(form), rules: RecordService.rules, today: today)
    }

    /// 'Notice must arrive by' and 'Send by' for the form; nil unless it is a
    /// contract with a term end.
    static func contractStatus(_ form: ItemForm, today: DayDate) -> ContractStatus? {
        guard let c = RecordService.contractFacts(form) else { return nil }
        return ContractMath.status(c, today: today, postalBufferDays: RecordService.rules.postalBufferDays)
    }

    /// Saves the form. 'Notice sent' records when (and marks the notice
    /// deadline done the first time); 'Something's wrong with it' records the
    /// day it was first set. The item leaves 'Needs a look' and loses its
    /// 'Please check' captions. After the rule dates are synced, the reminder
    /// switches the user changed are applied; when only the fault switch
    /// changed, the right-to-reject reminder follows it. Custom dates are
    /// replaced by id.
    static func apply(_ form: ItemForm, to item: VaultItem, context: ModelContext) throws {
        let today = RVCalendar.today()
        let book = RecordService.rules
        // The switches as form(for:) loaded them (first row of a kind in
        // sortedDeadlines), so 'changed by the user' is compared like for like.
        var before: [String: Bool] = [:]
        for row in item.sortedDeadlines where row.kind != DeadlineKind.custom && before[row.kindRaw] == nil {
            before[row.kindRaw] = row.remindersOn
        }
        let issueChanged = form.hasIssue != item.hasIssue
        let wasSent = item.noticeSentAt != nil

        // Fields
        item.kind = form.kind
        let merchant = RecordService.trimmed(form.merchant)
        item.merchant = merchant
        let title = RecordService.trimmed(form.title)
        item.title = title.isEmpty
            ? RecordService.fallbackTitle(merchant: merchant, kind: form.kind, day: form.purchaseDate)
            : title
        item.category = form.category
        item.purchaseDay = form.purchaseDate
        item.deliveryDay = form.hasDeliveryDate ? form.deliveryDate : nil

        item.totalMinor = FormParsing.minor(form.totalText)
        let code = form.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        item.currency = code.isEmpty ? AppSettings.defaultCurrency : code
        item.vatMinor = FormParsing.minor(form.vatText)
        item.vatRatePermille = FormParsing.permille(form.vatRateText)
        item.jurisdiction = form.jurisdiction
        item.channel = form.channel
        item.taxTag = form.taxTag
        item.isUsed = form.isUsed
        item.hasIssue = form.hasIssue
        if form.hasIssue && item.issueNotedAt == nil {
            item.issueNotedAt = Date()
        }

        item.returnDays = form.returnDays
        item.returnDaysIsPrinted = form.returnDays != nil && form.returnDaysIsPrinted
        item.warrantyMonths = form.warrantyMonths
        item.warrantyIsPrinted = form.warrantyMonths != nil && form.warrantyIsPrinted

        item.contractPresetID = form.presetID
        item.termEndDay = form.hasTermEnd ? form.termEnd : nil
        item.autoRenews = form.autoRenews
        item.renewalMonths = form.renewalMonths
        item.notice = form.notice
        item.cancelled = form.cancelled
        if form.noticeSent {
            if item.noticeSentAt == nil { item.noticeSentAt = Date() }
        } else {
            item.noticeSentAt = nil
        }

        item.notes = form.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        item.lines = form.lines
        item.needsReview = false
        item.checks = []

        // Rule dates, then the reminder switches
        let planned = RecordService.sync(item, today: today, book: book, context: context)
        var remindByDefault: [String: Bool] = [:]
        for p in planned { remindByDefault[p.kind.rawValue] = p.remindByDefault }
        for row in item.deadlines where row.kind != DeadlineKind.custom {
            let key = row.kindRaw
            if let on = form.reminders[key], on != before[key] {
                if row.remindersOn != on { row.remindersOn = on }
            } else if issueChanged, row.kind == DeadlineKind.rightToReject, let on = remindByDefault[key] {
                if row.remindersOn != on { row.remindersOn = on }
            }
            if row.kind == DeadlineKind.noticeDeadline {
                if form.noticeSent && !wasSent { row.isDone = true }
                if !form.noticeSent && wasSent { row.isDone = false }
            }
        }

        // Custom dates, replaced by id
        let customOffsets = book.offsets(for: DeadlineKind.custom)
        var wanted: [CustomDate] = []
        var wantedIDs = Set<UUID>()
        for entry in form.customDates {
            if wantedIDs.insert(entry.id).inserted { wanted.append(entry) }
        }
        var existing: [UUID: Deadline] = [:]
        var stale: [Deadline] = []
        for row in item.deadlines where row.kind == DeadlineKind.custom {
            if wantedIDs.contains(row.id) && existing[row.id] == nil {
                existing[row.id] = row
            } else {
                stale.append(row)
            }
        }
        for row in stale {
            RecordService.removeDeadline(row, from: item, context: context)
        }
        for entry in wanted {
            let label = RecordService.trimmed(entry.label)
            let offsets = RecordService.cleanedOffsets(entry.offsets, fallback: customOffsets)
            if let row = existing[entry.id] {
                if row.day != entry.date {
                    row.day = entry.date
                    row.isDone = false
                }
                if row.label != label { row.label = label }
                if row.remindersOn != entry.remindersOn { row.remindersOn = entry.remindersOn }
                if row.offsets != offsets { row.offsets = offsets }
            } else {
                let row = Deadline(kind: DeadlineKind.custom, day: entry.date)
                row.id = entry.id
                row.label = label
                row.remindersOn = entry.remindersOn
                row.offsets = offsets
                row.certainty = Certainty.user
                RecordService.attachDeadline(row, to: item, context: context)
            }
        }

        item.updatedAt = Date()
        RecordService.rebuildSearch(item)
        try context.save()
    }

    // MARK: Deadlines

    /// Regenerates the rule dates from DeadlinePlanner, without saving. Rows
    /// are matched by kind and updated in place; remindersOn is kept (a new
    /// row takes remindByDefault); isDone is kept only while the date is
    /// unchanged; rows for kinds no longer planned are deleted; custom rows
    /// are never touched.
    static func syncDeadlines(_ item: VaultItem, today: DayDate, context: ModelContext) {
        RecordService.sync(item, today: today, book: RecordService.rules, context: context)
    }

    /// Syncs every item (contracts roll forward) and saves when anything changed.
    static func resyncAll(context: ModelContext) throws {
        let today = RVCalendar.today()
        let book = RecordService.rules
        for item in try context.fetch(FetchDescriptor<VaultItem>()) {
            RecordService.sync(item, today: today, book: book, context: context)
            if item.searchBlob.isEmpty { RecordService.rebuildSearch(item) }
        }
        if context.hasChanges { try context.save() }
    }

    static func setDone(_ d: Deadline, _ done: Bool, context: ModelContext) throws {
        d.isDone = done
        try context.save()
    }

    static func setReminders(_ d: Deadline, _ on: Bool, context: ModelContext) throws {
        d.remindersOn = on
        try context.save()
    }

    /// Records that notice was sent today and marks the notice deadline done.
    static func markNoticeSent(_ item: VaultItem, context: ModelContext) throws {
        item.noticeSentAt = Date()
        for row in item.deadlines where row.kind == DeadlineKind.noticeDeadline {
            row.isDone = true
        }
        item.updatedAt = Date()
        RecordService.rebuildSearch(item)
        try context.save()
    }

    // MARK: Deleting

    /// Deletes the item (its files and deadlines cascade), then, only once
    /// the save has succeeded, its originals and thumbnails. A failed save
    /// leaves the files in place, so a rolled-back item keeps its pages; a
    /// failed file removal leaves only an orphan file.
    static func delete(_ item: VaultItem, context: ModelContext) throws {
        var names: [String] = []
        for file in item.files {
            names.append(file.fileName)
            names.append(file.thumbName)
        }
        context.delete(item)
        try context.save()
        FileVault.delete(names)
    }

    /// Deletes every item, then any orphan files and deadlines, and empties
    /// Files/, the staging folders and the exports. pendingWipe is set first,
    /// so the store files are removed at the next launch even if a save fails.
    static func deleteAll(context: ModelContext) throws {
        AppSettings.pendingWipe = true
        defer {
            FileVault.clearDirectory(Storage.filesDirectory)
            FileVault.clearDirectory(Storage.incomingDirectory)
            FileVault.clearDirectory(Storage.restoreDirectory)
            FileVault.clearExports()
        }
        for item in try context.fetch(FetchDescriptor<VaultItem>()) {
            context.delete(item)
        }
        try context.save()
        for file in try context.fetch(FetchDescriptor<StoredFile>()) {
            context.delete(file)
        }
        for row in try context.fetch(FetchDescriptor<Deadline>()) {
            context.delete(row)
        }
        try context.save()
    }

    // MARK: Fetching

    /// Newest purchase first.
    static func fetchItems(context: ModelContext) -> [VaultItem] {
        let items = (try? context.fetch(FetchDescriptor<VaultItem>())) ?? []
        return items.sorted { a, b in
            if a.purchaseDate != b.purchaseDate { return a.purchaseDate > b.purchaseDate }
            return a.createdAt > b.createdAt
        }
    }

    static func item(id: UUID, context: ModelContext) -> VaultItem? {
        let items = (try? context.fetch(FetchDescriptor<VaultItem>())) ?? []
        return items.first(where: { $0.id == id })
    }

    /// The earliest-saved other item holding a file with this SHA-256.
    static func duplicate(of sha256: String, excluding item: VaultItem?, context: ModelContext) -> VaultItem? {
        let hash = sha256.lowercased()
        guard !hash.isEmpty else { return nil }
        let files = (try? context.fetch(FetchDescriptor<StoredFile>())) ?? []
        var best: VaultItem? = nil
        for file in files where file.sha256.lowercased() == hash {
            guard let owner = file.item else { continue }
            if let excluded = item, owner.id == excluded.id { continue }
            if let current = best, current.createdAt <= owner.createdAt { continue }
            best = owner
        }
        return best
    }

    /// Deadlines that remind: remindersOn, not done, and still on an item.
    static func reminderInputs(context: ModelContext) -> [ReminderInput] {
        let rows = (try? context.fetch(FetchDescriptor<Deadline>())) ?? []
        var inputs: [ReminderInput] = []
        for row in rows where row.remindersOn && !row.isDone {
            guard let owner = row.item else { continue }
            inputs.append(ReminderInput(deadlineID: row.id.uuidString,
                                        itemID: owner.id.uuidString,
                                        kind: row.kind,
                                        label: row.label,
                                        date: row.day,
                                        offsets: row.offsets,
                                        itemTitle: owner.title,
                                        merchant: owner.merchant))
        }
        return inputs.sorted { a, b in
            a.date != b.date ? a.date < b.date : a.deadlineID < b.deadlineID
        }
    }

    // MARK: Search

    /// The pre-folded search blob: title, merchant, product lines, notes, the
    /// first SearchText.maxOCRCharacters of the OCR text, kind and category,
    /// plus the typed forms of the total and of the purchase and delivery days.
    static func rebuildSearch(_ item: VaultItem) {
        var parts: [String] = [item.title, item.merchant]
        parts.append(contentsOf: item.lines.map { $0.name })
        parts.append(item.notes)
        parts.append(String(item.ocrText.prefix(SearchText.maxOCRCharacters)))
        parts.append(item.kind.label)
        parts.append(item.category.label)
        if let total = item.totalMinor {
            parts.append(contentsOf: SearchText.amountTerms(total))
        }
        parts.append(contentsOf: SearchText.dateTerms(item.purchaseDay))
        if let delivered = item.deliveryDay {
            parts.append(contentsOf: SearchText.dateTerms(delivered))
        }
        let blob = SearchText.blob(parts)
        if item.searchBlob != blob { item.searchBlob = blob }
    }

    // MARK: Exports

    /// One 'ReceiptVault CSV v1' row. Return by is the shop return window,
    /// else the cancellation date; legal cover is the legal guarantee, else
    /// the claim limit.
    static func csvRow(_ item: VaultItem) -> ItemCSVRow {
        var byKind: [DeadlineKind: DayDate] = [:]
        for row in item.sortedDeadlines where byKind[row.kind] == nil {
            byKind[row.kind] = row.day
        }
        return ItemCSVRow(date: item.purchaseDay,
                          delivered: item.deliveryDay,
                          merchant: item.merchant,
                          title: item.title,
                          kind: item.kind,
                          category: item.category,
                          totalMinor: item.totalMinor,
                          currency: item.currency,
                          vatMinor: item.vatMinor,
                          vatRatePermille: item.vatRatePermille,
                          taxTag: item.taxTag,
                          returnBy: byKind[DeadlineKind.returnWindow] ?? byKind[DeadlineKind.cancellation],
                          warrantyUntil: byKind[DeadlineKind.manufacturerWarranty],
                          legalCoverUntil: byKind[DeadlineKind.legalGuarantee] ?? byKind[DeadlineKind.claimLimit],
                          noticeBy: byKind[DeadlineKind.noticeDeadline],
                          notes: item.notes,
                          id: item.id)
    }

    /// The evidence cover's content. Every file's hash is taken again from
    /// the stored bytes and compared with the one recorded at capture.
    static func evidenceInput(for item: VaultItem) -> EvidenceInput {
        let dates: [EvidenceDate] = item.sortedDeadlines.map { row in
            EvidenceDate(label: row.displayLabel, date: row.day, certainty: row.certainty)
        }
        var files: [EvidenceFile] = []
        for file in item.sortedFiles {
            let recorded = file.sha256.lowercased()
            let current = FileVault.sha256(file.fileName)
            let original = RecordService.trimmed(file.originalName)
            files.append(EvidenceFile(name: original.isEmpty ? file.fileName : original,
                                      pages: file.pageCount,
                                      sha256: file.sha256,
                                      capturedAt: RecordService.captureText(file.capturedAt, zoneID: file.capturedTimeZone),
                                      source: file.source.label,
                                      matchesCapture: !recorded.isEmpty && current == recorded))
        }
        var noted: DayDate? = nil
        if item.hasIssue, let at = item.issueNotedAt {
            noted = RVCalendar.today(now: at, timeZone: TimeZone.current)
        }
        return EvidenceInput(title: item.title,
                             merchant: item.merchant,
                             kind: item.kind,
                             purchaseDate: item.purchaseDay,
                             deliveryDate: item.deliveryDay,
                             totalMinor: item.totalMinor,
                             currency: item.currency,
                             vatMinor: item.vatMinor,
                             vatRatePermille: item.vatRatePermille,
                             items: item.lines,
                             jurisdiction: item.jurisdiction,
                             channel: item.channel,
                             hasIssue: item.hasIssue,
                             issueNoted: noted,
                             dates: dates,
                             notes: item.notes,
                             files: files)
    }

    // MARK: Backup

    /// The item as it goes into a backup manifest.
    static func dto(_ item: VaultItem) -> ItemDTO {
        let deadlines: [DeadlineDTO] = item.sortedDeadlines.map { row in
            DeadlineDTO(id: row.id, kind: row.kindRaw, date: row.day, label: row.label,
                        remindersOn: row.remindersOn, offsets: row.offsets, isDone: row.isDone,
                        basis: row.basis, certainty: row.certaintyRaw)
        }
        let files: [FileDTO] = item.sortedFiles.map { file in
            FileDTO(id: file.id, fileName: file.fileName, isPDF: file.isPDF, pageCount: file.pageCount,
                    byteCount: file.byteCount, originalName: file.originalName, sha256: file.sha256,
                    source: file.sourceRaw, capturedAt: file.capturedAt,
                    capturedTimeZone: file.capturedTimeZone, sortIndex: file.sortIndex)
        }
        return ItemDTO(id: item.id,
                       kind: item.kindRaw,
                       title: item.title,
                       merchant: item.merchant,
                       purchaseDate: item.purchaseDay,
                       deliveryDate: item.deliveryDay,
                       totalMinor: item.totalMinor,
                       currency: item.currency,
                       vatMinor: item.vatMinor,
                       vatRatePermille: item.vatRatePermille,
                       jurisdiction: item.jurisdictionRaw,
                       channel: item.channelRaw,
                       category: item.categoryRaw,
                       taxTag: item.taxTagRaw,
                       isUsed: item.isUsed,
                       hasIssue: item.hasIssue,
                       issueNotedAt: item.issueNotedAt,
                       returnDays: item.returnDays,
                       returnDaysIsPrinted: item.returnDaysIsPrinted,
                       warrantyMonths: item.warrantyMonths,
                       warrantyIsPrinted: item.warrantyIsPrinted,
                       contractPresetID: item.contractPresetID,
                       termEnd: item.termEndDay,
                       autoRenews: item.autoRenews,
                       renewalMonths: item.renewalMonths,
                       notice: item.notice,
                       cancelled: item.cancelled,
                       noticeSentAt: item.noticeSentAt,
                       itemLines: item.itemLines,
                       notes: item.notes,
                       ocrText: item.ocrText,
                       needsReview: item.needsReview,
                       checkFields: item.checkFields,
                       createdAt: item.createdAt,
                       updatedAt: item.updatedAt,
                       deadlines: deadlines,
                       files: files)
    }

    /// Restores one item, without saving. `files` maps each FileDTO.id to the
    /// original already adopted under a NEW local name; file records without
    /// one are skipped. The capture-time hash, time, time zone and source are
    /// kept. Deadlines come from the backup, then the rule dates are synced.
    @discardableResult
    static func insert(_ dto: ItemDTO, files: [UUID: SavedFile], context: ModelContext) -> VaultItem {
        let item = VaultItem(kind: ItemKind(rawValue: dto.kind) ?? ItemKind.receipt, purchaseDay: dto.purchaseDate)
        item.id = dto.id
        context.insert(item)

        item.title = dto.title
        item.merchant = dto.merchant
        item.deliveryDay = dto.deliveryDate
        item.totalMinor = dto.totalMinor
        item.currency = dto.currency.isEmpty ? AppSettings.defaultCurrency : dto.currency
        item.vatMinor = dto.vatMinor
        item.vatRatePermille = dto.vatRatePermille
        item.jurisdiction = Jurisdiction(rawValue: dto.jurisdiction) ?? AppSettings.defaultJurisdiction
        item.channel = PurchaseChannel(rawValue: dto.channel) ?? AppSettings.defaultChannel
        item.category = ProductCategory(rawValue: dto.category) ?? ProductCategory.otherGoods
        item.taxTag = TaxTag(rawValue: dto.taxTag) ?? TaxTag.none
        item.isUsed = dto.isUsed
        item.hasIssue = dto.hasIssue
        item.issueNotedAt = dto.issueNotedAt
        item.returnDays = dto.returnDays
        item.returnDaysIsPrinted = dto.returnDaysIsPrinted
        item.warrantyMonths = dto.warrantyMonths
        item.warrantyIsPrinted = dto.warrantyIsPrinted
        item.contractPresetID = dto.contractPresetID
        item.termEndDay = dto.termEnd
        item.autoRenews = dto.autoRenews
        item.renewalMonths = dto.renewalMonths
        item.notice = dto.notice
        item.cancelled = dto.cancelled
        item.noticeSentAt = dto.noticeSentAt
        item.lines = ModelCoding.itemLines(dto.itemLines)
        item.notes = dto.notes
        item.ocrText = dto.ocrText
        item.needsReview = dto.needsReview
        item.checks = ModelCoding.checkFields(dto.checkFields)
        item.createdAt = dto.createdAt
        item.updatedAt = dto.updatedAt

        // A damaged manifest can repeat an id: the first record wins, so no
        // two rows share an id (or, for files, one original).
        var fileIDs = Set<UUID>()
        for record in dto.files {
            guard let saved = files[record.id], fileIDs.insert(record.id).inserted else { continue }
            let source = FileSource(rawValue: record.source) ?? FileSource.restored
            let file = StoredFile(saved: saved, source: source, sortIndex: record.sortIndex)
            file.id = record.id
            if !record.sha256.isEmpty { file.sha256 = record.sha256.lowercased() }
            if !record.originalName.isEmpty { file.originalName = record.originalName }
            file.capturedAt = record.capturedAt
            file.capturedTimeZone = record.capturedTimeZone
            RecordService.attachFile(file, to: item, context: context)
        }

        let book = RecordService.rules
        var deadlineIDs = Set<UUID>()
        for record in dto.deadlines where deadlineIDs.insert(record.id).inserted {
            let kind = DeadlineKind(rawValue: record.kind) ?? DeadlineKind.custom
            let row = Deadline(kind: kind, day: record.date)
            row.id = record.id
            row.label = record.label
            row.remindersOn = record.remindersOn
            // Rule rows get the plan's lead times in sync; custom rows keep
            // theirs, cleaned as apply would.
            row.offsets = RecordService.cleanedOffsets(record.offsets, fallback: book.offsets(for: kind))
            row.isDone = record.isDone
            row.basis = record.basis
            row.certainty = Certainty(rawValue: record.certainty) ?? Certainty.user
            RecordService.attachDeadline(row, to: item, context: context)
        }

        RecordService.sync(item, today: RVCalendar.today(), book: book, context: context)
        RecordService.rebuildSearch(item)
        return item
    }

    // MARK: - Helpers

    /// The dataModel's sync rules, with the book read once by the caller.
    /// Returns the plan, so apply can read each kind's remindByDefault.
    @discardableResult
    private static func sync(_ item: VaultItem, today: DayDate, book: RuleBook, context: ModelContext) -> [PlannedDeadline] {
        let planned = DeadlinePlanner.plan(RecordService.facts(for: item), rules: book, today: today)
        var rows: [String: Deadline] = [:]
        var spare: [Deadline] = []
        for row in item.deadlines where row.kind != DeadlineKind.custom {
            if rows[row.kindRaw] == nil {
                rows[row.kindRaw] = row
            } else {
                spare.append(row) // a second row of one kind
            }
        }
        for p in planned where p.kind != DeadlineKind.custom {
            if let row = rows.removeValue(forKey: p.kind.rawValue) {
                if row.day != p.date {
                    row.day = p.date
                    if row.isDone { row.isDone = false }
                }
                if row.offsets != p.offsets { row.offsets = p.offsets }
                if row.basis != p.basis { row.basis = p.basis }
                if row.certainty != p.certainty { row.certainty = p.certainty }
                if !row.label.isEmpty { row.label = "" }
            } else {
                let row = Deadline(kind: p.kind, day: p.date)
                row.remindersOn = p.remindByDefault
                row.offsets = p.offsets
                row.basis = p.basis
                row.certainty = p.certainty
                RecordService.attachDeadline(row, to: item, context: context)
            }
        }
        // Whatever is left is no longer planned.
        spare.append(contentsOf: rows.values)
        for row in spare {
            RecordService.removeDeadline(row, from: item, context: context)
        }
        return planned
    }

    /// Inserts the row, then links it from both sides.
    private static func attachDeadline(_ row: Deadline, to item: VaultItem, context: ModelContext) {
        context.insert(row)
        row.item = item
        if !item.deadlines.contains(where: { $0 === row }) {
            item.deadlines.append(row)
        }
    }

    /// Takes the row off the item first, so the item never lists a deleted row.
    private static func removeDeadline(_ row: Deadline, from item: VaultItem, context: ModelContext) {
        item.deadlines.removeAll(where: { $0 === row })
        context.delete(row)
    }

    private static func attachFile(_ file: StoredFile, to item: VaultItem, context: ModelContext) {
        context.insert(file)
        file.item = item
        if !item.files.contains(where: { $0 === file }) {
            item.files.append(file)
        }
    }

    /// The contract facts of a form: only for a contract with a term end.
    private static func contractFacts(_ form: ItemForm) -> ContractFacts? {
        guard form.kind == ItemKind.contract, form.hasTermEnd else { return nil }
        return ContractFacts(termEnd: form.termEnd, autoRenews: form.autoRenews, renewalMonths: form.renewalMonths,
                             notice: form.notice, cancelled: form.cancelled)
    }

    /// A found value that is sure enough to fill the form.
    private static func filled<T: Equatable>(_ found: Found<T>?) -> T? {
        guard let f = found, f.shouldFill else { return nil }
        return f.value
    }

    /// Printed terms into the item, marked 'From document'. With
    /// `onlyWhereEmpty`, only values the item does not have yet are filled;
    /// the notice period and renewal count as empty until a term end or a
    /// preset has been set.
    private static func applyTerms(_ terms: PrintedTerms, to item: VaultItem, onlyWhereEmpty: Bool) {
        if let months = terms.warrantyMonths, months > 0, !(onlyWhereEmpty && item.warrantyMonths != nil) {
            item.warrantyMonths = months
            item.warrantyIsPrinted = true
        }
        if let days = terms.returnDays, days > 0, !(onlyWhereEmpty && item.returnDays != nil) {
            item.returnDays = days
            item.returnDaysIsPrinted = true
        }
        let contractUnset = item.termEnd == nil && item.contractPresetID.isEmpty
        if let end = terms.termEnd, !(onlyWhereEmpty && item.termEnd != nil) {
            item.termEndDay = end
        }
        if !onlyWhereEmpty || contractUnset {
            if let notice = terms.notice { item.notice = notice }
            if let renews = terms.autoRenews { item.autoRenews = renews }
            if let months = terms.renewalMonths, months > 0 { item.renewalMonths = months }
        }
    }

    /// Non-negative lead times, largest first, without repeats; `fallback`
    /// when none are left.
    private static func cleanedOffsets(_ offsets: [Int], fallback: [Int]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for o in offsets.sorted(by: >) where o >= 0 && o <= 36_600 {
            if seen.insert(o).inserted { out.append(o) }
        }
        return out.isEmpty ? fallback : out
    }

    /// The merchant, else '<Kind> <date>' ('Receipt 12 Mar 2025').
    private static func fallbackTitle(merchant: String, kind: ItemKind, day: DayDate) -> String {
        let shop = RecordService.trimmed(merchant)
        return shop.isEmpty ? "\(kind.label) \(RecordService.dayText(day))" : shop
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fixed English abbreviations, so stored titles read the same on every phone.
    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// '12 Mar 2025'.
    private static func dayText(_ d: DayDate) -> String {
        guard (1...12).contains(d.month) else { return d.iso }
        return "\(d.day) \(RecordService.monthAbbreviations[d.month - 1]) \(d.year)"
    }

    /// '12 Mar 2025, 14:32 (Europe/London)', on the clock of the capture time zone.
    private static func captureText(_ date: Date, zoneID: String) -> String {
        let zone = TimeZone(identifier: zoneID) ?? TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute else { return "" }
        let dayPart = RecordService.dayText(DayDate(year: year, month: month, day: day))
        return "\(dayPart), \(RecordService.pad(hour)):\(RecordService.pad(minute)) (\(zone.identifier))"
    }

    private static func pad(_ n: Int) -> String {
        n >= 0 && n < 10 ? "0\(n)" : "\(n)"
    }
}
