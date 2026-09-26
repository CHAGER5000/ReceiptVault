import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Small shared views and helpers. Bodies stay small, with explicit types, so
// the type checker never has to work hard.

// MARK: - Formatting

enum Formatters {
    /// Medium date style ('12 Mar 2026'), in UTC because calendar days are
    /// stored as their UTC midnight.
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 'Mar 2026', in UTC.
    private static let monthYearFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM yyyy")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// A calendar day, e.g. '12 Mar 2026'.
    static func day(_ d: DayDate) -> String {
        let formatter: DateFormatter = Formatters.day
        return formatter.string(from: RVCalendar.date(d))
    }

    /// A month and year, e.g. 'Mar 2026'.
    static func monthYear(_ d: DayDate) -> String {
        Formatters.monthYearFormat.string(from: RVCalendar.date(d))
    }

    /// A moment on the phone's clock, e.g. '12 Mar 2026 at 14:32'.
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Small views

struct AmountText: View {
    var minor: Int64
    var currency: String

    var body: some View {
        Text(Money.format(minor, currency: currency))
            .monospacedDigit()
    }
}

struct KindIcon: View {
    var kind: ItemKind

    var body: some View {
        Image(systemName: kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.accentColor)
            .frame(width: 28, height: 28)
            .accessibilityLabel(Text(kind.label))
    }
}

/// Under a value read from the document: 'Please check' (orange) when the
/// reading was unsure, otherwise 'From document' (grey).
struct ConfidenceCaption: View {
    var needsCheck: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(needsCheck ? Color.orange : Color.secondary)
    }

    private var title: String { needsCheck ? "Please check" : "From document" }
    private var symbol: String { needsCheck ? "exclamationmark.circle" : "doc.text.viewfinder" }
}

/// Where a date comes from: Law, Assumed, From document or You.
struct CertaintyBadge: View {
    var certainty: Certainty

    var body: some View {
        Text(certainty.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(badgeColor)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .accessibilityLabel(Text(spokenLabel))
    }

    private var badgeColor: Color {
        switch certainty {
        case .law: return Color.blue
        case .assumption: return Color.orange
        case .printed: return Color.green
        case .user: return Color.gray
        }
    }

    private var spokenLabel: String { "Source: \(certainty.label)" }
}

/// Shown on every screen that shows rule dates.
struct NotLegalAdviceFooter: View {
    static let text: String = LegalNotes.disclaimer + " Defaults can be changed in Settings › Rules."

    var body: some View {
        Text(NotLegalAdviceFooter.text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// A warning shown only when the phone has no passcode: iOS cannot then
/// encrypt the vault, and the lock unlocks without asking.
struct PasscodeWarning: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if needsWarning {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set a passcode so iOS can encrypt your vault")
                        .font(.subheadline.weight(.semibold))
                    Text("Without one, the files on this iPhone are not encrypted and the Face ID lock cannot protect ReceiptVault. Set it in Settings › Face ID & Passcode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(Color.orange)
            }
        }
    }

    private var needsWarning: Bool {
        // Reading scenePhase re-checks on every return to the app, since a
        // passcode may have been set in Settings meanwhile.
        _ = scenePhase
        return !OwnerCheck.deviceHasPasscode()
    }
}

/// The stored thumbnail of a page, or a placeholder symbol.
struct ThumbnailView: View {
    var file: StoredFile?
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: placeholder)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private var thumbnail: UIImage? {
        guard let stored = file else { return nil }
        return FileVault.thumbnail(stored.thumbName)
    }

    private var placeholder: String {
        guard let stored = file else { return "doc" }
        return stored.isPDF ? "doc.richtext" : "photo"
    }
}

/// Scan, photos or files. With `addTo`, what is captured becomes new pages of
/// that item.
struct AddMenu: View {
    var addTo: VaultItem? = nil
    @EnvironmentObject private var capture: CaptureModel

    var body: some View {
        Menu {
            if DocumentScannerView.isAvailable {
                Button {
                    capture.start(.scan, addTo: addTo)
                } label: {
                    Label("Scan document", systemImage: "doc.viewfinder")
                }
            }
            Button {
                capture.start(.photos, addTo: addTo)
            } label: {
                Label("Choose photos", systemImage: "photo.on.rectangle")
            }
            Button {
                capture.start(.files, addTo: addTo)
            } label: {
                Label("Choose files", systemImage: "folder")
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var title: String { addTo == nil ? "Add" : "Add pages" }
    private var symbol: String { addTo == nil ? "plus" : "doc.badge.plus" }
}

/// A card over the screen while a capture runs.
struct ProgressOverlay: View {
    var text: String
    var progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                ProgressView(value: fraction)
                    .frame(maxWidth: 240)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var fraction: Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }
}

/// Shown instead of the app while the database is not open: the phone is
/// still locked (iOS pre-warmed the app), or opening failed.
struct VaultUnavailableView: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let text = detail {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Retry") { vault.open() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vault.open() }
        }
    }

    /// The error text, unless the vault is only waiting for the phone to unlock.
    private var failure: String? {
        guard !vault.waitingForUnlock, let text = vault.errorText else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var symbol: String { failure == nil ? "lock.shield" : "exclamationmark.triangle" }

    private var headline: String {
        if failure != nil { return "ReceiptVault could not open your vault" }
        if vault.waitingForUnlock { return "Unlock your iPhone to open ReceiptVault" }
        return "Opening your vault…"
    }

    private var detail: String? {
        if let text = failure { return text }
        if vault.waitingForUnlock {
            return "iOS keeps your vault encrypted while the phone is locked. It opens by itself once you unlock."
        }
        return nil
    }
}

/// A date-only picker over a DayDate. DatePicker works in local time, so the
/// day is shown as its local midnight and read back by year, month and day
/// only; it never shifts when the phone changes time zone.
struct DayDatePicker: View {
    var title: String
    @Binding var selection: DayDate

    var body: some View {
        DatePicker(title, selection: localDate, displayedComponents: .date)
    }

    private var localDate: Binding<Date> {
        Binding<Date>(
            get: { DayDatePicker.localMidnight(selection) },
            set: { newValue in selection = DayDatePicker.day(fromLocal: newValue) }
        )
    }

    /// Gregorian in the phone's time zone, so a Buddhist or Japanese
    /// calendar setting cannot change the year numbers.
    private static var localCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    static func localMidnight(_ d: DayDate) -> Date {
        var parts = DateComponents()
        parts.year = d.year
        parts.month = d.month
        parts.day = d.day
        return DayDatePicker.localCalendar.date(from: parts) ?? RVCalendar.date(d)
    }

    static func day(fromLocal date: Date) -> DayDate {
        let parts = DayDatePicker.localCalendar.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return RVCalendar.day(date) }
        return DayDate(year: y, month: m, day: d)
    }
}

// MARK: - Sharing

/// The system share sheet (Mail, Messages, AirDrop, Save to Files …).
/// `onComplete` runs once: when an activity finishes, when the sheet is
/// closed, or when it goes away any other way (e.g. swiped down).
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    var onComplete: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let coordinator = context.coordinator
        // A cancelled activity (e.g. Mail closed without sending) can return
        // to the still-open sheet, so only a finished activity or closing the
        // sheet counts; any other way the sheet goes away is caught by
        // dismantleUIViewController.
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            if completed || activityType == nil {
                coordinator.finish()
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        context.coordinator.update(onComplete)
    }

    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) {
        // After the view update, so onComplete may change state safely.
        DispatchQueue.main.async { coordinator.finish() }
    }

    /// Holds onComplete and runs it at most once.
    final class Coordinator {
        private var action: (() -> Void)?

        init(onComplete: @escaping () -> Void) {
            action = onComplete
        }

        func update(_ onComplete: @escaping () -> Void) {
            if action != nil { action = onComplete }
        }

        func finish() {
            guard let run = action else { return }
            action = nil
            run()
        }
    }
}

/// A file prepared for the share sheet (evidence PDF, CSV, backup). Exports
/// live in tmp/Export and are deleted once shared.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
    var deleteAfterShare: Bool = true

    /// Deletes the file when it was written only for this share.
    func cleanUp() {
        guard deleteAfterShare else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Deadlines

/// One key date: symbol, 'Return by 9 Apr 2026', title · merchant, and how
/// far away it is. Notice deadlines add 'Send by', which leaves the postal
/// buffer from the rules.
struct DeadlineRow: View {
    var deadline: Deadline
    var today: DayDate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: deadline.kind.symbol)
                .foregroundStyle(symbolColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.body)
                if !itemLine.isEmpty {
                    Text(itemLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let send = sendByText {
                    Text(send)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
            Spacer(minLength: 8)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// 'Return by 9 Apr 2026'; a custom date leads with its name.
    private var heading: String {
        let kind = deadline.kind
        let date = Formatters.day(deadline.day)
        if kind == DeadlineKind.custom {
            return "\(deadline.displayLabel) · \(kind.dueWording) \(date)"
        }
        return "\(kind.dueWording) \(date)"
    }

    /// The item's title and merchant, skipping blanks and repeats.
    private var itemLine: String {
        guard let item = deadline.item else { return "" }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let merchant = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if !merchant.isEmpty && merchant.caseInsensitiveCompare(title) != .orderedSame {
            parts.append(merchant)
        }
        if parts.isEmpty { parts.append(item.kind.label) }
        return parts.joined(separator: " · ")
    }

    /// 'Send by 3 Mar 2026' for an open notice deadline, when it is earlier.
    private var sendByText: String? {
        guard deadline.kind == DeadlineKind.noticeDeadline, !deadline.isDone else { return nil }
        let buffer = RecordService.rules.postalBufferDays
        let send = ContractMath.sendBy(noticeBy: deadline.day, postalBufferDays: buffer)
        guard send < deadline.day else { return nil }
        return "Send by \(Formatters.day(send))"
    }

    /// 'Done', or EvidenceSummary.status with a capital: 'In 5 days', 'Today'.
    private var statusText: String {
        if deadline.isDone { return "Done" }
        let when: String = EvidenceSummary.status(of: deadline.day, today: today)
        return when.prefix(1).uppercased() + String(when.dropFirst())
    }

    private var daysLeft: Int { RVCalendar.daysBetween(today, deadline.day) }

    private var statusColor: Color {
        if deadline.isDone { return Color.secondary }
        if daysLeft < 0 { return Color.red }
        if daysLeft <= 7 { return Color.orange }
        return Color.secondary
    }

    private var symbolColor: Color {
        if deadline.isDone { return Color.secondary }
        if daysLeft < 0 { return Color.red }
        return Color.accentColor
    }
}

// MARK: - File types

extension UTType {
    /// A ReceiptVault encrypted backup (.rvault), declared in Config/Info.plist.
    static let rvaultBackup: UTType = UTType(exportedAs: "com.chager5000.receiptvault.backup")
}
