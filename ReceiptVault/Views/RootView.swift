import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

// The tab bar, and every capture presentation for the whole app: the document
// camera, the photo and file pickers, the review sheet, the restore sheet for
// a shared backup, the progress card and the capture alerts. They are hosted
// here once, so any tab (or an item's 'Add pages') starts a capture through
// CaptureModel and the result shows wherever the user is.

/// The three tabs.
enum RootTab: Hashable {
    case upcoming, library, settings
}

/// The app's root, shown once the vault is open and unlocked. Each time it
/// appears and each time the app becomes active, old exports are cleared,
/// files shared with 'Open in' are read, deadlines are resynced (contracts
/// roll forward) and the reminders are replanned.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var capture: CaptureModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = .upcoming
    /// False from the moment a capture sheet, camera or picker opens until
    /// shortly after it has closed, so an alert never starts while it is
    /// still sliding away.
    @State private var settled = true

    /// Exports still in tmp/Export after this long are deleted.
    private static let exportMaxAge: TimeInterval = 3600
    /// Photos picked at once; they become the pages of one item.
    private static let maxPhotos = 10
    /// Long enough for a sheet or picker to finish closing.
    private static let settleDelay: UInt64 = 450_000_000

    // The modifiers are split over three properties only to keep each
    // expression small for the type checker; together they are one chain.
    var body: some View {
        sheets
            .alert(noticeTitle, isPresented: noticeShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(noticeText)
            }
            .task(id: capturePresenting) {
                // Restarted (and the previous run cancelled) on every change.
                if capturePresenting {
                    settled = false
                } else if !settled {
                    try? await Task.sleep(nanoseconds: RootView.settleDelay)
                    if !Task.isCancelled { settled = true }
                }
            }
            .onAppear { refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .onChange(of: capture.incomingPending) { _, pending in
                if pending { capture.processQueue(context: context) }
            }
    }

    /// The review sheet for a new item and the restore sheet for a shared backup.
    private var sheets: some View {
        pickers
            .sheet(item: $capture.reviewItem) { item in
                ItemEditView(item: item, isNew: true)
                    .environmentObject(capture)
            }
            .sheet(item: $capture.pendingBackup) { backup in
                RestoreSheet(url: backup.url)
            }
    }

    /// The tabs with the progress card, the document camera, the photo
    /// picker and the file picker.
    private var pickers: some View {
        tabs
            .overlay {
                if let text = capture.working {
                    ProgressOverlay(text: text, progress: capture.progress)
                }
            }
            .fullScreenCover(isPresented: $capture.showScanner) {
                DocumentScannerView(onFinish: { images in
                    capture.scanned(images, context: context)
                }, onCancel: {
                    // An empty scan closes the camera and forgets 'Add pages'.
                    capture.scanned([], context: context)
                })
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $capture.showPhotos, selection: $capture.photoItems,
                          maxSelectionCount: RootView.maxPhotos, selectionBehavior: PhotosPickerSelectionBehavior.ordered,
                          matching: PHPickerFilter.images)
            .onChange(of: capture.photoItems) { _, items in
                if !items.isEmpty { capture.loadPhotos(context: context) }
            }
            .fileImporter(isPresented: $capture.showFiles, allowedContentTypes: [UTType.pdf, UTType.image],
                          allowsMultipleSelection: true) { result in
                capture.picked(result, context: context)
            }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            UpcomingView()
                .tabItem { Label("Upcoming", systemImage: "calendar.badge.clock") }
                .tag(RootTab.upcoming)
            LibraryView()
                .tabItem { Label("Library", systemImage: "tray.full") }
                .tag(RootTab.library)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
    }

    // MARK: Opening

    /// In this order: old exports go, shared files are read (after unlock
    /// only; CaptureModel checks), every item is resynced, then the
    /// reminders are replanned.
    private func refresh() {
        FileVault.clearExports(olderThan: RootView.exportMaxAge)
        capture.processQueue(context: context)
        try? RecordService.resyncAll(context: context)
        let current = context
        Task { await NotificationScheduler.replan(context: current) }
    }

    // MARK: Alerts

    /// True while a capture sheet, camera or picker is open. Alerts wait for
    /// it to close, so they never compete with it.
    private var capturePresenting: Bool {
        capture.reviewItem != nil || capture.pendingBackup != nil
            || capture.showScanner || capture.showPhotos || capture.showFiles
    }

    /// The capture's error, then its message; one alert shows both when both
    /// are waiting.
    private var noticeText: String {
        let parts: [String?] = [capture.error, capture.message]
        let texts: [String] = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return texts.joined(separator: "\n\n")
    }

    private var noticeTitle: String {
        capture.error != nil ? "Something went wrong" : "ReceiptVault"
    }

    /// No capture presentation is open, and the last one has finished closing.
    private var alertsAllowed: Bool {
        settled && !capturePresenting
    }

    /// OK clears what was shown. A dismissal forced by a capture sheet
    /// opening keeps the text, so the alert comes back once the sheet closes.
    private var noticeShown: Binding<Bool> {
        Binding<Bool>(
            get: { alertsAllowed && !noticeText.isEmpty },
            set: { shown in
                if !shown && alertsAllowed {
                    capture.error = nil
                    capture.message = nil
                }
            }
        )
    }
}
