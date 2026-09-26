import Foundation

/// A reminded deadline, as the planner sees it. `offsets` are lead times in
/// days before `date`; `label` is shown only for custom dates.
struct ReminderInput: Equatable {
    var deadlineID: String
    var itemID: String
    var kind: DeadlineKind
    var label: String
    var date: DayDate
    var offsets: [Int]
    var itemTitle: String
    var merchant: String
}

/// One local notification: it fires once at `hour`:`minute` on `fireDay`, in
/// the user's local time. `itemID` is empty for the refresh and backup
/// reminders.
struct PlannedReminder: Equatable {
    var identifier: String
    var itemID: String
    var fireDay: DayDate
    var hour: Int
    var minute: Int
    var title: String
    var body: String
}

/// Turns deadlines into a plan of local notifications, with no
/// UserNotifications code, so the whole plan is testable. The app removes
/// every pending request whose identifier starts with `prefix` and adds the
/// plan, so running it twice changes nothing.
///
/// Identifiers: 'rv.<deadlineID>.<daysBefore>' for one date,
/// 'rv.m.<itemID>.<yyyy-MM-dd>' for an item's dates merged on one day,
/// 'rv.refresh' and 'rv.backup'. Amounts never appear in the text.
enum ReminderPlanner {
    static let prefix = "rv."
    /// The most reminders `plan` returns, the refresh reminder included. With
    /// the backup reminder that stays under iOS's 64 pending requests.
    static let limit = 60
    static let refreshIdentifier = "rv.refresh"
    static let backupIdentifier = "rv.backup"

    static let privateTitle = "A deadline is coming up"
    static let privateBody = "Open ReceiptVault to see what is due."
    static let refreshTitle = "Your reminders need a refresh"
    static let refreshBody = "Open ReceiptVault to keep your reminders up to date."
    static let backupTitle = "Time for a backup"

    /// Lead times and backup intervals above this many days are ignored, so
    /// the day arithmetic cannot overflow on a wild value.
    private static let maxDays = 36_600

    // MARK: Deadlines

    /// The reminders for `inputs`, sorted by fire day, then identifier.
    /// `nowMinutes` is the local time as minutes after midnight; `hour` and
    /// `minute` are the user's reminder time.
    /// - Each lead time becomes a fire day. Fire times already past, including
    ///   earlier today, are dropped.
    /// - When every lead time has passed but the deadline has not, one
    ///   reminder fires at the next possible time, if that is still on or
    ///   before the deadline.
    /// - An item's reminders on the same day are merged into one.
    /// - Above `limit`, the soonest `limit − 1` are kept, plus 'rv.refresh' on
    ///   the last kept fire day.
    static func plan(_ inputs: [ReminderInput], today: DayDate, nowMinutes: Int, hour: Int, minute: Int, privateText: Bool, limit: Int = ReminderPlanner.limit) -> [PlannedReminder] {
        guard limit > 0 else { return [] }
        let h = ReminderPlanner.clampedHour(hour)
        let m = ReminderPlanner.clampedMinute(minute)
        let first = ReminderPlanner.nextFireDay(today: today, nowMinutes: nowMinutes, hour: h, minute: m)

        // One entry per deadline, so identifiers cannot repeat.
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for input in inputs {
            guard !seen.contains(input.deadlineID) else { continue }
            seen.insert(input.deadlineID)
            candidates.append(contentsOf: ReminderPlanner.candidates(for: input, firstFireDay: first))
        }

        // Group an item's reminders that fire on the same day.
        var groups: [GroupKey: [Candidate]] = [:]
        var keys: [GroupKey] = []
        for c in candidates {
            let key = c.input.itemID.isEmpty
                ? GroupKey(owner: c.input.deadlineID, isItem: false, day: c.fireDay)
                : GroupKey(owner: c.input.itemID, isItem: true, day: c.fireDay)
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(c)
        }

        var planned: [PlannedReminder] = []
        var used = Set<String>()
        for key in keys {
            guard let group = groups[key], !group.isEmpty else { continue }
            let reminder = group.count == 1
                ? ReminderPlanner.single(group[0], hour: h, minute: m, privateText: privateText)
                : ReminderPlanner.merged(group, hour: h, minute: m, privateText: privateText)
            guard !used.contains(reminder.identifier) else { continue }
            used.insert(reminder.identifier)
            planned.append(reminder)
        }
        planned.sort(by: ReminderPlanner.isOrderedBefore)

        guard planned.count > limit else { return planned }
        var kept = Array(planned.prefix(limit - 1))
        let lastDay = kept.last?.fireDay ?? planned[0].fireDay
        kept.append(PlannedReminder(identifier: ReminderPlanner.refreshIdentifier, itemID: "", fireDay: lastDay,
                                    hour: h, minute: m,
                                    title: ReminderPlanner.refreshTitle, body: ReminderPlanner.refreshBody))
        kept.sort(by: ReminderPlanner.isOrderedBefore)
        return kept
    }

    /// Today when the reminder time is still ahead, otherwise tomorrow.
    static func nextFireDay(today: DayDate, nowMinutes: Int, hour: Int, minute: Int) -> DayDate {
        let at = ReminderPlanner.clampedHour(hour) * 60 + ReminderPlanner.clampedMinute(minute)
        return at > nowMinutes ? today : RVCalendar.adding(days: 1, to: today)
    }

    // MARK: Text

    /// 'Return window closes in 3 days', '… tomorrow', '… today'; 'Notice
    /// must arrive in 7 days'; a custom date uses its label ('Boiler service
    /// in 3 days').
    static func title(kind: DeadlineKind, label: String, daysLeft: Int) -> String {
        let custom = ReminderPlanner.clean(label)
        if daysLeft < 0 {
            let name = (kind == .custom && !custom.isEmpty) ? custom : kind.label
            return "\(name) has passed"
        }
        let subject: String
        switch kind {
        case .returnWindow: subject = "Return window closes"
        case .cancellation: subject = "Cancellation period ends"
        case .rightToReject: subject = "Right to reject ends"
        case .faultPresumption: subject = "Fault presumption ends"
        case .manufacturerWarranty: subject = "Manufacturer warranty ends"
        case .legalGuarantee: subject = "Legal guarantee ends"
        case .claimLimit: subject = "Claim time limit ends"
        case .noticeDeadline: subject = "Notice must arrive"
        case .termEnd: subject = "Contract ends"
        case .custom: subject = custom.isEmpty ? kind.dueWording : custom
        }
        switch daysLeft {
        case 0: return "\(subject) today"
        case 1: return "\(subject) tomorrow"
        default: return "\(subject) in \(daysLeft) days"
        }
    }

    /// 'Sony WH-1000XM5 · Currys · 2024-04-09'. Empty parts are left out, and
    /// so is a merchant that repeats the title.
    static func body(itemTitle: String, merchant: String, date: DayDate) -> String {
        let name = ReminderPlanner.clean(itemTitle)
        let shop = ReminderPlanner.clean(merchant)
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        if !shop.isEmpty && shop.caseInsensitiveCompare(name) != .orderedSame { parts.append(shop) }
        parts.append(date.iso)
        return parts.joined(separator: " · ")
    }

    // MARK: Backup

    /// The backup nudge, 'rv.backup', due `everyDays` after `lastBackup`, or
    /// at the next possible time when that has passed or there has never
    /// been a backup. Nil when `everyDays` is 0 or less (turned off).
    static func backupReminder(lastBackup: DayDate?, everyDays: Int, today: DayDate, nowMinutes: Int, hour: Int, minute: Int) -> PlannedReminder? {
        guard everyDays > 0 else { return nil }
        let h = ReminderPlanner.clampedHour(hour)
        let m = ReminderPlanner.clampedMinute(minute)
        let first = ReminderPlanner.nextFireDay(today: today, nowMinutes: nowMinutes, hour: h, minute: m)
        var fireDay = first
        let text: String
        if let last = lastBackup {
            let due = RVCalendar.adding(days: min(everyDays, ReminderPlanner.maxDays), to: last)
            if first < due { fireDay = due }
            let age = RVCalendar.daysBetween(last, fireDay)
            text = "Your last encrypted backup is \(ReminderPlanner.dayCount(age)) old. Open ReceiptVault to make a new one."
        } else {
            text = "You have no encrypted backup yet. Open ReceiptVault to make one."
        }
        return PlannedReminder(identifier: ReminderPlanner.backupIdentifier, itemID: "", fireDay: fireDay,
                               hour: h, minute: m, title: ReminderPlanner.backupTitle, body: text)
    }

    // MARK: Planning helpers

    /// One deadline's reminder on one day, before merging.
    private struct Candidate {
        var input: ReminderInput
        var fireDay: DayDate
        var daysLeft: Int
        var identifier: String { "\(ReminderPlanner.prefix)\(input.deadlineID).\(daysLeft)" }
    }

    /// Merging key: an item's reminders on one day, or a single deadline's
    /// when it has no item.
    private struct GroupKey: Hashable {
        var owner: String
        var isItem: Bool
        var day: DayDate
    }

    private static func candidates(for input: ReminderInput, firstFireDay first: DayDate) -> [Candidate] {
        // Nothing can fire on or before a deadline that has passed, or one
        // that is today when today's reminder time has gone.
        guard RVCalendar.isValid(input.date), first <= input.date else { return [] }
        var leads = Set(input.offsets.filter { $0 >= 0 && $0 <= ReminderPlanner.maxDays })
        if leads.isEmpty { leads = [0] } // reminders on but no lead times: remind on the day
        var result: [Candidate] = []
        for lead in leads.sorted(by: >) {
            let fire = RVCalendar.adding(days: -lead, to: input.date)
            guard first <= fire else { continue }
            result.append(Candidate(input: input, fireDay: fire, daysLeft: lead))
        }
        if result.isEmpty {
            // Every lead time has passed: one reminder at the next possible time.
            result.append(Candidate(input: input, fireDay: first, daysLeft: RVCalendar.daysBetween(first, input.date)))
        }
        return result
    }

    private static func single(_ c: Candidate, hour: Int, minute: Int, privateText: Bool) -> PlannedReminder {
        let heading = privateText
            ? ReminderPlanner.privateTitle
            : ReminderPlanner.title(kind: c.input.kind, label: c.input.label, daysLeft: c.daysLeft)
        let text = privateText
            ? ReminderPlanner.privateBody
            : ReminderPlanner.body(itemTitle: c.input.itemTitle, merchant: c.input.merchant, date: c.input.date)
        return PlannedReminder(identifier: c.identifier, itemID: c.input.itemID, fireDay: c.fireDay,
                               hour: hour, minute: minute, title: heading, body: text)
    }

    /// '2 dates for Sony WH-1000XM5', with one line per date, soonest first.
    private static func merged(_ group: [Candidate], hour: Int, minute: Int, privateText: Bool) -> PlannedReminder {
        let ordered = group.sorted { a, b in
            a.input.date != b.input.date ? a.input.date < b.input.date : a.identifier < b.identifier
        }
        let head = ordered[0]
        let heading: String
        let text: String
        if privateText {
            heading = ReminderPlanner.privateTitle
            text = ReminderPlanner.privateBody
        } else {
            let name = ReminderPlanner.displayName(itemTitle: head.input.itemTitle, merchant: head.input.merchant)
            heading = name.isEmpty ? "\(ordered.count) dates coming up" : "\(ordered.count) dates for \(name)"
            text = ordered
                .map { ReminderPlanner.title(kind: $0.input.kind, label: $0.input.label, daysLeft: $0.daysLeft) }
                .joined(separator: "\n")
        }
        let identifier = "\(ReminderPlanner.prefix)m.\(head.input.itemID).\(head.fireDay.iso)"
        return PlannedReminder(identifier: identifier, itemID: head.input.itemID, fireDay: head.fireDay,
                               hour: hour, minute: minute, title: heading, body: text)
    }

    private static func isOrderedBefore(_ a: PlannedReminder, _ b: PlannedReminder) -> Bool {
        a.fireDay != b.fireDay ? a.fireDay < b.fireDay : a.identifier < b.identifier
    }

    private static func clampedHour(_ hour: Int) -> Int { min(max(hour, 0), 23) }
    private static func clampedMinute(_ minute: Int) -> Int { min(max(minute, 0), 59) }

    private static func dayCount(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    // MARK: Text cleaning

    /// The item title, or the merchant when there is no title.
    private static func displayName(itemTitle: String, merchant: String) -> String {
        let name = ReminderPlanner.clean(itemTitle)
        return name.isEmpty ? ReminderPlanner.clean(merchant) : name
    }

    /// Amounts in a title, merchant or label: "£299", "CHF 1'299.–",
    /// "12,50 €", and bare two-decimal numbers such as "299.00" (but not
    /// dates like "12.03.24"). A pattern that fails to compile is skipped.
    private static let amountPatterns: [NSRegularExpression] = {
        let patterns = [
            #"(?:[£€$¥]|(?<!\p{L})(?:CHF|GBP|EUR|USD|SFr|Fr)\.?(?!\p{L}))\s?-?\d+(?:[',.’\x{00A0}\x{202F}]\d{3})*(?:[.,](?:\d{1,2}|[-–]{1,2}))?"#,
            #"(?<![\p{L}\d.,'’])-?\d+(?:[',.’\x{00A0}\x{202F}]\d{3})*(?:[.,](?:\d{1,2}|[-–]{1,2}))?\s?(?:[£€$¥]|(?:CHF|GBP|EUR|USD|SFr|Fr)\.?(?!\p{L}))"#,
            #"(?<![\p{L}\d.,'’])-?\d{1,3}(?:[',.’\x{00A0}\x{202F}]?\d{3})*[.,]\d{2}(?![.,]?\d)"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—·,:;/|"))

    /// One line with amounts removed, single spaces and no stray separators
    /// at either end.
    private static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var s = text
        for regex in ReminderPlanner.amountPatterns {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for empty in ["( )", "()", "[ ]", "[]"] {
            s = s.replacingOccurrences(of: empty, with: " ")
        }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.trimmingCharacters(in: ReminderPlanner.edgeCharacters)
    }
}
