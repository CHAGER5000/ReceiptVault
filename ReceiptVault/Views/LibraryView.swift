import SwiftUI
import SwiftData

// The Library tab: every item, newest purchase first, with search over the
// pre-folded blob (SearchText.parse and matches) and a segmented filter.
// Rows show the first page, the title, merchant and date, the total, the next
// reminded date and an orange dot when something needs a look. Swipe to
// delete asks first, then goes through RecordService and a replan.

// MARK: - Filter

/// The segments above the list.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, needsReview, warranties, contracts, tax

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .needsReview: return "Needs a look"
        case .warranties: return "Warranties"
        case .contracts: return "Contracts"
        case .tax: return "Tax"
        }
    }

    /// Needs a look: needsReview. Warranties: a manufacturer warranty or legal
    /// guarantee that runs to today or later, or a warranty card with no such
    /// date yet. Contracts: kind contract. Tax: any tax claim set.
    func includes(_ item: VaultItem, today: DayDate) -> Bool {
        switch self {
        case .all: return true
        case .needsReview: return item.needsReview
        case .warranties: return LibraryFilter.hasActiveCover(item, today: today)
        case .contracts: return item.kind == ItemKind.contract
        case .tax: return item.taxTag != TaxTag.none
        }
    }

    /// Shown when the filter leaves nothing (with an empty search field).
    var emptyTitle: String {
        switch self {
        case .all: return "Nothing here"
        case .needsReview: return "Nothing needs a look"
        case .warranties: return "No active warranties"
        case .contracts: return "No contracts"
        case .tax: return "No tax items"
        }
    }

    var emptyText: String {
        switch self {
        case .all: return "Tap Add to scan a receipt, choose photos or pick files."
        case .needsReview: return "Items whose shop, date or total could not be read with confidence appear here."
        case .warranties: return "Items whose manufacturer warranty or legal guarantee is still running appear here."
        case .contracts: return "Save an insurance policy, rental or phone contract to keep track of its notice date."
        case .tax: return "Items with a tax claim appear here. Choose one under 'Tax claim' when you edit an item."
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray"
        case .needsReview: return "exclamationmark.circle"
        case .warranties: return "checkmark.seal"
        case .contracts: return "signature"
        case .tax: return "building.columns"
        }
    }

    /// The deadline kinds that count as cover under 'Warranties'.
    private static let coverKinds: [DeadlineKind] = [DeadlineKind.manufacturerWarranty, DeadlineKind.legalGuarantee]

    /// True while a warranty or guarantee date is today or later. A warranty
    /// card without any such date (its length is not known yet) also counts,
    /// so it does not disappear from the list.
    static func hasActiveCover(_ item: VaultItem, today: DayDate) -> Bool {
        var hasCoverDate = false
        for row in item.deadlines where LibraryFilter.coverKinds.contains(row.kind) {
            if row.day >= today { return true }
            hasCoverDate = true
        }
        return item.kind == ItemKind.warranty && !hasCoverDate
    }
}

// MARK: - Library

struct LibraryView: View {
    @Query(sort: \VaultItem.purchaseDate, order: .reverse) private var items: [VaultItem]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var capture: CaptureModel

    @State private var search = ""
    @State private var filter: LibraryFilter = LibraryFilter.all
    /// The item whose swipe-to-delete waits for confirmation.
    @State private var pendingDelete: VaultItem? = nil
    @State private var problem: String? = nil
    /// Refreshed on every return to the app, so badges move on after midnight.
    @State private var today: DayDate = RVCalendar.today()

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Library")
                // Pushed by value, so the detail stays when its row leaves
                // the filtered list (see ItemDestinationView).
                .navigationDestination(for: UUID.self) { id in
                    ItemDestinationView(id: id)
                }
                .searchable(text: $search,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Shop, product, amount or date")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        AddMenu()
                            .disabled(capture.working != nil)
                    }
                }
                .confirmationDialog("Delete this item?", isPresented: deleteShown,
                                    titleVisibility: .visible, presenting: pendingDelete) { item in
                    Button("Delete item", role: .destructive) { delete(item) }
                } message: { item in
                    Text(LibraryView.deleteMessage(item))
                }
                .alert("Could not delete", isPresented: problemShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(problem ?? "")
                }
                .onAppear { today = RVCalendar.today() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { today = RVCalendar.today() }
                }
        }
    }

    // MARK: Content

    private var list: some View {
        let day: DayDate = today
        let shown: [VaultItem] = visibleItems(today: day)
        return List {
            if !items.isEmpty {
                LibraryFilterBar(selection: $filter)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            if shown.isEmpty {
                emptyState
                    .padding(.top, 32)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(shown) { item in
                    NavigationLink(value: item.id) {
                        ItemRow(item: item, today: day)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Not role .destructive: that removes the row at once,
                        // before the deletion is confirmed.
                        Button {
                            pendingDelete = item
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Color.red)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("No receipts yet", systemImage: "tray")
            } description: {
                Text("Tap Add to scan a receipt, choose photos or pick PDFs from Files. Everything stays on this iPhone.")
            }
        } else if !isSearchEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView(filter.emptyTitle, systemImage: filter.symbol,
                                   description: Text(filter.emptyText))
        }
    }

    // MARK: State

    private var isSearchEmpty: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The items in the chosen filter that match the search, newest purchase
    /// first and, on the same day, the latest saved first.
    private func visibleItems(today: DayDate) -> [VaultItem] {
        let query: SearchQuery = SearchText.parse(search)
        let chosen: LibraryFilter = filter
        let kept: [VaultItem] = items.filter { item in
            // Deleted, or already gone from the store after a save.
            if item.isDeleted || item.modelContext == nil { return false }
            if !chosen.includes(item, today: today) { return false }
            return SearchText.matches(query, blob: item.searchBlob, totalMinor: item.totalMinor)
        }
        return kept.sorted { a, b in
            if a.purchaseDate != b.purchaseDate { return a.purchaseDate > b.purchaseDate }
            return a.createdAt > b.createdAt
        }
    }

    private var deleteShown: Binding<Bool> {
        Binding<Bool>(
            get: { pendingDelete != nil },
            set: { shown in if !shown { pendingDelete = nil } }
        )
    }

    private var problemShown: Binding<Bool> {
        Binding<Bool>(
            get: { problem != nil },
            set: { shown in if !shown { problem = nil } }
        )
    }

    // MARK: Actions

    /// RecordService.delete, then a replan. A failed save is undone and reported.
    private func delete(_ item: VaultItem) {
        pendingDelete = nil
        guard !item.isDeleted, item.modelContext != nil else { return }
        do {
            try RecordService.delete(item, context: context)
        } catch {
            context.rollback()
            problem = "The item is still here. \(error.localizedDescription)"
            return
        }
        let modelContext = context
        Task { @MainActor in
            await NotificationScheduler.replan(context: modelContext)
        }
    }

    /// Never reads the fields of an item that is already gone, in case the
    /// dialog is drawn once more while it closes.
    private static func deleteMessage(_ item: VaultItem) -> String {
        let tail: String = "its original files and its reminders are deleted from ReceiptVault. This cannot be undone."
        if item.isDeleted || item.modelContext == nil { return "The item, " + tail }
        return "“\(ItemRow.displayTitle(item))”, " + tail
    }
}

// MARK: - Filter bar

/// The segmented filter. It scrolls sideways when the segments do not fit,
/// so 'Needs a look' is never cut short.
private struct LibraryFilterBar: View {
    @Binding var selection: LibraryFilter

    var body: some View {
        ScrollView(.horizontal) {
            Picker("Show", selection: $selection) {
                ForEach(LibraryFilter.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Row

/// Thumbnail, title, merchant · date, the total, the next reminded date and
/// an orange dot when the item needs a look.
struct ItemRow: View {
    var item: VaultItem
    var today: DayDate

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ThumbnailView(file: item.sortedFiles.first)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let next = item.nextOpenDeadline(today: today) {
                    ItemRowBadge(deadline: next, today: today)
                }
            }
            Spacer(minLength: 8)
            if let total = item.totalMinor {
                AmountText(minor: total, currency: item.currency)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(ItemRow.displayTitle(item))
                .font(.body)
                .lineLimit(1)
            if item.needsReview {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.orange)
                    .accessibilityLabel(Text("Needs a look"))
            }
        }
    }

    /// 'Merchant · 12 Mar 2026'; the kind stands in for a merchant that is
    /// missing or already shown as the title, and only the date is left when
    /// the kind itself is the title (no title and no merchant).
    private var subtitle: String {
        let date: String = Formatters.day(item.purchaseDay)
        let merchant = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = ItemRow.displayTitle(item)
        if !merchant.isEmpty && merchant.caseInsensitiveCompare(title) != .orderedSame {
            return "\(merchant) · \(date)"
        }
        let kindLabel: String = item.kind.label
        if title == kindLabel { return date }
        return "\(kindLabel) · \(date)"
    }

    /// The title, else the merchant, else the kind ('Receipt').
    static func displayTitle(_ item: VaultItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let merchant = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        return merchant.isEmpty ? item.kind.label : merchant
    }
}

/// The next reminded date: 'Warranty to Mar 2026', or 'Returns · in 5 days'
/// within a month. Orange for the last 7 days.
private struct ItemRowBadge: View {
    var deadline: Deadline
    var today: DayDate

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: deadline.kind.symbol)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(badgeTint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badgeTint.opacity(0.12), in: Capsule())
    }

    private var daysLeft: Int { RVCalendar.daysBetween(today, deadline.day) }

    /// Named apart from View.tint(_:), so the lookup is never in doubt.
    private var badgeTint: Color { daysLeft <= 7 ? Color.orange : Color.accentColor }

    private var text: String {
        if daysLeft <= 31 {
            let status = EvidenceSummary.status(of: deadline.day, today: today)
            return "\(ItemRowBadge.shortName(deadline)) · \(status)"
        }
        return "\(ItemRowBadge.farName(deadline)) \(Formatters.monthYear(deadline.day))"
    }

    /// A short name for the date, e.g. 'Warranty'.
    private static func shortName(_ d: Deadline) -> String {
        switch d.kind {
        case .returnWindow: return "Returns"
        case .cancellation: return "Cancel"
        case .rightToReject: return "Reject"
        case .faultPresumption: return "Fault presumed"
        case .manufacturerWarranty: return "Warranty"
        case .legalGuarantee: return "Guarantee"
        case .claimLimit: return "Claims"
        case .noticeDeadline: return "Notice"
        case .termEnd: return "Contract ends"
        case .custom: return d.displayLabel
        }
    }

    /// The words before the month, e.g. 'Warranty to'.
    private static func farName(_ d: Deadline) -> String {
        switch d.kind {
        case .returnWindow: return "Returns to"
        case .cancellation: return "Cancel by"
        case .rightToReject: return "Reject by"
        case .faultPresumption: return "Fault presumed to"
        case .manufacturerWarranty: return "Warranty to"
        case .legalGuarantee: return "Guarantee to"
        case .claimLimit: return "Claims to"
        case .noticeDeadline: return "Notice by"
        case .termEnd: return "Contract ends"
        case .custom: return d.displayLabel + " ·"
        }
    }
}
