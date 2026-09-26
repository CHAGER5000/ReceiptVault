import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// The Settings tab, the Rules editor, and the backup and restore sheets.
// Turning the lock off, restoring a backup and deleting everything each ask
// for Face ID, Touch ID or the passcode first (OwnerCheck). Every file that
// leaves the phone goes through the share sheet and is deleted afterwards.

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    // The same keys and defaults as AppSettings.
    @AppStorage(SettingsKeys.lockEnabled) private var lockEnabled = true
    @AppStorage(SettingsKeys.excludeFromBackup) private var excludeFromBackup = false
    @AppStorage(SettingsKeys.privateReminderText) private var privateReminderText = true
    @AppStorage(SettingsKeys.defaultJurisdiction) private var defaultJurisdiction: Jurisdiction = Jurisdiction.englandWales
    @AppStorage(SettingsKeys.defaultCurrency) private var defaultCurrency = "GBP"
    @AppStorage(SettingsKeys.defaultChannel) private var defaultChannel: PurchaseChannel = PurchaseChannel.store
    @AppStorage(SettingsKeys.reminderHour) private var reminderHour = 9
    @AppStorage(SettingsKeys.reminderMinute) private var reminderMinute = 0
    /// Only watched, so 'Last backup' updates after a backup; the date itself
    /// is read through AppSettings.
    @AppStorage(SettingsKeys.lastBackupAt) private var lastBackupStamp: Double = 0

    @State private var checkingOwner = false
    @State private var confirmDelete = false
    @State private var showBackup = false
    @State private var showRestore = false
    @State private var exportFile: ExportFile? = nil
    @State private var message: String? = nil
    @State private var notificationsDenied = false
    @State private var itemCount = 0
    @State private var storageBytes: Int64 = 0
    /// Bumped whenever the rule book is changed here, so its rows redraw.
    @State private var rulesRevision = 0
    /// The pending resync and replan after a change, run once changes settle.
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var refreshNeedsResync = false

    private static let maxPostalBuffer = 20
    /// Minimum amounts offered, in minor units (0 = off).
    private static let minimumSteps: [Int64] = [0, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000]

    private static let backupExplanation = "Your vault is included by default, so a new iPhone set up from a backup brings it along. iCloud Backup is end-to-end encrypted only with Advanced Data Protection turned on, and an unencrypted Finder backup on a computer holds your documents readably. If you leave the vault out, only a ReceiptVault backup can bring it back."

    var body: some View {
        NavigationStack {
            Form {
                if showPasscodeWarning {
                    Section { PasscodeWarning() }
                }
                privacySection
                defaultsSection
                remindersSection
                rulesSection
                backupSection
                exportSection
                dataSection
                if let text = message {
                    Section { Text(text).font(.footnote) }
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showBackup, onDismiss: { refreshStats() }) {
                BackupSheet()
            }
            .sheet(isPresented: $showRestore, onDismiss: { refreshStats() }) {
                RestoreSheet(url: nil)
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url], onComplete: { file.cleanUp() })
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Delete every item, original file and reminder on this iPhone?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { deleteEverything() }
            } message: {
                Text("This cannot be undone. Backup files you saved elsewhere are not affected.")
            }
            .onChange(of: excludeFromBackup) { _, exclude in
                Storage.applyBackupSetting(exclude)
            }
            .onChange(of: privateReminderText) { _, _ in
                scheduleRefresh(resync: false)
            }
            .onChange(of: defaultJurisdiction) { _, place in
                defaultCurrency = place.defaultCurrency
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshState() }
            }
            .onAppear { refreshState() }
        }
    }

    // MARK: Sections

    private var privacySection: some View {
        Section {
            Toggle("Lock with Face ID", isOn: lockBinding)
                .disabled(checkingOwner)
            Toggle(isOn: $excludeFromBackup) {
                SettingsLabel(title: "Leave out of iCloud and computer backups",
                              detail: SettingsView.backupExplanation)
            }
            Toggle(isOn: $privateReminderText) {
                SettingsLabel(title: "Private reminder text", detail: privateTextDetail)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Turning the lock off needs Face ID, Touch ID or your passcode.")
        }
    }

    private var defaultsSection: some View {
        Section {
            Picker("Country", selection: $defaultJurisdiction) {
                ForEach(Jurisdiction.allCases) { place in
                    Text(place.label).tag(place)
                }
            }
            Picker("Currency", selection: $defaultCurrency) {
                ForEach(currencyChoices, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
            Picker("Usually bought", selection: $defaultChannel) {
                ForEach(PurchaseChannel.allCases) { channel in
                    Text(channel.label).tag(channel)
                }
            }
        } header: {
            Text("Defaults for new items")
        } footer: {
            Text("Used when a document does not say otherwise. You can change them on each item.")
        }
    }

    private var remindersSection: some View {
        Section {
            DatePicker("Reminder time", selection: reminderTime, displayedComponents: .hourAndMinute)
            Picker("Minimum amount", selection: minimumAmount) {
                ForEach(minimumChoices, id: \.self) { minor in
                    Text(SettingsView.minimumLabel(minor)).tag(minor)
                }
            }
            Stepper(value: postalBuffer, in: 0...SettingsView.maxPostalBuffer) {
                SettingsLabel(title: "Postal buffer",
                              detail: SettingsFormat.workingDays(currentRules.postalBufferDays))
            }
            if notificationsDenied {
                Label("Notifications are turned off for ReceiptVault in the iPhone Settings app, so reminders will not arrive.",
                      systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Items below the minimum amount get no reminders for dates worked out from now on; contracts and warranty cards always remind. 'Send by' leaves the postal buffer, counted in working days (Monday to Friday), before notice must arrive.")
        }
    }

    private var rulesSection: some View {
        Section {
            NavigationLink {
                RulesEditorView()
            } label: {
                Label("Rules and legal defaults", systemImage: "scalemass")
            }
        } footer: {
            Text(LegalNotes.disclaimer)
        }
    }

    private var backupSection: some View {
        Section {
            LabeledContent("Last backup", value: lastBackupText)
            Button {
                showBackup = true
            } label: {
                Label("Export encrypted backup…", systemImage: "lock.doc")
            }
            Button {
                showRestore = true
            } label: {
                Label("Restore from backup…", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("One file with every item and original, encrypted with a password only you know. Keep it off this iPhone, for example in iCloud Drive or on a computer. ReceiptVault reminds you \(AppSettings.backupReminderDays) days after your last backup.")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                exportCSV(onlyClaimable: false)
            } label: {
                Label("All items as CSV", systemImage: "tablecells")
            }
            Button {
                exportCSV(onlyClaimable: true)
            } label: {
                Label("Tax-claimable items as CSV", systemImage: "building.columns")
            }
        } header: {
            Text("Export")
        } footer: {
            Text("'ReceiptVault CSV v1', for Numbers, Excel or your accountant. CSV files are not encrypted: the share sheet shows where each one goes, and the copy on this iPhone is deleted afterwards.")
        }
    }

    private var dataSection: some View {
        Section {
            Button(role: .destructive) {
                askToDeleteAll()
            } label: {
                Label("Delete all data", systemImage: "trash")
            }
            .disabled(checkingOwner)
        } footer: {
            Text("Deletes every item, original file and reminder on this iPhone, after Face ID, Touch ID or your passcode.")
        }
    }

    private var aboutSection: some View {
        Section {
            Text("No internet code. Documents are read and stored only on this iPhone, encrypted while it is locked.")
            LabeledContent("Items", value: String(itemCount))
            LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
            LabeledContent("Version", value: SettingsView.versionText)
        } header: {
            Text("About")
        } footer: {
            Text("No account, no cloud and no analytics. Key dates are general information, not legal advice.")
        }
    }

    // MARK: Values

    /// Reading scenePhase re-checks on every return to the app, since a
    /// passcode may have been set in the Settings app meanwhile.
    private var showPasscodeWarning: Bool {
        _ = scenePhase
        return !OwnerCheck.deviceHasPasscode()
    }

    private var privateTextDetail: String {
        privateReminderText
            ? "Reminders say only 'A deadline is coming up'."
            : "Reminders name the item, the shop and the date. Amounts are never shown."
    }

    private var currencyChoices: [String] {
        var codes = Money.supportedCurrencies
        if !codes.contains(defaultCurrency) { codes.append(defaultCurrency) }
        return codes
    }

    private var lastBackupText: String {
        _ = lastBackupStamp
        guard let date = AppSettings.lastBackupAt else { return "Never" }
        return Formatters.dateTime(date)
    }

    /// The stored rule book; reading rulesRevision redraws after a change.
    private var currentRules: RuleBook {
        _ = rulesRevision
        return RecordService.rules
    }

    private var minimumChoices: [Int64] {
        let current = currentRules.minReminderMinor
        if SettingsView.minimumSteps.contains(current) { return SettingsView.minimumSteps }
        return (SettingsView.minimumSteps + [current]).sorted()
    }

    /// 'Off', '50 or more'. The minimum applies in each item's own currency.
    private static func minimumLabel(_ minor: Int64) -> String {
        if minor <= 0 { return "Off" }
        let amount = minor % 100 == 0 ? String(minor / 100) : Money.plain(minor)
        return "\(amount) or more"
    }

    /// '1.0 (1)', from the bundle.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    // MARK: Bindings

    /// Turning the lock on is immediate; turning it off waits for OwnerCheck.
    /// While the check runs the switch stays on (checkingOwner redraws it).
    private var lockBinding: Binding<Bool> {
        Binding<Bool>(
            get: { lockEnabled },
            set: { newValue in
                if newValue {
                    lockEnabled = true
                } else {
                    confirmTurningOffLock()
                }
            }
        )
    }

    /// Today at the reminder hour and minute, in local time.
    private var reminderTime: Binding<Date> {
        Binding<Date>(
            get: {
                let hour = min(max(reminderHour, 0), 23)
                let minute = min(max(reminderMinute, 0), 59)
                return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                let hour = parts.hour ?? 9
                let minute = parts.minute ?? 0
                guard hour != reminderHour || minute != reminderMinute else { return }
                reminderHour = hour
                reminderMinute = minute
                scheduleRefresh(resync: false)
            }
        )
    }

    private var minimumAmount: Binding<Int64> {
        Binding<Int64>(
            get: { currentRules.minReminderMinor },
            set: { newValue in
                let minor = max(newValue, 0)
                updateRules { book in book.minReminderMinor = minor }
            }
        )
    }

    private var postalBuffer: Binding<Int> {
        Binding<Int>(
            get: { currentRules.postalBufferDays },
            set: { newValue in
                let days = min(max(newValue, 0), SettingsView.maxPostalBuffer)
                updateRules { book in book.postalBufferDays = days }
            }
        )
    }

    // MARK: Actions

    private func confirmTurningOffLock() {
        guard !checkingOwner else { return }
        checkingOwner = true
        Task { @MainActor in
            let confirmed = await OwnerCheck.confirm(reason: "Turn off the ReceiptVault lock")
            checkingOwner = false
            if confirmed { lockEnabled = false }
        }
    }

    private func askToDeleteAll() {
        guard !checkingOwner else { return }
        checkingOwner = true
        message = nil
        Task { @MainActor in
            let confirmed = await OwnerCheck.confirm(reason: "Delete all ReceiptVault data")
            checkingOwner = false
            if confirmed { confirmDelete = true }
        }
    }

    /// RecordService.deleteAll sets pendingWipe first, so even after an error
    /// the store files go at the next launch; the reminders go either way.
    private func deleteEverything() {
        refreshTask?.cancel()
        refreshTask = nil
        do {
            try RecordService.deleteAll(context: context)
            message = "Everything has been deleted from this iPhone. The database file itself is wiped the next time ReceiptVault starts."
        } catch {
            message = "Some data could not be deleted now (\(error.localizedDescription)). It will be wiped the next time ReceiptVault starts."
        }
        Task { @MainActor in
            await NotificationScheduler.removeAll()
        }
        refreshStats()
    }

    private func exportCSV(onlyClaimable: Bool) {
        message = nil
        let items = RecordService.fetchItems(context: context)
        if items.isEmpty {
            message = "There are no items to export yet."
            return
        }
        if onlyClaimable && !items.contains(where: { $0.taxTag != TaxTag.none }) {
            message = "No items are marked as tax-claimable yet."
            return
        }
        do {
            let url = try CSVFile.make(items: items, onlyClaimable: onlyClaimable)
            exportFile = ExportFile(url: url)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Stores a changed rule book, then resyncs and replans once changes settle.
    private func updateRules(_ change: (inout RuleBook) -> Void) {
        var book = RecordService.rules
        let before = book
        change(&book)
        guard book != before else { return }
        RecordService.rules = book
        rulesRevision &+= 1
        scheduleRefresh(resync: true)
    }

    /// Steppers and the time picker change in quick steps, so the work waits
    /// until nothing has changed for a moment.
    private func scheduleRefresh(resync: Bool) {
        if resync { refreshNeedsResync = true }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            if refreshNeedsResync {
                refreshNeedsResync = false
                try? RecordService.resyncAll(context: context)
            }
            await NotificationScheduler.replan(context: context)
        }
    }

    private func refreshState() {
        refreshStats()
        Task { @MainActor in
            notificationsDenied = await NotificationScheduler.isDenied()
        }
    }

    private func refreshStats() {
        itemCount = (try? context.fetchCount(FetchDescriptor<VaultItem>())) ?? 0
        storageBytes = FileVault.totalBytes()
    }
}

// MARK: - Rules editor

/// Every default behind the key dates, editable and never presented as
/// certain. Nothing is stored until 'Save and apply to existing items'.
struct RulesEditorView: View {
    @Environment(\.modelContext) private var context
    @State private var book: RuleBook = RecordService.rules
    /// What is stored, to tell whether there are unsaved changes.
    @State private var savedBook: RuleBook = RecordService.rules
    @State private var confirmReset = false
    @State private var message: String? = nil
    /// The NavigationLink builds this view ahead of time, so the initial
    /// values above can predate a save made on an earlier visit; the stored
    /// book is read again once, when the editor first appears.
    @State private var loaded = false

    var body: some View {
        Form {
            introSection
            ForEach(Jurisdiction.allCases) { place in
                RulesJurisdictionSection(jurisdiction: place, rules: rulesBinding(place))
            }
            presetsIntroSection
            ForEach($book.presets) { preset in
                RulesPresetSection(preset: preset)
            }
            actionsSection
            if let text = message {
                Section { Text(text).font(.footnote) }
            }
        }
        .navigationTitle("Rules and legal defaults")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset every rule and contract preset to the built-in defaults?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset and apply", role: .destructive) { resetToDefaults() }
        } message: {
            Text("The dates of your items are worked out again from the defaults.")
        }
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let stored = RecordService.rules
        book = stored
        savedBook = stored
    }

    private var introSection: some View {
        Section {
            Text(LegalNotes.disclaimer)
            Text("0 means a rule does not apply. 'Assumed' marks a typical value or a simplification rather than a clear legal rule, and 'You' marks a value you have changed. A period printed on a document, or entered on an item, always wins.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var presetsIntroSection: some View {
        Section {
            Text("Used when you pick a preset for a new contract. Contracts you have already saved keep their own terms.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Contract presets")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                save(done: "Saved. The dates of your items now follow these rules.")
            } label: {
                Label("Save and apply to existing items", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Reset to defaults", systemImage: "arrow.uturn.backward")
            }
        } footer: {
            if book != savedBook {
                Text("You have changes that are not saved yet.")
            } else {
                Text("Custom dates you added to an item are never changed.")
            }
        }
    }

    private func rulesBinding(_ place: Jurisdiction) -> Binding<JurisdictionRules> {
        Binding<JurisdictionRules>(
            get: { book.rules(for: place) },
            set: { newValue in book.rules[place.rawValue] = newValue }
        )
    }

    /// Stores the book (keeping the postal buffer and minimum amount, which
    /// Settings edits), then resyncs every item and replans the reminders.
    private func save(done text: String) {
        var updated = book
        let current = RecordService.rules
        updated.postalBufferDays = current.postalBufferDays
        updated.minReminderMinor = current.minReminderMinor
        RecordService.rules = updated
        let stored = RecordService.rules
        book = stored
        savedBook = stored
        do {
            try RecordService.resyncAll(context: context)
            message = text
        } catch {
            message = "The rules were saved, but your items could not be updated: \(error.localizedDescription)"
        }
        Task { @MainActor in
            await NotificationScheduler.replan(context: context)
        }
    }

    private func resetToDefaults() {
        book = RuleBook.defaults
        save(done: "The built-in defaults are back, and the dates of your items follow them.")
    }
}

/// One jurisdiction's defaults: a stepper per RuleField.
private struct RulesJurisdictionSection: View {
    var jurisdiction: Jurisdiction
    @Binding var rules: JurisdictionRules

    var body: some View {
        Section {
            ForEach(RuleField.allCases) { field in
                RuleValueRow(field: field, jurisdiction: jurisdiction, value: binding(for: field))
            }
        } header: {
            Text(jurisdiction.label)
        } footer: {
            Text(RulesJurisdictionSection.note(for: jurisdiction))
        }
    }

    private func binding(for field: RuleField) -> Binding<Int> {
        Binding<Int>(
            get: { rules.value(field) },
            set: { newValue in rules.set(field, newValue) }
        )
    }

    private static func note(for place: Jurisdiction) -> String {
        switch place {
        case .englandWales:
            return "Northern Ireland is assumed to follow the same periods."
        case .scotland:
            return "The 5-year claim limit is counted from delivery, a simplification (assumed)."
        case .switzerland:
            return "Report defects promptly and in writing (OR Art. 201). Sellers may limit the guarantee in their terms (OR Art. 199)."
        case .eu:
            return "These are EU minimums; many countries give more, for example a longer fault presumption."
        }
    }
}

/// A rule value with its basis, and 'Assumed' or 'You' when it applies.
private struct RuleValueRow: View {
    var field: RuleField
    var jurisdiction: Jurisdiction
    @Binding var value: Int

    var body: some View {
        Stepper(value: $value, in: 0...field.maxValue) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                HStack(spacing: 6) {
                    Text(SettingsFormat.amount(value, unit: field.unit))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if isChanged {
                        CertaintyBadge(certainty: Certainty.user)
                    } else if basis.isAssumption {
                        CertaintyBadge(certainty: Certainty.assumption)
                    }
                }
                Text(basis.basis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isChanged {
                    Text("Default: \(SettingsFormat.amount(defaultValue, unit: field.unit))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var basis: RuleBasis { RuleBases.basis(field, jurisdiction) }
    private var defaultValue: Int { RuleBook.defaults.rules(for: jurisdiction).value(field) }
    private var isChanged: Bool { value != defaultValue }
}

/// A contract preset: notice value and renewal months, with its note.
private struct RulesPresetSection: View {
    @Binding var preset: ContractPreset

    private static let maxRenewalMonths = 120

    var body: some View {
        Section {
            Stepper(value: $preset.notice.value, in: 0...noticeLimit) {
                SettingsLabel(title: "Notice period", detail: preset.notice.label)
            }
            Stepper(value: $preset.renewalMonths, in: 1...RulesPresetSection.maxRenewalMonths) {
                SettingsLabel(title: "Renews", detail: renewalText)
            }
        } header: {
            Text(preset.name.isEmpty ? preset.id : preset.name)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if preset.isAssumption {
                    CertaintyBadge(certainty: Certainty.assumption)
                }
                Text(preset.note)
            }
        }
    }

    private var noticeLimit: Int {
        switch preset.notice.unit {
        case .days: return 365
        case .weeks: return 104
        case .months: return 36
        }
    }

    private var renewalText: String {
        if !preset.autoRenews { return "Does not renew" }
        let months = preset.renewalMonths
        return months == 1 ? "Every month" : "Every \(months) months"
    }
}

// MARK: - Backup

/// Makes a password-encrypted .rvault file and hands it to the share sheet.
/// The file is deleted from the export folder when the share sheet closes.
struct BackupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var backup = BackupService()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var failure: String? = nil
    @State private var shareFile: ExportFile? = nil
    /// The name of the backup once it has been made.
    @State private var madeName: String? = nil
    @State private var vaultEmpty = false

    var body: some View {
        NavigationStack {
            Form {
                if let name = madeName {
                    doneSection(name)
                } else if vaultEmpty {
                    Section {
                        Text("There is nothing to back up yet. Once you have saved a receipt, come back here to make an encrypted backup.")
                    }
                } else {
                    passwordSection
                    checksSection
                    if working {
                        progressSection
                    }
                    if let text = failure {
                        Section {
                            Label(text, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.red)
                        }
                    }
                    exportSection
                }
            }
            .navigationTitle("Encrypted backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(madeName == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(working)
                }
            }
            .interactiveDismissDisabled(working)
            .sheet(item: $shareFile) { file in
                ShareSheet(items: [file.url], onComplete: { file.cleanUp() })
                    .presentationDetents([.medium, .large])
            }
            .onAppear {
                let count = (try? context.fetchCount(FetchDescriptor<VaultItem>())) ?? 1
                vaultEmpty = count == 0
            }
        }
    }

    private var problems: [String] {
        BackupPassword.problems(password, confirm: confirmation)
    }

    private var passwordSection: some View {
        Section {
            SecureField("Password", text: $password)
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Type it again", text: $confirmation)
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Backup password")
        } footer: {
            Text(BackupPassword.advice)
        }
        .disabled(working)
    }

    private var checksSection: some View {
        Section {
            if problems.isEmpty {
                Label("This password can be used", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            } else {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "xmark.circle")
                        .foregroundStyle(Color.orange)
                }
            }
            Label("Nobody can recover this password, not even ReceiptVault. Without it, the backup cannot be opened.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(backup.phase.isEmpty ? "Preparing the backup…" : backup.phase)
                    .font(.subheadline)
                ProgressView(value: SettingsFormat.fraction(backup.progress))
            }
            .padding(.vertical, 4)
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                export()
            } label: {
                Label("Encrypt and export", systemImage: "lock.doc")
            }
            .disabled(!problems.isEmpty || working)
        } footer: {
            Text("Every item and original file goes into one encrypted file. Save it with 'Save to Files' or AirDrop it to a computer; ReceiptVault deletes its own copy once the share sheet closes.")
        }
    }

    private func doneSection(_ name: String) -> some View {
        Section {
            Label("Backup made", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.green)
            LabeledContent("File", value: name)
            Text("Keep the file somewhere other than this iPhone, and the password in the Passwords app. If you closed the share sheet without saving the file, make a new backup.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func export() {
        let secret = password
        guard !working, BackupPassword.problems(secret, confirm: confirmation).isEmpty else { return }
        working = true
        failure = nil
        Task { @MainActor in
            do {
                let url = try await backup.export(password: secret, context: context)
                password = ""
                confirmation = ""
                madeName = url.lastPathComponent
                shareFile = ExportFile(url: url)
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Restore

/// Restores a .rvault backup: a file shared with 'Open in' (`url`), or one
/// picked here (nil opens the file picker first). OwnerCheck runs before the
/// first restore attempt. Only items that are not on the phone yet are added.
struct RestoreSheet: View {
    var url: URL?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var backup = BackupService()
    @State private var chosen: URL? = nil
    @State private var showImporter = false
    @State private var askedForFile = false
    @State private var password = ""
    @State private var working = false
    @State private var ownerConfirmed = false
    @State private var summary: RestoreSummary? = nil
    @State private var failure: String? = nil

    init(url: URL? = nil) {
        self.url = url
    }

    var body: some View {
        NavigationStack {
            Form {
                if let result = summary {
                    resultSection(result)
                } else {
                    fileSection
                    if source != nil {
                        passwordSection
                    }
                    if working {
                        progressSection
                    }
                    if let text = failure {
                        Section {
                            Label(text, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.red)
                        }
                    }
                }
            }
            .navigationTitle("Restore backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(summary == nil ? "Cancel" : "Done") { close() }
                        .disabled(working)
                }
            }
            .interactiveDismissDisabled(working)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType.rvaultBackup, UTType.data]) { result in
                picked(result)
            }
            .task { await askForFileIfNeeded() }
        }
    }

    /// The picked file, else the one shared with 'Open in'.
    private var source: URL? { chosen ?? url }

    private var fileSection: some View {
        Section {
            if let file = source {
                LabeledContent("Backup file", value: RestoreSheet.displayName(file))
            } else {
                Text("Choose the .rvault file you saved, for example in Files or iCloud Drive.")
                    .foregroundStyle(.secondary)
            }
            Button(source == nil ? "Choose backup file…" : "Choose a different file…") {
                showImporter = true
            }
            .disabled(working)
        } footer: {
            Text("Only items that are not on this iPhone yet are added. Nothing already here is changed or deleted.")
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField("Backup password", text: $password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { restore() }
                .disabled(working)
            Button {
                restore()
            } label: {
                Label("Restore", systemImage: "arrow.counterclockwise")
            }
            .disabled(password.isEmpty || working)
        } header: {
            Text("Password")
        } footer: {
            Text("The password you chose when you made this backup. ReceiptVault asks for Face ID, Touch ID or your passcode before it restores.")
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(backup.phase.isEmpty ? "Checking it's you…" : backup.phase)
                    .font(.subheadline)
                ProgressView(value: SettingsFormat.fraction(backup.progress))
            }
            .padding(.vertical, 4)
        }
    }

    private func resultSection(_ result: RestoreSummary) -> some View {
        Section {
            Label(result.message, systemImage: "checkmark.circle")
            if result.added > 0 {
                Text("The restored items are in the Library, and their reminders are planned again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    /// Opens the picker once when no file was handed over, after the sheet
    /// has finished sliding in.
    private func askForFileIfNeeded() async {
        guard url == nil, chosen == nil, !askedForFile else { return }
        askedForFile = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled, summary == nil, chosen == nil else { return }
        showImporter = true
    }

    private func picked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let file):
            chosen = file
            failure = nil
        case .failure(let error):
            // Closing the picker is not an error worth showing.
            if let cocoa = error as? CocoaError, cocoa.code == CocoaError.Code.userCancelled { return }
            failure = error.localizedDescription
        }
    }

    private func restore() {
        guard let file = source, !password.isEmpty, !working else { return }
        let secret = password
        working = true
        failure = nil
        Task { @MainActor in
            if !ownerConfirmed {
                ownerConfirmed = await OwnerCheck.confirm(reason: "Restore a backup into ReceiptVault")
            }
            guard ownerConfirmed else {
                failure = "Restoring needs Face ID, Touch ID or your passcode."
                working = false
                return
            }
            do {
                summary = try await backup.restore(from: file, password: secret, context: context)
                password = ""
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }

    /// A backup shared with 'Open in' waits as a copy in staging; it goes when
    /// the sheet closes (the original stays where it was shared from).
    private func close() {
        if let given = url, RestoreSheet.isStaged(given) {
            try? FileManager.default.removeItem(at: given)
        }
        dismiss()
    }

    private static func displayName(_ file: URL) -> String {
        RestoreSheet.isStaged(file) ? "Shared with ReceiptVault" : file.lastPathComponent
    }

    /// True when the file lies inside Staging/Incoming.
    private static func isStaged(_ file: URL) -> Bool {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let base = Storage.incomingDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix)
    }
}

// MARK: - Helpers

/// A title with a smaller explanation or value below it.
private struct SettingsLabel: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private enum SettingsFormat {
    /// '28 days', '1 month', '6 years'; 'Does not apply' for 0.
    static func amount(_ value: Int, unit: String) -> String {
        if value <= 0 { return "Does not apply" }
        if value == 1 { return "1 " + String(unit.dropLast()) }
        return "\(value) \(unit)"
    }

    /// '5 working days', '1 working day'.
    static func workingDays(_ days: Int) -> String {
        if days <= 0 { return "None: send by the deadline itself" }
        return days == 1 ? "1 working day" : "\(days) working days"
    }

    /// 0...1 for a ProgressView.
    static func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
