import SwiftUI
import SwiftData
import QuickLook
import UIKit

// Everything about one item: the pages, the key-date timeline with its
// reminder and done switches, the legal notes, the details and the original
// files, then the actions for a claim. It is pushed onto a tab's
// NavigationStack. Every change goes through RecordService and is followed by
// a replan. Each section is its own small struct, which keeps type-checking
// fast, and nothing reads the item once it has been deleted.

// MARK: - Destination

/// The screen pushed for an item id (NavigationLink(value: item.id)). Upcoming
/// and Library register it once per NavigationStack with
/// `.navigationDestination(for: UUID.self)`. Pushing by value means the
/// detail does not depend on its row staying in a filtered list: turning
/// 'Remind me' off, or saving Edit (which clears 'Needs a look'), no longer
/// pops the screen out from under the user.
struct ItemDestinationView: View {
    var id: UUID

    @Environment(\.modelContext) private var context

    var body: some View {
        if let item = RecordService.item(id: id, context: context) {
            ItemDetailView(item: item)
        } else {
            ContentUnavailableView("This item was deleted", systemImage: "trash")
        }
    }
}

// MARK: - Detail

/// One item, pushed from Upcoming, Library or 'Needs a look'.
struct ItemDetailView: View {
    var item: VaultItem

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var capture: CaptureModel

    @State private var sheet: DetailSheet? = nil
    /// The original shown in QuickLook.
    @State private var previewURL: URL? = nil
    @State private var confirmDelete = false
    @State private var preparing = false
    /// 'Evidence PDF prepared: 2.4 MB.', after the last one.
    @State private var evidenceNote: String? = nil
    @State private var problem: DetailProblem? = nil
    @State private var notificationsDenied = false
    /// Set just before the item is deleted, so nothing reads it afterwards.
    @State private var isGone = false
    /// False once the screen has gone (popped, another tab, the app locked),
    /// so an evidence PDF finished after that is deleted instead of shown.
    @State private var onScreen = false

    /// Everything this screen presents as a sheet, so only one is ever up.
    private enum DetailSheet: Identifiable {
        case edit
        /// An evidence PDF in tmp/Export, deleted once shared.
        case evidence(ExportFile)
        /// The stored originals, shared as they are and never deleted.
        case originals([URL])

        var id: String {
            switch self {
            case .edit: return "edit"
            case .evidence(let file): return "evidence-" + file.id.uuidString
            case .originals: return "originals"
            }
        }
    }

    private struct DetailProblem {
        var title: String
        var message: String
    }

    init(item: VaultItem) {
        self.item = item
    }

    var body: some View {
        if isGone || item.isDeleted || item.modelContext == nil {
            ContentUnavailableView("This item was deleted", systemImage: "trash")
        } else {
            detail
        }
    }

    // The modifiers are split over three members only to keep each
    // expression small for the type checker; together they are one chain.
    private var detail: some View {
        let files: [StoredFile] = item.sortedFiles
        let urls: [URL] = ItemDetailView.previewURLs(files)
        return presented(files: files, urls: urls)
            .task { await refreshPermission() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await refreshPermission() }
                }
            }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
    }

    /// QuickLook, the sheets, the delete question and the alerts.
    private func presented(files: [StoredFile], urls: [URL]) -> some View {
        let alertTitle: String = problem?.title ?? ""
        return sections(files: files, hasOriginals: !urls.isEmpty)
            .quickLookPreview($previewURL, in: urls)
            .sheet(item: $sheet) { shown in
                sheetContent(shown)
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete item", role: .destructive) { deleteItem() }
            } message: {
                Text("The item, its original files and its reminders are deleted from ReceiptVault. This cannot be undone.")
            }
            .alert(alertTitle, isPresented: problemShown, presenting: problem) { _ in
                Button("OK", role: .cancel) {}
            } message: { shown in
                Text(shown.message)
            }
    }

    /// The list of sections with its title and the Edit button.
    private func sections(files: [StoredFile], hasOriginals: Bool) -> some View {
        let today: DayDate = RVCalendar.today()
        return List {
            ItemDetailHeaderSection(item: item, onCheck: { openEdit() })
            if !files.isEmpty {
                ItemDetailPagesSection(files: files, onOpen: { file in showOriginal(file) })
            }
            if item.kind == ItemKind.contract {
                ItemDetailContractSection(item: item, today: today)
            }
            ItemDetailTimelineSection(item: item, today: today, notificationsDenied: notificationsDenied,
                                      onReminders: { row, on in setReminders(row, on) },
                                      onDone: { row, done in setDone(row, done) })
            ItemDetailLegalSection(item: item)
            ItemDetailFactsSection(item: item)
            ItemDetailFilesSection(files: files, onOpen: { file in showOriginal(file) })
            actionsSection(hasOriginals: hasOriginals)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { openEdit() }
                    .disabled(preparing)
            }
        }
    }

    private func actionsSection(hasOriginals: Bool) -> some View {
        Section {
            // Nothing else is presented while the evidence PDF is prepared:
            // its share sheet would replace an open sheet (and an unsaved
            // Edit form with it) or clash with QuickLook and the pickers.
            AddMenu(addTo: item)
                .disabled(capture.working != nil || preparing)
            Button {
                prepareEvidence()
            } label: {
                ItemDetailBusyLabel(title: preparing ? "Preparing evidence PDF…" : "Prepare evidence PDF",
                                    systemImage: "doc.richtext", busy: preparing)
            }
            .disabled(preparing)
            Button {
                shareOriginals()
            } label: {
                Label("Share originals", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasOriginals || preparing)
            if showsMarkNoticeSent {
                Button {
                    markNoticeSent()
                } label: {
                    Label("Mark notice sent", systemImage: "paperplane")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete item", systemImage: "trash")
            }
            // Not while the evidence PDF is drawn from the originals: the
            // PDF of a deleted item would be left behind in tmp/Export.
            .disabled(preparing)
        } header: {
            Text("Actions")
        } footer: {
            Text(actionsFooter)
        }
    }

    @ViewBuilder
    private func sheetContent(_ shown: DetailSheet) -> some View {
        switch shown {
        case .edit:
            ItemEditView(item: item, isNew: false)
                .environmentObject(capture)
        case .evidence(let file):
            ShareSheet(items: [file.url], onComplete: { file.cleanUp() })
                .presentationDetents([.medium, .large])
        case .originals(let urls):
            ShareSheet(items: urls)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: State

    private var titleText: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? item.kind.label : title
    }

    /// Contracts whose notice has not been recorded yet.
    private var showsMarkNoticeSent: Bool {
        item.kind == ItemKind.contract && item.noticeSentAt == nil && !item.cancelled
    }

    private var actionsFooter: String {
        let text = "The evidence PDF has a cover with the details, key dates and file fingerprints, followed by every original page. It is removed from ReceiptVault once shared. 'Share originals' sends the files exactly as they are stored."
        guard let note = evidenceNote else { return text }
        return note + " " + text
    }

    private var problemShown: Binding<Bool> {
        Binding<Bool>(
            get: { problem != nil },
            set: { shown in if !shown { problem = nil } }
        )
    }

    // MARK: Actions

    /// Edit, from the toolbar or the 'Needs a look' row; not while the
    /// evidence PDF is prepared, whose share sheet would replace it.
    private func openEdit() {
        guard !preparing else { return }
        sheet = DetailSheet.edit
    }

    /// Opens the original in QuickLook, unless it is no longer on the phone.
    /// Not while the evidence PDF is prepared: its share sheet could not be
    /// presented over QuickLook.
    private func showOriginal(_ file: StoredFile) {
        guard !preparing else { return }
        guard FileVault.exists(file.fileName) else {
            problem = DetailProblem(title: "Original not found",
                                    message: "This file is no longer stored on this iPhone, so it cannot be opened.")
            return
        }
        previewURL = file.url
    }

    /// Turning a reminder on asks for permission the first time.
    private func setReminders(_ row: Deadline, _ on: Bool) {
        do {
            try RecordService.setReminders(row, on, context: context)
        } catch {
            failed("Could not save", error)
            return
        }
        let modelContext = context
        Task { @MainActor in
            if on {
                _ = await NotificationScheduler.requestIfNeeded()
            }
            await NotificationScheduler.replan(context: modelContext)
            await refreshPermission()
        }
    }

    private func setDone(_ row: Deadline, _ done: Bool) {
        do {
            try RecordService.setDone(row, done, context: context)
        } catch {
            failed("Could not save", error)
            return
        }
        replan()
    }

    private func markNoticeSent() {
        do {
            try RecordService.markNoticeSent(item, context: context)
        } catch {
            failed("Could not save", error)
            return
        }
        replan()
    }

    /// EvidencePDF.make, then the share sheet; the PDF is deleted once shared,
    /// or at once when the screen has gone meanwhile (nothing would show it).
    private func prepareEvidence() {
        guard !preparing else { return }
        preparing = true
        evidenceNote = nil
        let target = item
        Task { @MainActor in
            do {
                let url = try await EvidencePDF.make(for: target)
                preparing = false
                let export = ExportFile(url: url, deleteAfterShare: true)
                guard onScreen, !isGone else {
                    export.cleanUp()
                    return
                }
                evidenceNote = ItemDetailView.sizeNote(url)
                sheet = DetailSheet.evidence(export)
            } catch {
                preparing = false
                problem = DetailProblem(title: "Could not prepare the PDF", message: error.localizedDescription)
            }
        }
    }

    /// The stored files themselves; they stay in the vault.
    private func shareOriginals() {
        guard !preparing else { return }
        let urls = ItemDetailView.previewURLs(item.sortedFiles)
        guard !urls.isEmpty else {
            problem = DetailProblem(title: "Nothing to share",
                                    message: "The original files of this item are no longer stored on this iPhone.")
            return
        }
        sheet = DetailSheet.originals(urls)
    }

    /// RecordService.delete, a replan, then back to the list.
    private func deleteItem() {
        isGone = true
        previewURL = nil
        do {
            try RecordService.delete(item, context: context)
        } catch {
            context.rollback()
            isGone = false
            problem = DetailProblem(title: "Could not delete",
                                    message: "The item is still here. \(error.localizedDescription)")
            return
        }
        replan()
        dismiss()
    }

    private func replan() {
        let modelContext = context
        Task { @MainActor in
            await NotificationScheduler.replan(context: modelContext)
        }
    }

    private func refreshPermission() async {
        notificationsDenied = await NotificationScheduler.isDenied()
    }

    /// Undoes the unsaved change and says why.
    private func failed(_ title: String, _ error: Error) {
        context.rollback()
        problem = DetailProblem(title: title, message: error.localizedDescription)
    }

    // MARK: Helpers

    /// The originals that are still on the phone, in page order.
    private static func previewURLs(_ files: [StoredFile]) -> [URL] {
        files.filter { FileVault.exists($0.fileName) }.map { $0.url }
    }

    /// 'Evidence PDF prepared: 2.4 MB.'
    private static func sizeNote(_ url: URL) -> String? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "Evidence PDF prepared: \(size)."
    }
}

// MARK: - Header

/// Title, merchant, amount with VAT, the purchase and delivery dates, and a
/// 'Needs a look' row that opens Edit.
private struct ItemDetailHeaderSection: View {
    var item: VaultItem
    var onCheck: () -> Void

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                KindIcon(kind: item.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText)
                        .font(.title3.weight(.semibold))
                    if !merchantText.isEmpty {
                        Text(merchantText)
                            .foregroundStyle(.secondary)
                    }
                    Text(kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if let total = item.totalMinor {
                LabeledContent("Total") {
                    AmountText(minor: total, currency: item.currency)
                }
            }
            if let vat = vatText {
                LabeledContent("VAT", value: vat)
            }
            if item.kind == ItemKind.contract {
                LabeledContent("Date", value: Formatters.day(item.purchaseDay))
            } else {
                LabeledContent("Purchase date", value: Formatters.day(item.purchaseDay))
            }
            if let delivered = item.deliveryDay {
                LabeledContent("Delivery date", value: Formatters.day(delivered))
            }
            if item.needsReview {
                ItemDetailReviewRow(fields: checkLabels, onCheck: onCheck)
            }
        }
    }

    private var titleText: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? item.kind.label : title
    }

    /// The merchant, unless it is blank or the same as the title.
    private var merchantText: String {
        let merchant = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if merchant.caseInsensitiveCompare(titleText) == .orderedSame { return "" }
        return merchant
    }

    /// 'Receipt · Electronics'; just 'Contract' for contracts.
    private var kindText: String {
        if item.kind == ItemKind.contract { return item.kind.label }
        return "\(item.kind.label) · \(item.category.label)"
    }

    /// '£41.50 at 20%', '£41.50' or '20%'; nil when neither is known.
    private var vatText: String? {
        let rate: String? = item.vatRatePermille.map { Money.percent(permille: $0) + "%" }
        guard let vat = item.vatMinor else { return rate }
        let amount = Money.format(vat, currency: item.currency)
        guard let r = rate else { return amount }
        return "\(amount) at \(r)"
    }

    /// The fields still marked 'Please check', in form order.
    private var checkLabels: [String] {
        let checks = item.checks
        return FillField.allCases.filter { checks.contains($0) }.map { $0.label }
    }
}

/// 'Needs a look': some fields were hard to read. Tapping it opens Edit.
private struct ItemDetailReviewRow: View {
    var fields: [String]
    var onCheck: () -> Void

    var body: some View {
        Button(action: onCheck) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs a look")
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
    }

    private var detail: String {
        if fields.isEmpty {
            return "Some details were hard to read. Tap to check them."
        }
        return "Please check: \(fields.joined(separator: ", ")). Tap to check them."
    }
}

// MARK: - Pages

/// The page carousel: one page per stored file (the first page of a PDF).
/// Tapping a page opens the originals in QuickLook.
private struct ItemDetailPagesSection: View {
    var files: [StoredFile]
    var onOpen: (StoredFile) -> Void
    @State private var selection = 0

    private static let height: CGFloat = 340

    init(files: [StoredFile], onOpen: @escaping (StoredFile) -> Void) {
        self.files = files
        self.onOpen = onOpen
    }

    var body: some View {
        let mode: PageTabViewStyle.IndexDisplayMode = files.count > 1 ? .always : .never
        Section {
            TabView(selection: $selection) {
                ForEach(Array(files.enumerated()), id: \.element.id) { entry in
                    ItemDetailPageButton(file: entry.element, number: entry.offset + 1, count: files.count,
                                         onOpen: onOpen)
                        .tag(entry.offset)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: mode))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
            .frame(height: ItemDetailPagesSection.height)
            .listRowInsets(EdgeInsets())
            .onChange(of: files.count) { _, count in
                // A page removed elsewhere must not leave the carousel on a
                // tag that no longer exists (it would show a blank page).
                if selection >= count { selection = max(0, count - 1) }
            }
        } header: {
            Text(countText)
        } footer: {
            Text(footerText)
        }
    }

    /// '1 page', '3 pages'.
    private var countText: String {
        let pages = files.reduce(0) { sum, file in sum + max(file.pageCount, 1) }
        return pages == 1 ? "1 page" : "\(pages) pages"
    }

    private var footerText: String {
        let longPDF = files.contains { file in file.isPDF && file.pageCount > 1 }
        if longPDF {
            return "Tap a page to open the originals. A PDF shows its first page here and opens with all its pages."
        }
        return "Tap a page to open the originals. They are kept exactly as saved."
    }
}

private struct ItemDetailPageButton: View {
    var file: StoredFile
    var number: Int
    var count: Int
    var onOpen: (StoredFile) -> Void

    var body: some View {
        Button {
            onOpen(file)
        } label: {
            ItemDetailPageImage(file: file)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityHint(Text("Opens the original"))
    }

    private var spokenLabel: String {
        count > 1 ? "Page \(number) of \(count)" : "Page"
    }
}

/// One page, decoded off the main thread and scaled down for the screen.
private struct ItemDetailPageImage: View {
    var file: StoredFile
    @State private var image: UIImage? = nil
    @State private var failed = false

    init(file: StoredFile) {
        self.file = file
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let shown = image {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("This page cannot be shown here.")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            if file.isPDF {
                Text(pdfBadge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
            }
        }
        .contentShape(Rectangle())
        .task(id: file.fileName) {
            await load()
        }
    }

    private var pdfBadge: String {
        file.pageCount > 1 ? "PDF · \(file.pageCount) pages" : "PDF"
    }

    private func load() async {
        let name = file.fileName
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            ItemDetailImages.display(name)
        }.value
        image = loaded
        failed = loaded == nil
    }
}

/// Page images for the carousel. Plain functions, so they run off the main thread.
private enum ItemDetailImages {
    /// Longest edge of a page on screen.
    static let maxEdge: CGFloat = 1600

    /// FileVault.image, decoded for display and scaled down when it is larger.
    static func display(_ name: String) -> UIImage? {
        guard let image = FileVault.image(name) else { return nil }
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > 0 else { return nil }
        guard longEdge > ItemDetailImages.maxEdge else {
            return image.preparingForDisplay() ?? image
        }
        let factor = ItemDetailImages.maxEdge / longEdge
        let target = CGSize(width: max(1, (size.width * factor).rounded(.down)),
                            height: max(1, (size.height * factor).rounded(.down)))
        return image.preparingThumbnail(of: target) ?? image
    }
}

// MARK: - Contract

/// 'Notice must arrive by', 'Send by' and the current term, whether notice
/// was sent, and the registered-post tip.
private struct ItemDetailContractSection: View {
    var item: VaultItem
    var today: DayDate

    var body: some View {
        let status: ContractStatus? = ItemDetailContractSection.status(of: item, today: today)
        Section {
            if let name = presetName {
                LabeledContent("Type", value: name)
            }
            if let s = status {
                ItemDetailContractRows(status: s, notice: item.notice, renewalMonths: item.renewalMonths)
            } else {
                Text("Set when the term ends with Edit to see when notice must arrive.")
                    .foregroundStyle(.secondary)
            }
            if item.cancelled {
                Label("Marked as cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let sent = sentText {
                Label(sent, systemImage: "checkmark.circle")
                    .foregroundStyle(Color.green)
            }
        } header: {
            Text("Contract")
        } footer: {
            Text(footerText)
        }
    }

    private var presetName: String? {
        let id = item.contractPresetID
        guard !id.isEmpty else { return nil }
        return RecordService.rules.presets.first(where: { $0.id == id })?.name
    }

    /// 'Notice sent on 12 Mar 2026', on the phone's calendar.
    private var sentText: String? {
        guard let at = item.noticeSentAt else { return nil }
        return "Notice sent on \(Formatters.day(RVCalendar.today(now: at)))"
    }

    private var footerText: String {
        let days = RecordService.rules.postalBufferDays
        let unit = days == 1 ? "working day" : "working days"
        var text = "'Send by' leaves \(days) \(unit) for the post, counting Monday to Friday; public holidays are not taken into account. Send notice by registered post (Einschreiben / recommandé) and keep the receipt: it is the day notice arrives that counts."
        if item.noticeSentAt != nil && !item.cancelled {
            text += " Once the provider confirms, turn on 'Cancelled' with Edit, so the next term does not remind you."
        }
        return text
    }

    /// Nil unless the contract has a term end.
    private static func status(of item: VaultItem, today: DayDate) -> ContractStatus? {
        guard let facts = RecordService.facts(for: item).contract else { return nil }
        return ContractMath.status(facts, today: today, postalBufferDays: RecordService.rules.postalBufferDays)
    }
}

private struct ItemDetailContractRows: View {
    var status: ContractStatus
    var notice: NoticePeriod
    var renewalMonths: Int

    var body: some View {
        if status.endsWithoutRenewal {
            LabeledContent("Contract ends", value: Formatters.day(status.termEnd))
        } else if notice.value <= 0 {
            LabeledContent("Renews on", value: Formatters.day(status.termEnd))
        } else {
            LabeledContent("Notice must arrive by", value: Formatters.day(status.noticeBy))
            LabeledContent("Send by", value: Formatters.day(status.sendBy))
            LabeledContent("Current term ends", value: Formatters.day(status.termEnd))
        }
        LabeledContent("Notice period", value: notice.label)
        if !status.endsWithoutRenewal {
            LabeledContent("Renews", value: renewalText)
        }
        if status.skippedTerms > 0 {
            Label("Earlier notice dates have passed. These dates are for the next term you can still end.",
                  systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(Color.orange)
        }
    }

    private var renewalText: String {
        renewalMonths == 1 ? "Every month" : "Every \(renewalMonths) months"
    }
}

// MARK: - Timeline

/// Every key date, soonest first, with its reminder and done switches.
private struct ItemDetailTimelineSection: View {
    var item: VaultItem
    var today: DayDate
    var notificationsDenied: Bool
    var onReminders: (Deadline, Bool) -> Void
    var onDone: (Deadline, Bool) -> Void

    var body: some View {
        let rows: [Deadline] = item.sortedDeadlines
        let buffer: Int = RecordService.rules.postalBufferDays
        Section {
            if rows.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                ItemDetailDeadlineRow(deadline: row, today: today, postalBufferDays: buffer,
                                      onReminders: { on in onReminders(row, on) },
                                      onDone: { done in onDone(row, done) })
            }
        } header: {
            Text("Key dates")
        } footer: {
            Text(footerText)
        }
    }

    private var emptyText: String {
        if item.kind == ItemKind.contract {
            return item.termEnd == nil
                ? "Set when the term ends with Edit to plan the notice deadline."
                : "No dates apply with these details."
        }
        if !item.category.tracksGoodsDates {
            return "No legal dates apply to this category. With Edit you can set a return window, a warranty or your own dates."
        }
        return "No dates apply with these details. With Edit you can add your own."
    }

    private var footerText: String {
        if notificationsDenied {
            return "Notifications are turned off for ReceiptVault in the iPhone's Settings, so these reminders cannot arrive."
        }
        return "'Done' stops a date's reminders. Change the dates with Edit, and the defaults in Settings › Rules."
    }
}

/// One key date: name, 'Return by 9 Apr 2026', how far away it is, its
/// certainty and basis, then 'Remind me' and 'Done'. A notice deadline adds
/// 'Send by', which leaves the postal buffer from the rules.
private struct ItemDetailDeadlineRow: View {
    var deadline: Deadline
    var today: DayDate
    var postalBufferDays: Int
    var onReminders: (Bool) -> Void
    var onDone: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: deadline.kind.symbol)
                    .foregroundStyle(symbolColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deadline.displayLabel)
                    Text(dateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                    if let send = sendByText {
                        Text(send)
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                }
                Spacer(minLength: 8)
                CertaintyBadge(certainty: deadline.certainty)
            }
            if !basisText.isEmpty {
                Text(basisText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Remind me", isOn: remindBinding)
                .font(.subheadline)
            if let lead = leadText {
                Text(lead)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Done", isOn: doneBinding)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private var remindBinding: Binding<Bool> {
        Binding<Bool>(
            get: { deadline.remindersOn },
            set: { on in onReminders(on) }
        )
    }

    private var doneBinding: Binding<Bool> {
        Binding<Bool>(
            get: { deadline.isDone },
            set: { done in onDone(done) }
        )
    }

    private var daysLeft: Int { RVCalendar.daysBetween(today, deadline.day) }

    /// 'Return by 9 Apr 2026'.
    private var dateText: String {
        "\(deadline.kind.dueWording) \(Formatters.day(deadline.day))"
    }

    /// 'Done', or EvidenceSummary.status with a capital: 'In 5 days', '3 days ago'.
    private var statusText: String {
        if deadline.isDone { return "Done" }
        let when = EvidenceSummary.status(of: deadline.day, today: today)
        return when.prefix(1).uppercased() + String(when.dropFirst())
    }

    /// 'Send by 3 Mar 2026' for an open notice deadline, when it is earlier.
    private var sendByText: String? {
        guard deadline.kind == DeadlineKind.noticeDeadline, !deadline.isDone else { return nil }
        let send = ContractMath.sendBy(noticeBy: deadline.day, postalBufferDays: postalBufferDays)
        guard send < deadline.day else { return nil }
        return "Send by \(Formatters.day(send))"
    }

    private var basisText: String {
        deadline.basis.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When it reminds; nil while it does not.
    private var leadText: String? {
        guard deadline.remindersOn, !deadline.isDone else { return nil }
        if daysLeft < 0 { return "This date has passed, so it no longer reminds you." }
        let text = ItemDetailDeadlineRow.leadTimes(deadline.offsets)
        return text.isEmpty ? nil : text
    }

    private var statusColor: Color {
        if deadline.isDone { return Color.green }
        if daysLeft < 0 { return Color.secondary }
        if daysLeft <= 7 { return Color.orange }
        return Color.primary
    }

    private var symbolColor: Color {
        if deadline.isDone || daysLeft < 0 { return Color.secondary }
        return Color.accentColor
    }

    /// 'Reminds you 30 and 7 days before', 'Reminds you 1 day before and on the day'.
    private static func leadTimes(_ offsets: [Int]) -> String {
        let days: [Int] = Array(Set(offsets.filter { $0 > 0 })).sorted(by: >)
        var parts: [String] = []
        if !days.isEmpty {
            let numbers: [String] = days.map { String($0) }
            let list: String = numbers.count == 1
                ? numbers[0]
                : numbers.dropLast().joined(separator: ", ") + " and " + numbers[numbers.count - 1]
            let unit = days == [1] ? "day" : "days"
            parts.append("\(list) \(unit) before")
        }
        if offsets.contains(0) { parts.append("on the day") }
        return parts.isEmpty ? "" : "Reminds you " + parts.joined(separator: " and ")
    }
}

// MARK: - Legal notes

/// LegalNotes for the country, channel and fault state, ending with the disclaimer.
private struct ItemDetailLegalSection: View {
    var item: VaultItem

    var body: some View {
        let notes: [LegalNote] = LegalNotes.notes(for: item.jurisdiction, channel: item.channel, kind: item.kind,
                                                  hasIssue: item.hasIssue, isUsed: item.isUsed)
        Section {
            ForEach(Array(notes.enumerated()), id: \.offset) { entry in
                ItemDetailLegalNoteRow(note: entry.element)
            }
        } header: {
            Text(headerText)
        } footer: {
            NotLegalAdviceFooter()
        }
    }

    private var headerText: String {
        let place = item.jurisdiction.label
        return item.kind == ItemKind.contract ? "Giving notice · \(place)" : "Your rights · \(place)"
    }
}

/// A note, its basis, and 'Assumed' when it is an assumption.
private struct ItemDetailLegalNoteRow: View {
    var note: LegalNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.text)
                .font(.subheadline)
            if note.isAssumption || !basisText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if note.isAssumption {
                        CertaintyBadge(certainty: Certainty.assumption)
                    }
                    if !basisText.isEmpty {
                        Text(basisText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var basisText: String {
        note.basis.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Details

/// Category, channel, country, tax tag, used goods and fault, then the
/// product lines and the notes.
private struct ItemDetailFactsSection: View {
    var item: VaultItem

    var body: some View {
        let lines: [ItemLine] = item.lines
        let notes: String = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Section {
            if item.kind != ItemKind.contract {
                LabeledContent("Category", value: item.category.label)
                LabeledContent("Bought", value: item.channel.label)
            }
            LabeledContent("Country", value: item.jurisdiction.label)
            LabeledContent("Tax claim", value: item.taxTag.label)
            if item.isUsed {
                LabeledContent("Condition", value: "Used or second-hand")
            }
            if item.hasIssue {
                LabeledContent("Fault noticed on", value: faultText)
            }
            LabeledContent("Added", value: Formatters.dateTime(item.createdAt))
        } header: {
            Text("Details")
        }
        if !lines.isEmpty {
            Section {
                ForEach(Array(lines.enumerated()), id: \.offset) { entry in
                    ItemDetailLineRow(line: entry.element, currency: item.currency)
                }
            } header: {
                Text(lines.count == 1 ? "Product" : "Products")
            }
        }
        if !notes.isEmpty {
            Section {
                Text(notes)
                    .textSelection(.enabled)
            } header: {
                Text("Notes")
            }
        }
    }

    /// The day 'Something's wrong with it' was first set.
    private var faultText: String {
        guard let at = item.issueNotedAt else { return "Not recorded" }
        return Formatters.day(RVCalendar.today(now: at))
    }
}

/// '2 × USB-C cable' and its amount.
private struct ItemDetailLineRow: View {
    var line: ItemLine
    var currency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(nameText)
            Spacer(minLength: 8)
            if let amount = line.amountMinor {
                AmountText(minor: amount, currency: currency)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nameText: String {
        let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? "Item" : name
        return line.quantity > 1 ? "\(line.quantity) × \(shown)" : shown
    }
}

// MARK: - Files

/// Each original with its source, capture time and the first 12 hex
/// characters of its SHA-256. Tapping one opens it in QuickLook.
private struct ItemDetailFilesSection: View {
    var files: [StoredFile]
    var onOpen: (StoredFile) -> Void

    var body: some View {
        Section {
            if files.isEmpty {
                Text("No original files are stored for this item.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(files.enumerated()), id: \.element.id) { entry in
                Button {
                    onOpen(entry.element)
                } label: {
                    ItemDetailFileRow(file: entry.element, number: entry.offset + 1)
                }
            }
        } header: {
            Text("Original files")
        } footer: {
            Text("The fingerprint (SHA-256) was taken when each file was saved. The evidence PDF checks every file against it again.")
        }
    }
}

private struct ItemDetailFileRow: View {
    var file: StoredFile
    var number: Int

    var body: some View {
        let missing: Bool = !FileVault.exists(file.fileName)
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(file: file, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(nameText)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(savedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(hashText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if missing {
                    Text("The stored file is missing.")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The name it arrived with, else 'File 2'.
    private var nameText: String {
        let original = file.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return original.isEmpty ? "File \(number)" : original
    }

    /// 'PDF · 3 pages · 1.2 MB · Files', 'JPEG · 640 KB · Camera scan'.
    private var summaryText: String {
        var parts: [String] = []
        if file.isPDF {
            parts.append(file.pageCount == 1 ? "PDF · 1 page" : "PDF · \(file.pageCount) pages")
        } else {
            parts.append("JPEG")
        }
        if file.byteCount > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
        }
        parts.append(file.source.label)
        return parts.joined(separator: " · ")
    }

    private var savedText: String {
        "Saved \(Formatters.dateTime(file.capturedAt))"
    }

    /// 'SHA-256 3f2a9c01be47…'.
    private var hashText: String {
        let hash = file.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hash.isEmpty else { return "SHA-256 not recorded" }
        return "SHA-256 " + String(hash.prefix(12)) + "…"
    }
}

// MARK: - Small rows

/// A label with a spinner while its action runs.
private struct ItemDetailBusyLabel: View {
    var title: String
    var systemImage: String
    var busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            if busy {
                Spacer(minLength: 8)
                ProgressView()
            }
        }
    }
}
