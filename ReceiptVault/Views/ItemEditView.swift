import SwiftUI
import SwiftData
import UIKit

// The review-and-edit sheet. It edits an ItemForm held in @State, so nothing
// reaches the item until Save (RecordService.apply): Close and Cancel change
// nothing. Right after a capture (isNew) the item is already saved, so Close
// keeps it as it was read and Discard deletes it. Every section is its own
// small struct over a Binding<ItemForm>, which keeps type-checking fast.

// MARK: - Sheet

/// Review (isNew, right after a capture) or edit an item. It is presented as
/// a sheet, so it brings its own NavigationStack.
struct ItemEditView: View {
    var item: VaultItem
    var isNew: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var capture: CaptureModel

    @State private var form: ItemForm
    /// The form as it opened, to tell whether anything changed.
    @State private var initial: ItemForm
    /// The values as read from the document: at capture, then from each
    /// picked line. A field is captioned 'From document' while it matches.
    @State private var read: ItemForm
    @State private var readFields: Set<FillField>
    @State private var question: EditQuestion? = nil
    @State private var notice: EditNotice? = nil

    /// The recognised text, one entry per non-blank line.
    private let recognisedLines: [String]

    /// More lines than this are left out of 'Recognised text'.
    private static let maxLines = 1000

    private enum EditQuestion {
        case discard, close
    }

    private struct EditNotice {
        var title: String
        var message: String
    }

    init(item: VaultItem, isNew: Bool) {
        self.item = item
        self.isNew = isNew
        let start = RecordService.form(for: item)
        _form = State(initialValue: start)
        _initial = State(initialValue: start)
        _read = State(initialValue: start)
        _readFields = State(initialValue: isNew ? ItemEditView.documentFields(start) : [])
        self.recognisedLines = ItemEditView.lines(of: item.ocrText)
    }

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle(isNew ? "Check details" : "Edit item")
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .toolbar { toolbarItems }
                .interactiveDismissDisabled(hasChanges)
                .onChange(of: form.hasIssue) { _, _ in
                    followFaultSwitch()
                }
                .confirmationDialog(questionTitle, isPresented: questionShown, titleVisibility: .visible,
                                    presenting: question) { asked in
                    switch asked {
                    case .discard:
                        Button("Discard item", role: .destructive) { discard() }
                    case .close:
                        Button(closeLabel, role: .destructive) { dismiss() }
                        if !EditProblems.blocksSave(form) {
                            Button("Save changes") { save() }
                        }
                    }
                } message: { asked in
                    Text(questionMessage(asked))
                }
                .alert(notice?.title ?? "", isPresented: noticeShown, presenting: notice) { _ in
                    Button("OK", role: .cancel) {}
                } message: { shown in
                    Text(shown.message)
                }
        }
    }

    private var formContent: some View {
        let today = RVCalendar.today()
        let planned: [PlannedDeadline] = RecordService.preview(form, today: today)
        let status: ContractStatus? = RecordService.contractStatus(form, today: today)
        let presets: [ContractPreset] = RecordService.rules.presets
        let shown: Set<FillField> = fromDocument
        return Form {
            if let original = duplicate {
                Section {
                    DuplicateBanner(original: original, onDiscard: { question = EditQuestion.discard })
                }
            }
            PagesSection(item: item)
            WhatSection(form: $form, fromDocument: shown)
            PurchaseSection(form: $form, fromDocument: shown)
            if form.kind == ItemKind.contract {
                ContractSection(form: $form, status: status, presets: presets)
            }
            DatesSection(form: $form, planned: planned)
            NotesSection(form: $form)
            if !recognisedLines.isEmpty {
                RecognisedTextSection(lines: recognisedLines, onPick: { field, line in pick(field, line) },
                                      isContract: form.kind == ItemKind.contract)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isNew ? "Close" : "Cancel") { close() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
                .disabled(EditProblems.blocksSave(form))
        }
        if isNew {
            ToolbarItem(placement: .bottomBar) {
                Button("Discard", role: .destructive) { question = EditQuestion.discard }
                    .tint(Color.red)
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { ItemEditView.hideKeyboard() }
        }
    }

    // MARK: State

    private var hasChanges: Bool { form != initial }

    /// The earlier item this capture looks like a copy of (review only).
    private var duplicate: VaultItem? {
        guard isNew, let current = capture.reviewItem, current.id == item.id,
              let original = capture.duplicateOf, original.id != item.id else { return nil }
        return original
    }

    /// Fields that still hold the value read from the document.
    private var fromDocument: Set<FillField> {
        var out = Set<FillField>()
        for field in readFields where ItemEditView.sameValue(field, form, read) {
            out.insert(field)
        }
        return out
    }

    private var questionShown: Binding<Bool> {
        Binding<Bool>(
            get: { question != nil },
            set: { shown in if !shown { question = nil } }
        )
    }

    private var noticeShown: Binding<Bool> {
        Binding<Bool>(
            get: { notice != nil },
            set: { shown in if !shown { notice = nil } }
        )
    }

    private var questionTitle: String {
        guard let asked = question else { return "" }
        switch asked {
        case .discard: return "Discard this item?"
        case .close: return isNew ? "Close without saving your changes?" : "Discard your changes?"
        }
    }

    private var closeLabel: String { isNew ? "Close without saving" : "Discard changes" }

    private func questionMessage(_ asked: EditQuestion) -> String {
        switch asked {
        case .discard:
            return duplicate == nil
                ? "The item and its pages are deleted from ReceiptVault. This cannot be undone."
                : "This copy and its pages are deleted from ReceiptVault. The earlier item stays as it is."
        case .close:
            return isNew
                ? "The item stays in your vault as it was read. The changes you made here are not kept."
                : "The changes you made here are not kept."
        }
    }

    // MARK: Actions

    /// RecordService.apply, then the reminder permission (the first time
    /// something reminds) and a replan, then the sheet closes.
    private func save() {
        do {
            try RecordService.apply(form, to: item, context: context)
            try applyRejectSwitch()
        } catch {
            context.rollback()
            notice = EditNotice(title: "Could not save",
                                message: "Your changes are still here. \(error.localizedDescription)")
            return
        }
        let reminds = item.deadlines.contains { row in row.remindersOn && !row.isDone }
        let modelContext = context
        Task { @MainActor in
            if reminds {
                _ = await NotificationScheduler.requestIfNeeded()
            }
            await NotificationScheduler.replan(context: modelContext)
        }
        dismiss()
    }

    /// Close or Cancel: asks first when something was changed.
    private func close() {
        if hasChanges {
            question = EditQuestion.close
        } else {
            dismiss()
        }
    }

    /// Deletes a new item through the capture model, which closes the review
    /// sheet before the delete.
    private func discard() {
        let presentedByCapture = capture.reviewItem?.id == item.id
        capture.discard(item, context: context)
        if !presentedByCapture { dismiss() }
    }

    /// 'Pick from document': Core reads the line for the field, then the form
    /// takes the value and drops that field's 'Please check'.
    private func pick(_ field: FillField, _ line: String) {
        // A tapped line is a deliberate choice, so OCR slips in amounts are repaired.
        guard let value = ReceiptExtractor.fill(field, fromLine: line, fromOCR: true) else {
            notice = EditNotice(title: "Nothing to use", message: ItemEditView.nothingFound(field))
            return
        }
        form.apply(value, to: field)
        if field != FillField.notes {
            read.apply(value, to: field)
            readFields.insert(field)
        }
    }

    /// The right-to-reject reminder follows 'Something's wrong with it', as
    /// RecordService.apply does; back where it started, the switch shows its
    /// saved value again.
    private func followFaultSwitch() {
        let key = DeadlineKind.rightToReject.rawValue
        if form.hasIssue == initial.hasIssue {
            form.reminders[key] = initial.reminders[key]
        } else {
            form.reminders.removeValue(forKey: key)
        }
    }

    /// RecordService.apply lets a changed fault switch decide the
    /// right-to-reject reminder whenever that reminder's switch shows its saved
    /// value, so a switch set by hand after changing the fault switch is
    /// applied here.
    private func applyRejectSwitch() throws {
        let key = DeadlineKind.rightToReject.rawValue
        guard form.hasIssue != initial.hasIssue, let on = form.reminders[key] else { return }
        var changed = false
        for row in item.deadlines where row.kind == DeadlineKind.rightToReject && row.remindersOn != on {
            row.remindersOn = on
            changed = true
        }
        if changed { try context.save() }
    }

    // MARK: Helpers

    /// The fields a new item holds as read from the document at 0.75 or more:
    /// filled, and not marked 'Please check'.
    private static func documentFields(_ f: ItemForm) -> Set<FillField> {
        var out = Set<FillField>()
        if !f.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.insert(FillField.merchant) }
        out.insert(FillField.date)
        if f.hasDeliveryDate { out.insert(FillField.deliveryDate) }
        if !f.totalText.isEmpty { out.insert(FillField.total) }
        if !f.vatText.isEmpty { out.insert(FillField.vat) }
        return out.subtracting(f.checks)
    }

    private static func sameValue(_ field: FillField, _ a: ItemForm, _ b: ItemForm) -> Bool {
        switch field {
        case .title: return a.title == b.title
        case .merchant: return a.merchant == b.merchant
        case .total: return a.totalText == b.totalText
        case .vat: return a.vatText == b.vatText
        case .date: return a.purchaseDate == b.purchaseDate
        case .deliveryDate: return a.hasDeliveryDate && b.hasDeliveryDate && a.deliveryDate == b.deliveryDate
        case .notes: return false
        }
    }

    /// Non-blank lines of the stored text, trimmed, at most maxLines.
    private static func lines(of text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            out.append(line)
            if out.count >= ItemEditView.maxLines { break }
        }
        return out
    }

    private static func nothingFound(_ field: FillField) -> String {
        switch field {
        case .total, .vat:
            return "No amount was found in that line. Amounts need two decimals, such as 12.50."
        case .date, .deliveryDate:
            return "No date was found in that line."
        case .title, .merchant, .notes:
            return "That line has no text to use."
        }
    }

    private static func hideKeyboard() {
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Duplicate and pages

/// 'Looks like a copy of X saved on <date>', with 'Discard this copy'.
struct DuplicateBanner: View {
    var original: VaultItem
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message)
                    .font(.subheadline)
            } icon: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(Color.orange)
            }
            Button(role: .destructive, action: onDiscard) {
                Label("Discard this copy", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var message: String {
        let title = original.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? original.kind.label : title
        let saved = Formatters.day(RVCalendar.today(now: original.createdAt))
        return "Looks like a copy of “\(name)” saved on \(saved)."
    }
}

/// Thumbnails of the stored pages, in the order they were added.
struct PagesSection: View {
    var item: VaultItem

    var body: some View {
        let files: [StoredFile] = item.sortedFiles
        if !files.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files) { file in
                            ThumbnailView(file: file, size: 72)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(PagesSection.countText(files)))
            } header: {
                Text(PagesSection.countText(files))
            } footer: {
                Text("The originals are kept exactly as saved. Nothing here changes them.")
            }
        }
    }

    /// '1 page', '3 pages'.
    private static func countText(_ files: [StoredFile]) -> String {
        let pages = files.reduce(0) { sum, file in sum + max(file.pageCount, 1) }
        return pages == 1 ? "1 page" : "\(pages) pages"
    }
}

// MARK: - What and purchase

/// Kind, title (with a menu of the product lines found), merchant and category.
struct WhatSection: View {
    @Binding var form: ItemForm
    /// Fields that still hold the value read from the document.
    var fromDocument: Set<FillField> = []

    var body: some View {
        Section {
            Picker("Kind", selection: $form.kind) {
                ForEach(ItemKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            EditTextRow(placeholder: "Title", text: $form.title, field: FillField.title,
                        checks: $form.checks, fromDocument: fromDocument.contains(FillField.title))
            if !productNames.isEmpty {
                Menu {
                    ForEach(productNames, id: \.self) { name in
                        Button(name) { form.title = name }
                    }
                } label: {
                    Label("Use a product as the title", systemImage: "list.bullet")
                }
            }
            EditTextRow(placeholder: "Merchant or provider", text: $form.merchant, field: FillField.merchant,
                        checks: $form.checks, fromDocument: fromDocument.contains(FillField.merchant))
            if form.kind != ItemKind.contract {
                Picker("Category", selection: $form.category) {
                    ForEach(ProductCategory.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
            }
        } header: {
            Text("What it is")
        } footer: {
            if form.kind != ItemKind.contract && !form.category.tracksGoodsDates {
                Text("Food, services and expense-only items get no return or warranty dates unless you set them under 'Dates we will track'.")
            }
        }
    }

    /// The product lines' names, without blanks or repeats.
    private var productNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in form.lines {
            let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }
}

/// Dates, amounts, VAT, channel, country, used goods, tax tag and
/// 'Something's wrong with it'.
struct PurchaseSection: View {
    @Binding var form: ItemForm
    /// Fields that still hold the value read from the document.
    var fromDocument: Set<FillField> = []

    var body: some View {
        Section {
            EditDateRow(title: dateTitle, day: $form.purchaseDate, field: FillField.date,
                        checks: $form.checks, fromDocument: fromDocument.contains(FillField.date))
            if !isContract {
                Toggle("Delivered on a later day", isOn: $form.hasDeliveryDate)
                    .onChange(of: form.hasDeliveryDate) { _, on in
                        if on && form.deliveryDate < form.purchaseDate {
                            form.deliveryDate = form.purchaseDate
                        }
                    }
                if form.hasDeliveryDate {
                    EditDateRow(title: "Delivery date", day: $form.deliveryDate, field: FillField.deliveryDate,
                                checks: $form.checks, fromDocument: fromDocument.contains(FillField.deliveryDate))
                }
            }
            EditAmountRow(title: "Total", text: $form.totalText, field: FillField.total, checks: $form.checks,
                          fromDocument: fromDocument.contains(FillField.total),
                          problem: EditProblems.amount(form.totalText),
                          currency: $form.currency, currencies: currencies)
            EditAmountRow(title: "VAT", text: $form.vatText, field: FillField.vat, checks: $form.checks,
                          fromDocument: fromDocument.contains(FillField.vat),
                          problem: vatProblem)
            EditRateRow(text: $form.vatRateText, problem: EditProblems.rate(form.vatRateText))
        } header: {
            Text(isContract ? "Date and amount" : "Purchase")
        } footer: {
            if !isContract {
                Text("Legal periods run from the delivery date when it is set, otherwise from the purchase date.")
            }
        }
        Section {
            Picker("Country", selection: $form.jurisdiction) {
                ForEach(Jurisdiction.allCases) { place in
                    Text(place.label).tag(place)
                }
            }
            if !isContract {
                Picker("Bought", selection: $form.channel) {
                    ForEach(PurchaseChannel.allCases) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                Toggle("Used or second-hand", isOn: $form.isUsed)
            }
            Picker("Tax claim", selection: $form.taxTag) {
                ForEach(TaxTag.allCases) { tag in
                    Text(tag.label).tag(tag)
                }
            }
            if !isContract {
                Toggle("Something's wrong with it", isOn: $form.hasIssue)
            }
        } header: {
            Text("Rights and tax")
        } footer: {
            if let note = faultNote {
                Text(note)
            }
        }
    }

    private var isContract: Bool { form.kind == ItemKind.contract }

    private var dateTitle: String { isContract ? "Date" : "Purchase date" }

    /// The supported currencies, plus the item's own when it is another one.
    private var currencies: [String] {
        var list = Money.supportedCurrencies
        let code = form.currency
        if !code.isEmpty && !list.contains(code) { list.append(code) }
        return list
    }

    private var vatProblem: String? {
        EditProblems.amount(form.vatText) ?? EditProblems.vatAboveTotal(form)
    }

    /// What to do about a fault where the item was bought (the first legal
    /// note when a fault is noted).
    private var faultNote: String? {
        guard form.hasIssue, !isContract else { return nil }
        let notes = LegalNotes.notes(for: form.jurisdiction, channel: form.channel, kind: form.kind,
                                     hasIssue: true, isUsed: form.isUsed)
        return notes.first?.text
    }
}

// MARK: - Dates

/// 'Dates we will track': the live DeadlinePlanner preview with certainty,
/// basis and a reminder switch per date, steppers for the shop return window
/// and the warranty, then the user's own dates.
struct DatesSection: View {
    @Binding var form: ItemForm
    var planned: [PlannedDeadline]

    var body: some View {
        let today = RVCalendar.today()
        Section {
            if planned.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
            ForEach(planned, id: \.kind) { p in
                EditPlannedRow(planned: p, today: today, remindersOn: reminderBinding(p))
            }
            if form.kind != ItemKind.contract {
                EditRuleStepper(title: "Shop return window", unit: "days",
                                value: $form.returnDays, printed: $form.returnDaysIsPrinted,
                                fallback: defaultReturnDays, range: 0...RuleField.returnDaysStore.maxValue,
                                noDefault: "No default here. Set one if the shop takes returns.")
                EditRuleStepper(title: "Manufacturer warranty", unit: "months",
                                value: $form.warrantyMonths, printed: $form.warrantyIsPrinted,
                                fallback: defaultWarrantyMonths, range: 0...RuleField.manufacturerWarrantyMonths.maxValue,
                                noDefault: "No default for this category. Set it if a warranty came with it.")
            }
        } header: {
            Text("Dates we will track")
        } footer: {
            NotLegalAdviceFooter()
        }
        Section {
            ForEach(form.customDates) { entry in
                EditCustomDateRow(entry: customBinding(entry.id), onRemove: { removeCustom(entry.id) })
            }
            .onDelete { offsets in
                form.customDates.remove(atOffsets: offsets)
            }
            Button {
                addCustom(today)
            } label: {
                Label("Add a date", systemImage: "plus.circle")
            }
        } header: {
            Text("Your own dates")
        } footer: {
            Text("Anything else worth a reminder, such as a service or a price check before renewal.")
        }
    }

    private var rules: JurisdictionRules { RecordService.rules.rules(for: form.jurisdiction) }

    /// The shop's default, as the planner uses it: goods bought in store.
    private var defaultReturnDays: Int? {
        (form.category.tracksGoodsDates && form.channel == PurchaseChannel.store) ? rules.returnDaysStore : nil
    }

    /// The typical warranty, as the planner uses it: electronics and appliances.
    private var defaultWarrantyMonths: Int? {
        (form.category.tracksGoodsDates && form.category.usesManufacturerDefault) ? rules.manufacturerWarrantyMonths : nil
    }

    private var emptyText: String {
        if form.kind == ItemKind.contract && !form.hasTermEnd {
            return "Set when the term ends, under Contract, to plan the notice deadline."
        }
        if form.kind != ItemKind.contract && !form.category.tracksGoodsDates {
            return "No legal dates apply to this category. You can set a return window or a warranty below."
        }
        return "No dates apply with these details."
    }

    /// The switch as RecordService.apply will save it: the form's value, else
    /// the planner's default for a date the item does not have yet.
    private func reminderBinding(_ p: PlannedDeadline) -> Binding<Bool> {
        let key = p.kind.rawValue
        let fallback = p.remindByDefault
        return Binding<Bool>(
            get: { form.reminders[key] ?? fallback },
            set: { newValue in form.reminders[key] = newValue }
        )
    }

    /// A binding by id, so removing a date never leaves a row on a stale index.
    private func customBinding(_ id: UUID) -> Binding<CustomDate> {
        Binding<CustomDate>(
            get: { form.customDates.first(where: { $0.id == id }) ?? CustomDate(id: id, date: RVCalendar.today()) },
            set: { newValue in
                guard let index = form.customDates.firstIndex(where: { $0.id == id }) else { return }
                form.customDates[index] = newValue
            }
        )
    }

    private func addCustom(_ today: DayDate) {
        let offsets = RecordService.rules.offsets(for: DeadlineKind.custom)
        form.customDates.append(CustomDate(date: RVCalendar.adding(months: 1, to: today), offsets: offsets))
    }

    private func removeCustom(_ id: UUID) {
        form.customDates.removeAll(where: { $0.id == id })
    }
}

// MARK: - Contract

/// Preset, term end, renewal, notice, cancelled and notice sent, then
/// 'Notice must arrive by' and 'Send by' with the registered-post tip. A
/// preset fills the renewal, notice and automatic renewal; one with a fixed
/// end date sets the term end to the next such day.
struct ContractSection: View {
    @Binding var form: ItemForm
    var status: ContractStatus?
    var presets: [ContractPreset]

    var body: some View {
        Section {
            Picker("Type of contract", selection: presetSelection) {
                Text("Not set").tag("")
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
                if isUnknownPreset {
                    Text(form.presetID).tag(form.presetID)
                }
            }
            if let preset = selectedPreset, !preset.note.isEmpty {
                EditPresetNote(preset: preset)
            }
            Toggle("I know when the term ends", isOn: $form.hasTermEnd)
            if form.hasTermEnd {
                DayDatePicker(title: "Term ends on", selection: $form.termEnd)
            }
            Toggle("Renews automatically", isOn: $form.autoRenews)
            if form.autoRenews {
                Stepper(value: $form.renewalMonths, in: 1...ContractSection.maxRenewalMonths) {
                    Text(renewalText)
                }
            }
            EditNoticeRows(notice: $form.notice)
            Toggle("Cancelled", isOn: $form.cancelled)
            Toggle("Notice sent", isOn: $form.noticeSent)
        } header: {
            Text("Contract")
        } footer: {
            Text("Enter the end of the current term or of any earlier one; later terms are counted from it.")
        }
        Section {
            EditContractStatusRows(status: status, notice: form.notice, noticeSent: form.noticeSent)
        } header: {
            Text("Notice")
        } footer: {
            Text(tipText)
        }
    }

    private static let maxRenewalMonths = 120

    private var selectedPreset: ContractPreset? {
        presets.first(where: { $0.id == form.presetID })
    }

    /// A preset id no longer in the rules still needs a row in the picker.
    private var isUnknownPreset: Bool {
        !form.presetID.isEmpty && selectedPreset == nil
    }

    private var presetSelection: Binding<String> {
        Binding<String>(
            get: { form.presetID },
            set: { id in choosePreset(id) }
        )
    }

    private func choosePreset(_ id: String) {
        var f = form
        f.presetID = id
        if let preset = presets.first(where: { $0.id == id }) {
            f.renewalMonths = preset.renewalMonths
            f.notice = preset.notice
            f.autoRenews = preset.autoRenews
            if preset.fixedEndMonth > 0 && preset.fixedEndDay > 0 {
                f.termEnd = ContractMath.nextFixedEnd(month: preset.fixedEndMonth, day: preset.fixedEndDay,
                                                      after: RVCalendar.today())
                f.hasTermEnd = true
            }
        }
        form = f
    }

    private var renewalText: String {
        form.renewalMonths == 1 ? "Renews every month" : "Renews every \(form.renewalMonths) months"
    }

    private var tipText: String {
        let days = RecordService.rules.postalBufferDays
        let unit = days == 1 ? "working day" : "working days"
        return "'Send by' leaves \(days) \(unit) for the post, counting Monday to Friday; public holidays are not taken into account. Send notice by registered post (Einschreiben / recommandé) and keep the receipt: it is the day notice arrives that counts."
    }
}

// MARK: - Notes and recognised text

struct NotesSection: View {
    @Binding var form: ItemForm

    var body: some View {
        Section {
            TextField("Serial number, where it is kept, who to call…", text: $form.notes, axis: .vertical)
                .lineLimit(3...10)
        } header: {
            Text("Notes")
        }
    }
}

/// The recognised text. Tapping a line asks which field it fills; the parent
/// reads it with ReceiptExtractor.fill and applies it to the form.
struct RecognisedTextSection: View {
    var lines: [String]
    var onPick: (FillField, String) -> Void
    /// A contract has no delivery date, and its purchase date is 'Date'.
    var isContract: Bool = false
    @State private var showAll = false

    /// Lines shown before 'Show all'.
    private static let shortCount = 30

    var body: some View {
        Section {
            ForEach(Array(visible.enumerated()), id: \.offset) { entry in
                EditRecognisedLineRow(text: entry.element, isContract: isContract, onPick: onPick)
            }
            if lines.count > RecognisedTextSection.shortCount {
                Button(showAll ? "Show fewer lines" : "Show all \(lines.count) lines") {
                    showAll.toggle()
                }
            }
        } header: {
            Text("Recognised text")
        } footer: {
            Text("Tap a line to use it for a field, such as the total or the date.")
        }
    }

    private var visible: [String] {
        showAll ? lines : Array(lines.prefix(RecognisedTextSection.shortCount))
    }
}

// MARK: - Rows

/// 'Please check' while a field is still unsure; 'From document' while it
/// holds the value read with confidence; nothing once it has been changed.
private struct EditFieldCaption: View {
    var needsCheck: Bool
    var fromDocument: Bool

    var body: some View {
        if needsCheck {
            ConfidenceCaption(needsCheck: true)
        } else if fromDocument {
            ConfidenceCaption(needsCheck: false)
        }
    }
}

/// A text field with its caption. Typing in it drops its 'Please check'.
private struct EditTextRow: View {
    var placeholder: String
    @Binding var text: String
    var field: FillField
    @Binding var checks: Set<FillField>
    var fromDocument: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .onChange(of: text) { _, _ in
                    if checks.contains(field) { checks.remove(field) }
                }
            EditFieldCaption(needsCheck: checks.contains(field), fromDocument: fromDocument)
        }
    }
}

/// A day picker with its caption. Changing it drops its 'Please check'.
private struct EditDateRow: View {
    var title: String
    @Binding var day: DayDate
    var field: FillField
    @Binding var checks: Set<FillField>
    var fromDocument: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DayDatePicker(title: title, selection: $day)
                .onChange(of: day) { _, _ in
                    if checks.contains(field) { checks.remove(field) }
                }
            EditFieldCaption(needsCheck: checks.contains(field), fromDocument: fromDocument)
        }
    }
}

/// An amount typed as text ('249.00' or '249,00'), optionally with the
/// currency picker, its caption and a note when it cannot be read.
private struct EditAmountRow: View {
    var title: String
    @Binding var text: String
    var field: FillField
    @Binding var checks: Set<FillField>
    var fromDocument: Bool
    var problem: String?
    var currency: Binding<String>? = nil
    var currencies: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title)
                TextField("0.00", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: text) { _, _ in
                        if checks.contains(field) { checks.remove(field) }
                    }
                if let code = currency {
                    Picker("Currency", selection: code) {
                        ForEach(currencies, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: code.wrappedValue) { _, _ in
                        // The currency is part of the amount: choosing it confirms the row.
                        if checks.contains(field) { checks.remove(field) }
                    }
                }
            }
            EditFieldCaption(needsCheck: checks.contains(field), fromDocument: fromDocument)
            if let message = problem {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }
}

/// The VAT rate in percent ('20', '8.1').
private struct EditRateRow: View {
    @Binding var text: String
    var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("VAT rate")
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text("%")
                    .foregroundStyle(.secondary)
            }
            if let message = problem {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }
}

/// A rule input (return days, warranty months) over an optional value: nil
/// uses the default from the rules, 0 means none. Stepping makes it yours.
private struct EditRuleStepper: View {
    var title: String
    /// Plural: 'days' or 'months'.
    var unit: String
    @Binding var value: Int?
    @Binding var printed: Bool
    var fallback: Int?
    var range: ClosedRange<Int>
    var noDefault: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: stepped, in: range) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(amountText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                source
                Spacer(minLength: 8)
                if value != nil {
                    Button(fallback == nil ? "Clear" : "Use default") {
                        value = nil
                        printed = false
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var source: some View {
        if value != nil && printed {
            ConfidenceCaption(needsCheck: false)
        } else if value != nil {
            Text("Set by you")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if fallback != nil {
            Text("Default from Settings › Rules")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(noDefault)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stepped: Binding<Int> {
        Binding<Int>(
            get: { value ?? fallback ?? 0 },
            set: { newValue in
                value = newValue
                printed = false
            }
        )
    }

    /// '28 days', '1 month', 'none'.
    private var amountText: String {
        let n = value ?? fallback ?? 0
        if n <= 0 { return "none" }
        return n == 1 ? "1 \(String(unit.dropLast()))" : "\(n) \(unit)"
    }
}

/// One planned date: kind, 'Return by 9 Apr 2026 · in 5 days', certainty,
/// basis and its reminder switch.
private struct EditPlannedRow: View {
    var planned: PlannedDeadline
    var today: DayDate
    @Binding var remindersOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: planned.kind.symbol)
                    .foregroundStyle(isPast ? Color.secondary : Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(planned.kind.label)
                    Text(dateLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                CertaintyBadge(certainty: planned.certainty)
            }
            if !planned.basis.isEmpty {
                Text(planned.basis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Remind me", isOn: $remindersOn)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private var isPast: Bool { planned.date < today }

    private var dateLine: String {
        let when = EvidenceSummary.status(of: planned.date, today: today)
        return "\(planned.kind.dueWording) \(Formatters.day(planned.date)) · \(when)"
    }
}

/// A date the user adds: what is due, the day and its reminder.
private struct EditCustomDateRow: View {
    @Binding var entry: CustomDate
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                TextField("What is due, e.g. Boiler service", text: $entry.label)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove this date"))
            }
            DayDatePicker(title: "Date", selection: $entry.date)
            Toggle("Remind me", isOn: $entry.remindersOn)
            if entry.remindersOn && !leadText.isEmpty {
                Text(leadText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 'Reminds you 7 days before', 'Reminds you 30, 14 and 3 days before'.
    private var leadText: String {
        let days = Array(Set(entry.offsets.filter { $0 > 0 })).sorted(by: >)
        var parts: [String] = []
        if !days.isEmpty {
            let numbers = days.map { String($0) }
            let list = numbers.count == 1
                ? numbers[0]
                : numbers.dropLast().joined(separator: ", ") + " and " + numbers[numbers.count - 1]
            let unit = days == [1] ? "day" : "days"
            parts.append("\(list) \(unit) before")
        }
        if entry.offsets.contains(0) { parts.append("on the day") }
        return parts.isEmpty ? "" : "Reminds you " + parts.joined(separator: " and ")
    }
}

/// A preset's note, with 'Assumed' when it is an assumption.
private struct EditPresetNote: View {
    var preset: ContractPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if preset.isAssumption {
                CertaintyBadge(certainty: Certainty.assumption)
            }
            Text(preset.note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The notice period: a stepper for the value and days / weeks / months.
private struct EditNoticeRows: View {
    @Binding var notice: NoticePeriod

    var body: some View {
        Stepper(value: $notice.value, in: 0...EditNoticeRows.limit(notice.unit)) {
            Text(stepperText)
        }
        Picker("Counted in", selection: unitSelection) {
            ForEach(NoticePeriod.Unit.allCases, id: \.self) { unit in
                Text(EditNoticeRows.name(unit)).tag(unit)
            }
        }
        .pickerStyle(.segmented)
    }

    private var stepperText: String {
        notice.value <= 0 ? "No notice period" : "Notice: \(notice.label)"
    }

    /// A new unit keeps the value within that unit's range.
    private var unitSelection: Binding<NoticePeriod.Unit> {
        Binding<NoticePeriod.Unit>(
            get: { notice.unit },
            set: { unit in
                var n = notice
                n.unit = unit
                n.value = min(n.value, EditNoticeRows.limit(unit))
                notice = n
            }
        )
    }

    private static func limit(_ unit: NoticePeriod.Unit) -> Int {
        switch unit {
        case .days: return 365
        case .weeks: return 104
        case .months: return 36
        }
    }

    private static func name(_ unit: NoticePeriod.Unit) -> String {
        switch unit {
        case .days: return "Days"
        case .weeks: return "Weeks"
        case .months: return "Months"
        }
    }
}

/// 'Notice must arrive by', 'Send by' and the current term end, or the end
/// or renewal day when no notice applies.
private struct EditContractStatusRows: View {
    var status: ContractStatus?
    var notice: NoticePeriod
    var noticeSent: Bool

    var body: some View {
        if let s = status {
            if s.endsWithoutRenewal {
                LabeledContent("Contract ends", value: Formatters.day(s.termEnd))
            } else if notice.value <= 0 {
                LabeledContent("Renews on", value: Formatters.day(s.termEnd))
            } else {
                LabeledContent("Notice must arrive by", value: Formatters.day(s.noticeBy))
                LabeledContent("Send by", value: Formatters.day(s.sendBy))
                LabeledContent("Current term ends", value: Formatters.day(s.termEnd))
            }
            if s.skippedTerms > 0 {
                Label("Earlier notice dates have passed. These dates are for the next term you can still end.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
            }
            if noticeSent {
                Label("Notice sent. Its deadline is marked as done when you save.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Set when the term ends to see when notice must arrive.")
                .foregroundStyle(.secondary)
        }
    }
}

/// One recognised line. Tapping it asks which field it should fill.
private struct EditRecognisedLineRow: View {
    var text: String
    var isContract: Bool
    var onPick: (FillField, String) -> Void
    @State private var asking = false

    var body: some View {
        Button {
            asking = true
        } label: {
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Use this line", isPresented: $asking, titleVisibility: .visible) {
            ForEach(fields, id: \.self) { field in
                Button(actionTitle(field)) { onPick(field, text) }
            }
        } message: {
            Text(text)
        }
    }

    /// Every field, except the delivery date a contract does not show.
    private var fields: [FillField] {
        let all: [FillField] = FillField.allCases
        return isContract ? all.filter { $0 != FillField.deliveryDate } : all
    }

    private func actionTitle(_ field: FillField) -> String {
        switch field {
        case .title: return "Use as title"
        case .merchant: return "Use as merchant"
        case .total: return "Use as total"
        case .vat: return "Use as VAT"
        case .date: return isContract ? "Use as date" : "Use as purchase date"
        case .deliveryDate: return "Use as delivery date"
        case .notes: return "Add to notes"
        }
    }
}

// MARK: - Checks

/// Inline checks on the typed amounts. Text that cannot be read blocks Save,
/// because it would otherwise be stored as blank.
private enum EditProblems {
    static func amount(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, FormParsing.minor(t) == nil else { return nil }
        return "This amount cannot be read. Type it as 249.00 or 249,00."
    }

    static func rate(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, FormParsing.permille(t) == nil else { return nil }
        return "Type a rate between 0 and 100, such as 20 or 8.1."
    }

    /// A warning only: it does not block Save.
    static func vatAboveTotal(_ form: ItemForm) -> String? {
        guard let vat = FormParsing.minor(form.vatText), let total = FormParsing.minor(form.totalText),
              total >= 0, vat > total else { return nil }
        return "The VAT is more than the total. Please check both amounts."
    }

    static func blocksSave(_ form: ItemForm) -> Bool {
        EditProblems.amount(form.totalText) != nil
            || EditProblems.amount(form.vatText) != nil
            || EditProblems.rate(form.vatRateText) != nil
    }
}
