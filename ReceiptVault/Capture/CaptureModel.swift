import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// A backup file shared with 'Open in', waiting for the restore sheet.
struct IncomingBackup: Identifiable {
    let id = UUID()
    let url: URL
}

/// Where a capture comes from in the Add menu.
enum CaptureKind {
    case scan, photos, files
}

/// Runs every capture: camera scans, photos, picked files and files shared
/// with 'Open in'. It is created once at app level, outside LockGate, so a
/// capture that is running when the app locks still finishes, and its review
/// opens after unlock.
///
/// Save first, check after:
/// 1. the originals go into the vault (FileVault) and are hashed;
/// 2. a file with the same SHA-256 marks the capture as a possible copy;
/// 3. the text is read on the phone (DocumentReader);
/// 4. ReceiptExtractor fills in what it is sure of;
/// 5. a new item is created, or the pages are added to `addTo`;
/// 6. reminder permission is asked the first time something reminds, then
///    the reminders are replanned;
/// 7. the review sheet opens for one new item; several get a message.
///
/// A reading error never loses files: the item is saved with blank fields and
/// needs a look. Captures run one at a time, in the order they arrive, and
/// alerts wait while the review sheet is open so they never compete with it.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var showScanner = false
    @Published var showPhotos = false
    @Published var showFiles = false
    @Published var photoItems: [PhotosPickerItem] = []
    /// What is happening now ('Reading 2 pages…'); nil when idle.
    @Published private(set) var working: String? = nil
    @Published private(set) var progress: Double = 0
    @Published var error: String? = nil
    @Published var message: String? = nil
    /// The item just created, for the review sheet (ItemEditView, isNew).
    @Published var reviewItem: VaultItem? = nil {
        didSet {
            if reviewItem == nil { reviewClosed() }
        }
    }
    /// An earlier item holding a file identical to one of reviewItem's.
    @Published var duplicateOf: VaultItem? = nil
    /// A shared .rvault file, for the restore sheet.
    @Published var pendingBackup: IncomingBackup? = nil
    /// The item the next capture adds pages to; set by start.
    @Published var addTo: VaultItem? = nil
    /// True while shared files wait in Staging/Incoming for processQueue.
    @Published private(set) var incomingPending = false

    private static let backupExtension = "rvault"
    private static let maxPhotos = 10
    /// Long enough for a sheet to finish closing.
    private static let closeDelay: UInt64 = 450_000_000
    /// A staged backup that no restore sheet shows is removed after this long.
    private static let staleBackupAge: TimeInterval = 3600
    /// Part of a document's progress bar spent saving the original.
    private static let saveShare = 0.2

    /// addTo's id, taken when the capture is handed over.
    private var targetID: UUID? = nil
    /// The last capture in the queue; each one waits for the one before.
    private var lastJob: Task<Void, Never>? = nil
    /// Bumped whenever the progress bar restarts, so late updates are ignored.
    private var jobNumber = 0
    /// The names of files shared with 'Open in', by their staged name.
    private var sharedNames: [String: String] = [:]
    /// The alert of the capture the review sheet shows ('No text could be
    /// read…'), shown once the sheet closes; dropped when that item is discarded.
    private var reviewNotice: Notice? = nil
    /// Alerts from anything else that happened while the review sheet was open.
    private var held: Notice? = nil
    /// When the camera or a picker last closed, so the review sheet is not
    /// presented while it is still sliding away.
    private var pickerClosedAt: Date? = nil
    /// A shared backup waiting for the review sheet to close (RootView shows
    /// the review and the restore sheet from the same view, one at a time).
    private var heldBackup: IncomingBackup? = nil

    // MARK: Types

    private struct IncomingFile {
        var url: URL
        var name: String
        /// Already in Staging/Incoming ('Open in'); picked files are staged first.
        var isStaged: Bool
    }

    private enum DocumentFormat {
        case pdf, image
    }

    /// What DocumentReader reads: the stored PDF, or full-resolution pages.
    private enum Pages {
        case pdf(URL)
        case images([UIImage])
    }

    private struct CreatedItem {
        var item: VaultItem
        var copyOf: VaultItem?
    }

    /// What one capture did, for steps 6 and 7.
    private struct Outcome {
        var created: [CreatedItem] = []
        var target: VaultItem? = nil
        var addedPages = 0
        var targetCopyOf: VaultItem? = nil
        /// New items whose text could not be read.
        var unread: [String] = []
        /// One line per file or page that could not be saved.
        var failed: [String] = []
    }

    private struct Notice {
        var text: String
        var isError: Bool
    }

    // MARK: Starting a capture

    /// Opens the scanner, the photo picker or the file picker. With `item`,
    /// what is captured is added to that item as new pages.
    func start(_ kind: CaptureKind, addTo item: VaultItem? = nil) {
        addTo = item
        targetID = item?.id
        switch kind {
        case .scan:
            if DocumentScannerView.isAvailable {
                showScanner = true
            } else {
                addTo = nil
                targetID = nil
                show(Notice(text: "Scanning needs the iPhone camera, which is not available here. You can still choose photos or files.",
                            isError: false))
            }
        case .photos:
            showPhotos = true
        case .files:
            showFiles = true
        }
    }

    /// 'Open in ReceiptVault' (onOpenURL, outside the lock). The file is moved
    /// into protected staging at once, while the phone is unlocked, and read
    /// after unlock by processQueue. A backup opens the restore sheet instead.
    func enqueue(_ url: URL) {
        guard url.isFileURL else { return }
        let name = url.lastPathComponent
        let isBackup = url.pathExtension.lowercased() == CaptureModel.backupExtension
        do {
            let staged = try FileVault.stageIncoming(url)
            if isBackup {
                offer(IncomingBackup(url: staged))
            } else {
                sharedNames[staged.lastPathComponent] = name
                incomingPending = true
            }
        } catch {
            // A processQueue job that ran first (the scene became active) may
            // already have moved this file out of Documents/Inbox with
            // FileVault.pendingIncoming(). It is staged, so it only needs
            // processing, not an error alert.
            if !FileManager.default.fileExists(atPath: url.path) {
                if isBackup {
                    if let staged = unclaimedStagedBackup() { offer(IncomingBackup(url: staged)) }
                } else {
                    incomingPending = true
                }
                return
            }
            show(Notice(text: CaptureModel.failure(name, error), isError: true))
        }
    }

    /// Shows the restore sheet for `backup`, or holds it while a review sheet is open.
    private func offer(_ backup: IncomingBackup) {
        if reviewItem != nil {
            heldBackup = backup
        } else {
            pendingBackup = backup
        }
    }

    /// The newest staged backup that no restore sheet shows or holds: the one
    /// pendingIncoming() has just moved out of Documents/Inbox.
    private func unclaimedStagedBackup() -> URL? {
        let showing = pendingBackup?.url.lastPathComponent
        let waiting = heldBackup?.url.lastPathComponent
        let backups = FileVault.pendingIncoming().filter { url in
            url.pathExtension.lowercased() == CaptureModel.backupExtension
                && url.lastPathComponent != showing
                && url.lastPathComponent != waiting
        }
        return backups.last
    }

    /// Reads the shared files waiting in staging, oldest first: one item each,
    /// source 'Shared to ReceiptVault'. Called after unlock; while the phone is
    /// locked the files stay staged.
    func processQueue(context: ModelContext) {
        schedule { [weak self] in
            guard let self = self else { return }
            await self.readIncoming(context: context)
        }
    }

    /// The document camera's pages become one item (or new pages of addTo).
    func scanned(_ images: [UIImage], context: ModelContext) {
        showScanner = false
        pickerClosedAt = Date()
        let target = takeTarget()
        guard !images.isEmpty else { return }
        let names = images.indices.map { i in "Scan page \(i + 1).jpg" }
        schedule { [weak self] in
            guard let self = self else { return }
            await self.captureImages(images, names: names, source: FileSource.scan, label: "the scan",
                                     targetID: target, outcome: Outcome(), context: context)
        }
    }

    /// Files from the file picker: one item each (or new pages of addTo).
    /// Each is staged, then saved as a PDF or an image by its extension.
    func picked(_ result: Result<[URL], Error>, context: ModelContext) {
        showFiles = false
        pickerClosedAt = Date()
        let target = takeTarget()
        switch result {
        case .failure(let problem):
            if let cocoa = problem as? CocoaError, cocoa.code == .userCancelled { return }
            show(Notice(text: problem.localizedDescription, isError: true))
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let files = urls.map { url in IncomingFile(url: url, name: url.lastPathComponent, isStaged: false) }
            schedule { [weak self] in
                guard let self = self else { return }
                var outcome = Outcome()
                _ = await self.captureFiles(files, source: FileSource.files, targetID: target,
                                            into: &outcome, context: context)
                await self.publish(outcome, context: context)
            }
        }
    }

    /// The picked photos (up to 10) become the pages of one item (or new pages
    /// of addTo). photoItems is cleared as soon as they are taken.
    func loadPhotos(context: ModelContext) {
        let items = Array(photoItems.prefix(CaptureModel.maxPhotos))
        guard !items.isEmpty else { return }
        photoItems = []
        showPhotos = false
        pickerClosedAt = Date()
        let target = takeTarget()
        schedule { [weak self] in
            guard let self = self else { return }
            await self.capturePhotos(items, targetID: target, context: context)
        }
    }

    /// 'Discard' on the review sheet: closes the sheet, then deletes the item
    /// with its originals and replans the reminders. The delete waits until
    /// the sheet has gone, so no view is left showing a deleted item.
    func discard(_ item: VaultItem, context: ModelContext) {
        let id = item.id
        // Only the review sheet showing this item is closed, and the alert
        // about its capture is dropped; alerts about anything else that
        // happened meanwhile still show. A review of another item stays open.
        if reviewItem?.id == id {
            reviewNotice = nil
            reviewItem = nil
            duplicateOf = nil
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: CaptureModel.closeDelay)
            do {
                if let live = RecordService.item(id: id, context: context) {
                    try RecordService.delete(live, context: context)
                }
            } catch {
                self?.show(Notice(text: "The item could not be deleted. \(error.localizedDescription)", isError: true))
            }
            await NotificationScheduler.replan(context: context)
        }
    }

    // MARK: Queue

    /// Runs captures one at a time, in the order they were handed over.
    private func schedule(_ job: @escaping @MainActor () async -> Void) {
        let previous = lastJob
        lastJob = Task { @MainActor in
            await previous?.value
            await job()
        }
    }

    /// The id of the item to add pages to, taken once per capture.
    private func takeTarget() -> UUID? {
        let id = targetID ?? addTo?.id
        targetID = nil
        addTo = nil
        return id
    }

    /// Shows `text` over the app and restarts the progress bar at `value`.
    private func begin(_ text: String, at value: Double) {
        jobNumber &+= 1
        working = text
        progress = value
    }

    /// The reader's progress (0...1), mapped onto base...base + span of the bar.
    private func reporter(from base: Double, span: Double) -> @Sendable (Double) -> Void {
        let number = jobNumber
        return { [weak self] value in
            guard let model = self else { return }
            let fraction = min(max(value, 0), 1)
            Task { @MainActor in
                guard model.jobNumber == number else { return }
                model.progress = base + span * fraction
            }
        }
    }

    // MARK: Captures

    /// processQueue's job. Files that arrive while it runs are read as well.
    private func readIncoming(context: ModelContext) async {
        var outcome = Outcome()
        var tried = Set<String>()
        while UIApplication.shared.isProtectedDataAvailable {
            let staged = FileVault.pendingIncoming()
            clearStaleBackups(staged)
            var files: [IncomingFile] = []
            for url in staged where url.pathExtension.lowercased() != CaptureModel.backupExtension {
                let key = url.lastPathComponent
                guard tried.insert(key).inserted else { continue }
                let name = sharedNames[key] ?? CaptureModel.sharedName(for: url)
                files.append(IncomingFile(url: url, name: name, isStaged: true))
            }
            if files.isEmpty { break }
            let finished = await captureFiles(files, source: FileSource.openIn, targetID: nil,
                                              into: &outcome, context: context)
            if !finished { break }
            for file in files {
                sharedNames.removeValue(forKey: file.url.lastPathComponent)
            }
        }
        incomingPending = false
        await publish(outcome, context: context)
    }

    /// Loads the picked photos, then saves and reads them like scanned pages.
    private func capturePhotos(_ items: [PhotosPickerItem], targetID: UUID?, context: ModelContext) async {
        begin("Loading \(CaptureModel.counted(items.count, "photo", "photos"))…", at: 0)
        var images: [UIImage] = []
        var names: [String] = []
        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
                names.append("Photo \(index + 1).jpg")
            }
            progress = Double(index + 1) / Double(items.count)
        }
        var outcome = Outcome()
        if images.isEmpty {
            let what = items.count == 1 ? "The photo" : "The photos"
            outcome.failed.append("\(what) could not be loaded. If your photos are kept in iCloud, check that they have downloaded, then try again.")
            await publish(outcome, context: context)
            return
        }
        let missing = items.count - images.count
        if missing == 1 {
            outcome.failed.append("1 photo could not be loaded, so it was left out.")
        } else if missing > 1 {
            outcome.failed.append("\(missing) photos could not be loaded, so they were left out.")
        }
        let label = images.count == 1 ? "the photo" : "the photos"
        await captureImages(images, names: names, source: FileSource.photos, label: label,
                            targetID: targetID, outcome: outcome, context: context)
    }

    /// Scans and photos: every page is saved first, then all are read as one item.
    private func captureImages(_ images: [UIImage], names: [String], source: FileSource, label: String,
                               targetID: UUID?, outcome initial: Outcome, context: ModelContext) async {
        var outcome = initial
        begin("Reading \(CaptureModel.counted(images.count, "page", "pages"))…", at: 0)
        let total = Double(max(images.count, 1))
        var saved: [SavedFile] = []
        var kept: [UIImage] = []
        for (index, image) in images.enumerated() {
            let name = index < names.count ? names[index] : "Page \(index + 1).jpg"
            do {
                let file = try await CaptureModel.save(image: image, name: name)
                saved.append(file)
                kept.append(image)
            } catch {
                outcome.failed.append(CaptureModel.failure(name, error))
            }
            progress = CaptureModel.saveShare * Double(index + 1) / total
        }
        if !saved.isEmpty {
            await record(saved, source: source, label: label, targetID: targetID, pages: Pages.images(kept),
                         from: CaptureModel.saveShare, span: 1 - CaptureModel.saveShare,
                         into: &outcome, context: context)
        }
        await publish(outcome, context: context)
    }

    /// Steps 1 to 5 for picked or shared files: one item each, or new pages of
    /// the target. Returns false when it stopped because the phone locked; a
    /// staged file that was not saved yet waits for the next unlock.
    private func captureFiles(_ files: [IncomingFile], source: FileSource, targetID: UUID?,
                              into outcome: inout Outcome, context: ModelContext) async -> Bool {
        let share = 1 / Double(max(files.count, 1))
        for (index, file) in files.enumerated() {
            guard UIApplication.shared.isProtectedDataAvailable else {
                if !file.isStaged { outcome.failed.append(CaptureModel.lockedNote) }
                return false
            }
            let base = Double(index) * share
            let counter = files.count > 1 ? " (\(index + 1) of \(files.count))" : ""
            begin("Reading \(file.name)\(counter)…", at: base)

            guard let format = CaptureModel.format(of: file.url) else {
                if file.isStaged { CaptureModel.remove(file.url) }
                outcome.failed.append("Could not save \(file.name): ReceiptVault keeps PDFs and images (JPEG, PNG or HEIC).")
                continue
            }

            // 1. The original goes into the vault before anything is read.
            var local = file.url
            if !file.isStaged {
                do {
                    local = try await CaptureModel.stage(file.url)
                } catch {
                    outcome.failed.append(CaptureModel.failure(file.name, error))
                    continue
                }
            }
            let stored: (file: SavedFile, imageData: Data?)
            do {
                stored = try await CaptureModel.save(local, isPDF: format == DocumentFormat.pdf, name: file.name)
            } catch {
                // Locked meanwhile: a shared file stays staged for the next
                // unlock. A picked file's staged copy is removed, because the
                // note asks for it to be chosen again (kept, it would later be
                // read a second time as a shared file).
                guard UIApplication.shared.isProtectedDataAvailable else {
                    if !file.isStaged {
                        CaptureModel.remove(local)
                        outcome.failed.append(CaptureModel.lockedNote)
                    }
                    return false
                }
                CaptureModel.remove(local)
                outcome.failed.append(CaptureModel.failure(file.name, error))
                continue
            }
            CaptureModel.remove(local)
            progress = base + share * CaptureModel.saveShare

            let pages: Pages
            switch format {
            case .pdf:
                pages = Pages.pdf(FileVault.url(stored.file.fileName))
            case .image:
                var images: [UIImage] = []
                if let data = stored.imageData, let image = UIImage(data: data) {
                    images.append(image)
                }
                pages = Pages.images(images)
            }
            await record([stored.file], source: source, label: file.name, targetID: targetID, pages: pages,
                         from: base + share * CaptureModel.saveShare, span: share * (1 - CaptureModel.saveShare),
                         into: &outcome, context: context)
        }
        return true
    }

    /// Steps 2 to 5 for one capture whose originals are already saved.
    private func record(_ files: [SavedFile], source: FileSource, label: String, targetID: UUID?, pages: Pages,
                        from base: Double, span: Double, into outcome: inout Outcome,
                        context: ModelContext) async {
        // 2. A file with the same SHA-256 is already in the vault.
        let before = targetID.flatMap { id in RecordService.item(id: id, context: context) }
        let copyOf = CaptureModel.duplicate(of: files, excluding: before, context: context)

        // 3. Read the text. A failure leaves the fields blank; the files are kept.
        let report = reporter(from: base, span: span)
        var lines: [TextLine] = []
        var fromOCR = false
        do {
            let output: DocumentReader.Output
            switch pages {
            case .pdf(let url):
                output = try await DocumentReader.read(pdf: url, progress: report)
            case .images(let images):
                output = try await CaptureModel.readPages(images, progress: report)
            }
            lines = output.lines
            fromOCR = output.usedOCR
        } catch {
            lines = []
        }

        let text = ReceiptText.plainText(lines)

        // 5a. New pages of the target, if it still exists. Nothing is awaited
        //     between this fetch and the change, so the target cannot go meanwhile.
        if let id = targetID, let target = RecordService.item(id: id, context: context) {
            do {
                try RecordService.addFiles(files, source: source, text: text, to: target, context: context)
                outcome.target = target
                outcome.addedPages += files.reduce(0) { sum, file in sum + file.pageCount }
                if outcome.targetCopyOf == nil { outcome.targetCopyOf = copyOf }
            } catch {
                // The new StoredFiles and field changes are dropped, so a
                // later save cannot store them; the originals saved for them
                // are removed, as the message says they were not saved.
                context.rollback()
                FileVault.delete(files.flatMap { file in [file.fileName, file.thumbName] })
                outcome.failed.append(CaptureModel.failure(label, error))
            }
            return
        }

        // 4. What the text says; an unread document gives ReceiptFields().
        var fields = ReceiptFields()
        if !lines.isEmpty {
            fields = await CaptureModel.extract(lines, today: RVCalendar.today(), fromOCR: fromOCR)
        }

        // 5b. Otherwise a new item.
        do {
            let item = try RecordService.createItem(fields: fields, files: files, source: source,
                                                    ocrText: text, context: context)
            outcome.created.append(CreatedItem(item: item, copyOf: copyOf))
            if lines.isEmpty { outcome.unread.append(label) }
        } catch {
            // The item, its StoredFiles and Deadlines are still pending in the
            // context: drop them, so a later save cannot store an item the
            // user was told had failed, and remove the originals saved for it.
            context.rollback()
            FileVault.delete(files.flatMap { file in [file.fileName, file.thumbName] })
            outcome.failed.append(CaptureModel.failure(label, error))
        }
    }

    /// Steps 6 and 7 for everything one capture created or changed.
    private func publish(_ outcome: Outcome, context: ModelContext) async {
        working = nil
        progress = 0
        jobNumber &+= 1

        // 6. Permission the first time something reminds, then the new plan.
        var touched: [VaultItem] = outcome.created.map { $0.item }
        if let target = outcome.target { touched.append(target) }
        if !touched.isEmpty {
            let reminds = touched.contains { item in
                item.deadlines.contains { row in row.remindersOn && !row.isDone }
            }
            if reminds {
                _ = await NotificationScheduler.requestIfNeeded()
            }
            await NotificationScheduler.replan(context: context)
        }

        // 7. The review sheet for one new item; a message otherwise.
        var notes: [String] = []
        if let target = outcome.target {
            let pages = CaptureModel.counted(outcome.addedPages, "page", "pages")
            notes.append("Added \(pages) to \(CaptureModel.quoted(target.title)).")
            if let copy = outcome.targetCopyOf {
                notes.append("One of the added files is identical to a file in \(CaptureModel.quoted(copy.title)).")
            }
        }
        let created = outcome.created
        // RootView presents the review, the restore sheet, the camera and the
        // pickers from the same view, so the review opens only once the one
        // that closed last has gone, and while no other is showing.
        var opensReview = false
        if created.count == 1 && outcome.target == nil {
            await waitForPickersToClose()
            opensReview = reviewItem == nil && pendingBackup == nil
                && !showScanner && !showPhotos && !showFiles
        }
        if opensReview {
            duplicateOf = created[0].copyOf
            reviewItem = created[0].item
        } else if created.count == 1 {
            notes.append("\(CaptureModel.quoted(created[0].item.title)) is saved in the Library.")
            if let copy = created[0].copyOf {
                notes.append("It looks like a copy of \(CaptureModel.quoted(copy.title)).")
            }
        } else if created.count > 1 {
            notes.append(CaptureModel.severalNote(created))
        }
        if !outcome.unread.isEmpty {
            notes.append(CaptureModel.unreadNote(outcome.unread))
        }

        let info = notes.joined(separator: " ")
        let problems = outcome.failed.joined(separator: "\n")
        if opensReview {
            // The notes are about the item under review ('No text could be
            // read…'): shown when its sheet closes, and dropped if it is
            // discarded. Files that could not be saved are not part of that
            // item, so they are held and shown after the sheet closes either
            // way (show holds them, as the review is now open).
            if !info.isEmpty {
                reviewNotice = CaptureModel.merged(reviewNotice, Notice(text: info, isError: false))
            }
            if !problems.isEmpty {
                show(Notice(text: problems, isError: true))
            }
            return
        }
        if !problems.isEmpty {
            show(Notice(text: info.isEmpty ? problems : problems + "\n\n" + info, isError: true))
        } else if !info.isEmpty {
            show(Notice(text: info, isError: false))
        }
    }

    /// Waits until the camera or picker that closed last has finished closing.
    private func waitForPickersToClose() async {
        guard let closed = pickerClosedAt else { return }
        let delay = Double(CaptureModel.closeDelay) / 1_000_000_000
        let remaining = delay - Date().timeIntervalSince(closed)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    // MARK: Alerts

    /// Alerts wait while the review sheet is open, so they never compete with it.
    private func show(_ notice: Notice) {
        if reviewItem != nil {
            held = CaptureModel.merged(held, notice)
        } else if notice.isError {
            error = CaptureModel.appended(error, notice.text)
        } else {
            message = CaptureModel.appended(message, notice.text)
        }
    }

    /// The review sheet closed: the duplicate banner goes, and a held backup
    /// and the held alerts are shown once the sheet has finished closing.
    private func reviewClosed() {
        duplicateOf = nil
        // A let, not a var: it is captured by the Task below.
        let notice: Notice?
        if let later = held {
            notice = CaptureModel.merged(reviewNotice, later)
        } else {
            notice = reviewNotice
        }
        let backup = heldBackup
        reviewNotice = nil
        held = nil
        heldBackup = nil
        guard notice != nil || backup != nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: CaptureModel.closeDelay)
            guard let model = self else { return }
            if let waiting = backup {
                if model.reviewItem == nil {
                    model.pendingBackup = waiting
                } else {
                    model.heldBackup = waiting
                }
            }
            if let text = notice {
                model.show(text)
            }
        }
    }

    /// A staged backup that no restore sheet is showing is removed after an
    /// hour. It is only a copy: the backup stays wherever it was shared from.
    private func clearStaleBackups(_ staged: [URL]) {
        let cutoff = Date().addingTimeInterval(-CaptureModel.staleBackupAge)
        let showing = pendingBackup?.url.lastPathComponent
        let waiting = heldBackup?.url.lastPathComponent
        for url in staged where url.pathExtension.lowercased() == CaptureModel.backupExtension {
            if url.lastPathComponent == showing || url.lastPathComponent == waiting { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? Date.distantPast
            if modified < cutoff { CaptureModel.remove(url) }
        }
    }

    // MARK: Off the main actor

    /// Scans and photos: drawn upright, downscaled and saved as JPEG.
    private nonisolated static func save(image: UIImage, name: String) async throws -> SavedFile {
        try FileVault.save(image: image, originalName: name)
    }

    /// Copies a picked file into protected staging.
    private nonisolated static func stage(_ url: URL) async throws -> URL {
        try FileVault.stageIncoming(url)
    }

    /// A staged PDF (kept byte for byte) or image file, saved into the vault,
    /// with the image bytes when it is an image.
    private nonisolated static func save(_ local: URL, isPDF: Bool,
                                         name: String) async throws -> (file: SavedFile, imageData: Data?) {
        if isPDF {
            let file = try FileVault.save(pdfAt: local, originalName: name)
            return (file: file, imageData: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: local)
        } catch {
            throw AppError.message("That image could not be opened.")
        }
        let file = try FileVault.save(imageData: data, originalName: name)
        return (file: file, imageData: data)
    }

    private nonisolated static func extract(_ lines: [TextLine], today: DayDate, fromOCR: Bool) async -> ReceiptFields {
        ReceiptExtractor.extract(lines: lines, today: today, fromOCR: fromOCR)
    }

    // MARK: Helpers

    /// Reads full-resolution pages one at a time, so only one large photo is
    /// decoded at once, and numbers the lines by page as a single read would.
    private static func readPages(_ images: [UIImage],
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> DocumentReader.Output {
        var lines: [TextLine] = []
        let count = Double(max(images.count, 1))
        for (index, image) in images.enumerated() {
            let part = try await DocumentReader.read(images: [image], progress: { value in
                progress((Double(index) + value) / count)
            })
            for line in part.lines {
                var numbered = line
                numbered.page = index
                lines.append(numbered)
            }
        }
        return DocumentReader.Output(lines: lines, pages: images.count, usedOCR: true)
    }

    /// The earliest other item holding a file identical to one of these.
    private static func duplicate(of files: [SavedFile], excluding item: VaultItem?,
                                  context: ModelContext) -> VaultItem? {
        for file in files {
            if let found = RecordService.duplicate(of: file.sha256, excluding: item, context: context) {
                return found
            }
        }
        return nil
    }

    /// PDF or image, by the file name's extension; nil for anything else.
    private static func format(of url: URL) -> DocumentFormat? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: UTType.pdf) { return DocumentFormat.pdf }
        if type.conforms(to: UTType.image) { return DocumentFormat.image }
        return nil
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The name of a shared file whose own name was not kept (it arrived
    /// before the app was last closed).
    private static func sharedName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "Shared file" : "Shared file.\(ext)"
    }

    private static let lockedNote = "The iPhone locked before every file was saved. Choose any that are missing again."

    /// 'Could not save receipt.pdf: That PDF is larger than 40 MB, …'
    private static func failure(_ name: String, _ error: Error) -> String {
        "Could not save \(name): \(error.localizedDescription)"
    }

    /// '3 items saved. 1 of them needs a look. …'
    private static func severalNote(_ created: [CreatedItem]) -> String {
        var parts: [String] = ["\(created.count) items saved."]
        let review = created.filter { $0.item.needsReview }.count
        if review == created.count {
            parts.append("They all need a look.")
        } else if review == 1 {
            parts.append("1 of them needs a look.")
        } else if review > 1 {
            parts.append("\(review) of them need a look.")
        }
        let copies = created.filter { $0.copyOf != nil }.count
        if copies == 1 {
            parts.append("1 looks like a copy of an item you already have.")
        } else if copies > 1 {
            parts.append("\(copies) look like copies of items you already have.")
        }
        return parts.joined(separator: " ")
    }

    private static func unreadNote(_ names: [String]) -> String {
        if names.count == 1 {
            return "No text could be read from \(names[0]). The item is saved with blank details for you to fill in."
        }
        return "No text could be read from \(CaptureModel.list(names)). Those items are saved with blank details for you to fill in."
    }

    /// '1 page', '3 pages'.
    private static func counted(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    /// 'a', 'a and b', 'a, b and c'.
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private static func quoted(_ title: String) -> String {
        "“\(title)”"
    }

    private static func appended(_ current: String?, _ text: String) -> String {
        guard let current = current, !current.isEmpty else { return text }
        return current + "\n\n" + text
    }

    private static func merged(_ first: Notice?, _ next: Notice) -> Notice {
        guard let first = first else { return next }
        return Notice(text: first.text + "\n\n" + next.text, isError: first.isError || next.isError)
    }
}
