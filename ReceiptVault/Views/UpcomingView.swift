import SwiftUI
import SwiftData

// The Upcoming tab: the dates that need action soon. Deadlines with
// reminders on are grouped as Overdue (open, last 30 days), Next 7 days,
// Next 30 days and Later; a swipe marks one done (or undoes it) through
// RecordService, followed by a replan. An empty vault shows the welcome
// card instead. Queries fetch everything and filter in Swift (no #Predicate),
// and each part is its own small struct so type-checking stays fast.

// MARK: - Upcoming

/// The home tab.
struct UpcomingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var capture: CaptureModel

    @Query(sort: \Deadline.date) private var deadlines: [Deadline]
    @Query private var items: [VaultItem]

    // The same keys and defaults as AppSettings.
    @AppStorage(SettingsKeys.reminderHour) private var reminderHour = 9
    @AppStorage(SettingsKeys.reminderMinute) private var reminderMinute = 0
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false

    @State private var notificationsDenied = false
    @State private var problem: String? = nil

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Upcoming")
                // Pushed by value, so a pushed screen stays when its row
                // leaves a filtered list (see ItemDestinationView).
                .navigationDestination(for: UUID.self) { id in
                    ItemDestinationView(id: id)
                }
                .navigationDestination(for: UpcomingRoute.self) { _ in
                    NeedsReviewView()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        AddMenu()
                            .disabled(capture.working != nil)
                    }
                }
                .alert("Could not save", isPresented: problemShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(problem ?? "")
                }
                .task { await refreshPermission() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await refreshPermission() }
                    }
                }
                .onChange(of: items.isEmpty, initial: true) { _, empty in
                    // The first item means the defaults have been accepted
                    // (also when the vault already held items at launch).
                    if !empty && !onboardingDone { onboardingDone = true }
                }
        }
    }

    private var content: some View {
        let today: DayDate = RVCalendar.today()
        let sections: [UpcomingSection] = UpcomingSection.build(deadlines, today: today)
        return List {
            if showsPasscodeWarning {
                Section { PasscodeWarning() }
            }
            if items.isEmpty {
                WelcomeCard()
            } else {
                UpcomingAgenda(sections: sections,
                               today: today,
                               reviewCount: reviewCount,
                               reminderTime: reminderTimeText,
                               notificationsDenied: notificationsDenied,
                               onDone: { row, done in setDone(row, done) })
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: State

    /// Reading scenePhase re-checks on every return to the app, since a
    /// passcode may have been set in the Settings app meanwhile.
    private var showsPasscodeWarning: Bool {
        _ = scenePhase
        return !OwnerCheck.deviceHasPasscode()
    }

    private var reviewCount: Int {
        items.filter { $0.needsReview }.count
    }

    /// The reminder time in the phone's own format, e.g. '09:00' or '9:00 AM'.
    private var reminderTimeText: String {
        let hour = min(max(reminderHour, 0), 23)
        let minute = min(max(reminderMinute, 0), 59)
        if let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private var problemShown: Binding<Bool> {
        Binding<Bool>(
            get: { problem != nil },
            set: { shown in if !shown { problem = nil } }
        )
    }

    // MARK: Actions

    /// Done stops the date's reminders; Undo brings them back.
    private func setDone(_ row: Deadline, _ done: Bool) {
        do {
            try RecordService.setDone(row, done, context: context)
        } catch {
            context.rollback()
            problem = error.localizedDescription
            return
        }
        let modelContext = context
        Task { @MainActor in
            await NotificationScheduler.replan(context: modelContext)
        }
    }

    private func refreshPermission() async {
        notificationsDenied = await NotificationScheduler.isDenied()
    }
}

// MARK: - Grouping

/// Where a reminded deadline sits on the Upcoming tab.
private enum UpcomingGroup: Int, CaseIterable, Identifiable {
    case overdue, week, month, later

    /// How many days back an open date still shows as overdue.
    static let overdueDays = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .week: return "Next 7 days"
        case .month: return "Next 30 days"
        case .later: return "Later"
        }
    }

    var note: String? {
        switch self {
        case .overdue:
            return "Dates from the last \(UpcomingGroup.overdueDays) days that are not marked done yet."
        case .week, .month, .later:
            return nil
        }
    }

    /// The group of a date `days` from today (0 = today); nil when it is not
    /// shown: done and passed, or passed more than 30 days ago.
    static func group(days: Int, isDone: Bool) -> UpcomingGroup? {
        if days < 0 {
            guard !isDone, days >= -UpcomingGroup.overdueDays else { return nil }
            return UpcomingGroup.overdue
        }
        if days <= 7 { return UpcomingGroup.week }
        if days <= 30 { return UpcomingGroup.month }
        return UpcomingGroup.later
    }
}

/// One group's deadlines, soonest first.
private struct UpcomingSection: Identifiable {
    let group: UpcomingGroup
    let rows: [Deadline]

    var id: Int { group.rawValue }

    /// The deadlines with reminders on that still belong to an item, in
    /// group order. Empty groups are left out.
    static func build(_ deadlines: [Deadline], today: DayDate) -> [UpcomingSection] {
        var buckets: [UpcomingGroup: [Deadline]] = [:]
        for row in deadlines where row.remindersOn && row.item != nil {
            let days = RVCalendar.daysBetween(today, row.day)
            guard let group = UpcomingGroup.group(days: days, isDone: row.isDone) else { continue }
            buckets[group, default: []].append(row)
        }
        var result: [UpcomingSection] = []
        for group in UpcomingGroup.allCases {
            guard let rows = buckets[group], !rows.isEmpty else { continue }
            result.append(UpcomingSection(group: group, rows: rows.sorted(by: UpcomingSection.isOrdered)))
        }
        return result
    }

    /// By day; the same day keeps the timeline's kind order.
    private static func isOrdered(_ a: Deadline, _ b: Deadline) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.kindOrder != b.kindOrder { return a.kindOrder < b.kindOrder }
        return a.id.uuidString < b.id.uuidString
    }
}

/// The words used in the header counts.
private enum UpcomingTally: CaseIterable {
    case returns, warranties, notices, contractEnds, other

    static func of(_ kind: DeadlineKind) -> UpcomingTally {
        switch kind {
        case .returnWindow, .cancellation, .rightToReject:
            return UpcomingTally.returns
        case .faultPresumption, .manufacturerWarranty, .legalGuarantee, .claimLimit:
            return UpcomingTally.warranties
        case .noticeDeadline:
            return UpcomingTally.notices
        case .termEnd:
            return UpcomingTally.contractEnds
        case .custom:
            return UpcomingTally.other
        }
    }

    /// '1 return', '5 warranties'.
    func text(_ n: Int) -> String {
        let word: String
        switch self {
        case .returns: word = n == 1 ? "return" : "returns"
        case .warranties: word = n == 1 ? "warranty" : "warranties"
        case .notices: word = n == 1 ? "notice" : "notices"
        case .contractEnds: word = n == 1 ? "contract end" : "contract ends"
        case .other: word = n == 1 ? "other date" : "other dates"
        }
        return "\(n) \(word)"
    }
}

/// '2 returns · 5 warranties · 1 notice', then '1 overdue · 2 in the next
/// 7 days'. Only dates not marked done are counted.
private struct UpcomingSummary {
    var headline: String
    var detail: String?
    var hasOverdue: Bool

    static func make(_ sections: [UpcomingSection]) -> UpcomingSummary {
        var counts: [UpcomingTally: Int] = [:]
        var overdue = 0
        var soon = 0
        for section in sections {
            for row in section.rows where !row.isDone {
                counts[UpcomingTally.of(row.kind), default: 0] += 1
                if section.group == UpcomingGroup.overdue { overdue += 1 }
                if section.group == UpcomingGroup.week { soon += 1 }
            }
        }
        var parts: [String] = []
        for tally in UpcomingTally.allCases {
            let n = counts[tally] ?? 0
            if n > 0 { parts.append(tally.text(n)) }
        }
        var details: [String] = []
        if overdue > 0 { details.append("\(overdue) overdue") }
        if soon > 0 { details.append("\(soon) in the next 7 days") }
        let headline: String = parts.isEmpty ? "All caught up" : parts.joined(separator: " · ")
        let detail: String? = details.isEmpty ? nil : details.joined(separator: " · ")
        return UpcomingSummary(headline: headline, detail: detail, hasOverdue: overdue > 0)
    }
}

// MARK: - Agenda

/// The screens Upcoming pushes by value besides an item (whose value is its
/// id). 'Needs a look' is one too: its link disappears once no item needs a
/// look, which would otherwise pop it together with the detail on top.
enum UpcomingRoute: Hashable {
    case needsReview
}

/// Everything below the passcode warning when the vault has items: the
/// 'Needs a look' link, the header counts and the date groups.
private struct UpcomingAgenda: View {
    var sections: [UpcomingSection]
    var today: DayDate
    var reviewCount: Int
    var reminderTime: String
    var notificationsDenied: Bool
    var onDone: (Deadline, Bool) -> Void

    var body: some View {
        if reviewCount > 0 {
            Section {
                NavigationLink(value: UpcomingRoute.needsReview) {
                    UpcomingReviewLabel(count: reviewCount)
                }
            }
        }
        if sections.isEmpty {
            ContentUnavailableView("Nothing coming up",
                                   systemImage: "calendar.badge.checkmark",
                                   description: Text("Dates with reminders on appear here, soonest first. Open an item to see all of its dates."))
        } else {
            UpcomingSummarySection(summary: UpcomingSummary.make(sections),
                                   reminderTime: reminderTime,
                                   notificationsDenied: notificationsDenied)
            ForEach(sections) { section in
                UpcomingGroupSection(section: section,
                                     today: today,
                                     showsDisclaimer: section.id == lastID,
                                     onDone: onDone)
            }
        }
    }

    /// The disclaimer goes under the last group.
    private var lastID: Int? { sections.last?.id }
}

/// 'Needs a look (3)', which opens NeedsReviewView.
private struct UpcomingReviewLabel: View {
    var count: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs a look (\(count))")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.orange)
        }
    }

    private var detail: String {
        count == 1
            ? "Some details of 1 item were hard to read."
            : "Some details of \(count) items were hard to read."
    }
}

/// The header counts, and a warning when notifications are turned off.
private struct UpcomingSummarySection: View {
    var summary: UpcomingSummary
    var reminderTime: String
    var notificationsDenied: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.headline)
                    .font(.headline)
                if let detail = summary.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(summary.hasOverdue ? Color.red : Color.secondary)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            if notificationsDenied {
                Label("Notifications are turned off for ReceiptVault in the iPhone Settings app, so reminders will not arrive.",
                      systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
            }
        } footer: {
            Text("Reminders arrive at \(reminderTime), a few days before each date. Swipe a date to mark it done.")
        }
    }
}

/// One group ('Next 7 days') of deadline rows.
private struct UpcomingGroupSection: View {
    var section: UpcomingSection
    var today: DayDate
    var showsDisclaimer: Bool
    var onDone: (Deadline, Bool) -> Void

    var body: some View {
        Section {
            ForEach(section.rows) { row in
                UpcomingDeadlineLink(deadline: row, today: today, onDone: onDone)
            }
        } header: {
            Text(section.group.title)
        } footer: {
            if section.group.note != nil || showsDisclaimer {
                VStack(alignment: .leading, spacing: 6) {
                    if let note = section.group.note {
                        Text(note)
                    }
                    if showsDisclaimer {
                        NotLegalAdviceFooter()
                    }
                }
            }
        }
    }
}

/// A deadline row that opens its item, with a Done or Undo swipe.
private struct UpcomingDeadlineLink: View {
    var deadline: Deadline
    var today: DayDate
    var onDone: (Deadline, Bool) -> Void

    var body: some View {
        if let owner = deadline.item {
            NavigationLink(value: owner.id) {
                DeadlineRow(deadline: deadline, today: today)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                swipeButton
            }
        }
    }

    @ViewBuilder
    private var swipeButton: some View {
        if deadline.isDone {
            Button {
                onDone(deadline, false)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .tint(Color.gray)
        } else {
            Button {
                onDone(deadline, true)
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .tint(Color.green)
        }
    }
}

// MARK: - Needs a look

/// Items whose shop, date or total could not be read with confidence. Saving
/// an item in Edit clears the flag. Pushed onto Upcoming's stack, whose
/// UUID destination opens the item.
struct NeedsReviewView: View {
    @Query(sort: \VaultItem.purchaseDate, order: .reverse) private var items: [VaultItem]

    var body: some View {
        List {
            if flagged.isEmpty {
                ContentUnavailableView("Nothing needs a look",
                                       systemImage: "checkmark.circle",
                                       description: Text("Items whose shop, date or total could not be read with confidence appear here until you check them."))
            } else {
                Section {
                    ForEach(flagged) { item in
                        NavigationLink(value: item.id) {
                            NeedsReviewRow(item: item)
                        }
                    }
                } footer: {
                    Text("Open an item and tap Edit to check what was read. Saving it removes it from this list.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Needs a look")
    }

    /// Newest purchase first.
    private var flagged: [VaultItem] {
        items.filter { $0.needsReview }
    }
}

/// Thumbnail, title, merchant · date, the fields to check, and the total.
private struct NeedsReviewRow: View {
    var item: VaultItem

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(file: item.sortedFiles.first, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(checkText)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            Spacer(minLength: 8)
            if let total = item.totalMinor {
                AmountText(minor: total, currency: item.currency)
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? item.kind.label : title
    }

    /// 'Merchant · 12 Mar 2026'; just the date when the merchant is blank or
    /// repeats the title.
    private var subtitle: String {
        let merchant = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Formatters.day(item.purchaseDay)
        if merchant.isEmpty || merchant.caseInsensitiveCompare(titleText) == .orderedSame {
            return date
        }
        return "\(merchant) · \(date)"
    }

    /// 'Please check: Purchase date, Total', in form order.
    private var checkText: String {
        let checks = item.checks
        let labels: [String] = FillField.allCases.filter { checks.contains($0) }.map { $0.label }
        if labels.isEmpty { return "Some details were hard to read" }
        return "Please check: " + labels.joined(separator: ", ")
    }
}

// MARK: - Welcome

/// The empty-vault welcome, as list sections: where you usually shop (the
/// default country and currency), whether the vault goes into iPhone
/// backups, and three lines on how to start. 'Use these settings' sets
/// onboardingDone, after which the choices fold into a summary.
struct WelcomeCard: View {
    // The same keys and defaults as AppSettings.
    @AppStorage(SettingsKeys.defaultJurisdiction) private var defaultJurisdiction: Jurisdiction = Jurisdiction.englandWales
    @AppStorage(SettingsKeys.defaultCurrency) private var defaultCurrency = "GBP"
    @AppStorage(SettingsKeys.excludeFromBackup) private var excludeFromBackup = false
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false
    @EnvironmentObject private var capture: CaptureModel

    /// Opens the choices again after onboarding.
    @State private var editing = false

    private static let backupNote = "When on, a new iPhone set up from an iCloud or computer backup brings your vault along. iCloud Backup is end-to-end encrypted only with Advanced Data Protection turned on, and an unencrypted computer backup holds your documents readably. When off, only a ReceiptVault backup file can bring the vault back."

    var body: some View {
        introSection
        if showsChoices {
            regionSection
            backupSection
            doneSection
        } else {
            summarySection
        }
        howToSection
    }

    // MARK: Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Welcome to ReceiptVault", systemImage: "lock.doc")
                    .font(.title3.weight(.semibold))
                Text("Receipts, invoices, warranty cards and contracts, read and kept only on this iPhone. ReceiptVault works out the dates that matter, such as return windows, warranties and notice deadlines, and reminds you before they pass.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var regionSection: some View {
        Section {
            Picker("Country", selection: region) {
                ForEach(Jurisdiction.allCases) { place in
                    Text(place.label).tag(place)
                }
            }
            LabeledContent("Currency", value: defaultCurrency)
        } header: {
            Text("Where do you usually shop?")
        } footer: {
            Text("Sets the consumer rules and the currency for new items. You can change both on any item, and later in Settings.")
        }
    }

    private var backupSection: some View {
        Section {
            Toggle("Include in iPhone backups", isOn: includeInBackups)
        } footer: {
            Text(WelcomeCard.backupNote)
        }
    }

    private var doneSection: some View {
        Section {
            Button {
                onboardingDone = true
                editing = false
            } label: {
                Text("Use these settings")
                    .font(.body.weight(.semibold))
            }
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Country", value: defaultJurisdiction.label)
            LabeledContent("Currency", value: defaultCurrency)
            LabeledContent("iPhone backups", value: backupText)
            Button("Change") { editing = true }
        } header: {
            Text("Your defaults")
        } footer: {
            Text("These can also be changed in Settings.")
        }
    }

    private var howToSection: some View {
        Section {
            Label("Tap Add to scan a receipt, or to choose photos or files.", systemImage: "doc.viewfinder")
            Label("Or share a PDF to ReceiptVault from Mail, Files or SlimScan.", systemImage: "square.and.arrow.up")
            Label("Check what was read. ReceiptVault works out the key dates and reminds you before each one.", systemImage: "bell")
            AddMenu()
                .disabled(capture.working != nil)
        } header: {
            Text("How it works")
        } footer: {
            Text("Moving from another iPhone? Restore your ReceiptVault backup in Settings › Backup.")
        }
    }

    // MARK: Values

    private var showsChoices: Bool { !onboardingDone || editing }

    private var backupText: String { excludeFromBackup ? "Left out" : "Included" }

    /// Choosing a country also sets its currency.
    private var region: Binding<Jurisdiction> {
        Binding<Jurisdiction>(
            get: { defaultJurisdiction },
            set: { place in
                defaultJurisdiction = place
                defaultCurrency = place.defaultCurrency
            }
        )
    }

    /// The inverse of excludeFromBackup, applied to the vault folder at once.
    private var includeInBackups: Binding<Bool> {
        Binding<Bool>(
            get: { !excludeFromBackup },
            set: { include in
                excludeFromBackup = !include
                Storage.applyBackupSetting(!include)
            }
        )
    }
}
