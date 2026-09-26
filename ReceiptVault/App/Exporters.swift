import UIKit
import PDFKit
import SwiftData
// ObservableObject and @Published live in Combine, which UIKit, PDFKit and
// SwiftData do not re-export.
import Combine

// Files that leave or enter the app: the evidence PDF, the CSV, and the
// password-encrypted backup (export and restore). Models are read on the main
// actor first; drawing, key derivation and encryption then run in
// Task.detached with plain values only (URLs, Strings, Data, file names).
// Everything written here goes to tmp/Export or Staging with complete protection.

// MARK: - Evidence PDF

/// An original file for the evidence PDF, as plain values.
private struct EvidenceSource {
    var url: URL
    var isPDF: Bool
    var name: String
}

/// The evidence PDF: an A4 cover built from EvidenceSummary, then every page
/// of every original in order. PDF pages are copied as they are; each image
/// is drawn aspect-fit on its own A4 page.
enum EvidencePDF {
    /// A4 in points.
    static let pageSize = CGSize(width: 595.2, height: 841.8)
    static let margin: CGFloat = 48
    /// Margin around an image page.
    private static let imageMargin: CGFloat = 24
    /// Room kept free at the bottom of a cover page for its footer.
    private static let footerSpace: CGFloat = 20
    /// Room below an image for its caption.
    private static let captionSpace: CGFloat = 18
    /// How much of the next paragraph a heading needs below it on the same page.
    private static let keepTogether: CGFloat = 36

    /// Fixed English abbreviations, as in RecordService, so the cover reads
    /// the same on every phone.
    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Writes 'Evidence-<merchant>-<purchase day>.pdf' to tmp/Export and
    /// returns its URL. Earlier exports are deleted first. The item is read
    /// here, on the main actor (every file hash is taken again); drawing and
    /// merging run in the background with plain values.
    @MainActor
    static func make(for item: VaultItem) async throws -> URL {
        FileVault.clearExports()
        let input = RecordService.evidenceInput(for: item)
        let notes = LegalNotes.notes(for: item.jurisdiction, channel: item.channel, kind: item.kind,
                                     hasIssue: item.hasIssue, isUsed: item.isUsed)
        let lines = EvidenceSummary.lines(input, today: RVCalendar.today(), notes: notes,
                                          generatedAt: EvidencePDF.timestamp(Date()))
        let sources: [EvidenceSource] = item.sortedFiles.map { file in
            let original = file.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
            return EvidenceSource(url: file.url, isPDF: file.isPDF, name: original.isEmpty ? file.fileName : original)
        }
        let label = EvidencePDF.fileLabel(input)
        let target = FileVault.exportURL("Evidence-\(label)-\(input.purchaseDate.iso).pdf")
        let title = lines.first?.text ?? "Evidence summary"
        try await Task.detached(priority: .userInitiated) {
            try EvidencePDF.build(lines: lines, sources: sources, title: title, to: target)
        }.value
        return target
    }

    /// '25 Sep 2026, 14:32 (Europe/London)', on the phone's clock.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute, (1...12).contains(month) else { return "" }
        let clock = EvidencePDF.pad(hour) + ":" + EvidencePDF.pad(minute)
        return "\(day) \(EvidencePDF.monthAbbreviations[month - 1]) \(year), \(clock) (\(timeZone.identifier))"
    }

    // MARK: Building

    /// The cover, then the originals in order, written with complete protection.
    private static func build(lines: [EvidenceLine], sources: [EvidenceSource], title: String, to target: URL) throws {
        guard let doc = PDFDocument(data: EvidencePDF.cover(lines, title: title)) else {
            throw AppError.message("The evidence PDF could not be created.")
        }
        // The documents the pages were copied from stay alive until the PDF is written.
        var parts: [PDFDocument] = []
        for (index, source) in sources.enumerated() {
            autoreleasepool {
                let part = EvidencePDF.document(for: source, number: index + 1)
                EvidencePDF.append(part, to: doc)
                parts.append(part)
            }
        }
        let data = withExtendedLifetime(parts) { doc.dataRepresentation() }
        guard let pdf = data else {
            throw AppError.message("The evidence PDF could not be created.")
        }
        do {
            try pdf.write(to: target, options: [.atomic, .completeFileProtection])
        } catch {
            throw AppError.message("The evidence PDF could not be saved. Check that your iPhone is unlocked and has free space.")
        }
    }

    /// The pages of one original: the PDF itself, an image on its own A4
    /// page, or a notice page when the file is missing or cannot be read.
    /// The bytes are read into memory first (never memory-mapped): a mapped
    /// file with complete protection faults if the phone locks meanwhile.
    private static func document(for source: EvidenceSource, number: Int) -> PDFDocument {
        let bytes = try? Data(contentsOf: source.url)
        if source.isPDF {
            if let data = bytes, let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 {
                return pdf
            }
        } else if let data = bytes,
                  let image = UIImage(data: data),
                  let page = EvidencePDF.imagePage(image, caption: "Original file \(number): \(source.name)"),
                  let pdf = PDFDocument(data: page) {
            return pdf
        }
        let notice = "Original file \(number) (\(source.name)) could not be added to this PDF, because it is missing or cannot be read on this iPhone."
        return PDFDocument(data: EvidencePDF.noticePage(notice)) ?? PDFDocument()
    }

    /// Copies every page of `part` to the end of `doc`.
    private static func append(_ part: PDFDocument, to doc: PDFDocument) {
        for index in 0..<part.pageCount {
            guard let page = part.page(at: index) else { continue }
            doc.insert((page.copy() as? PDFPage) ?? page, at: doc.pageCount)
        }
    }

    /// The merchant, else the title, else the kind: the middle of the file name.
    private static func fileLabel(_ input: EvidenceInput) -> String {
        for candidate in [input.merchant, input.title] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        }
        return input.kind.label
    }

    // MARK: Cover

    /// One paragraph (or part of one) laid out for the cover.
    private struct CoverBlock {
        var text: NSAttributedString
        var height: CGFloat
        var spaceBefore: CGFloat
        var spaceAfter: CGFloat
        var keepWithNext: Bool
    }

    /// The cover pages, drawn with NSAttributedString.draw(in:) inside 48 pt
    /// margins. A heading moves to the next page together with the start of
    /// its section, and a paragraph taller than a page is split.
    private static func cover(_ lines: [EvidenceLine], title: String) -> Data {
        let bounds = CGRect(origin: .zero, size: EvidencePDF.pageSize)
        let margin = EvidencePDF.margin
        let width = bounds.width - 2 * margin
        let bottom = bounds.height - margin - EvidencePDF.footerSpace
        let pageHeight = bottom - margin

        var blocks: [CoverBlock] = []
        for line in lines {
            let attributes = EvidencePDF.attributes(line.style)
            let pieces = EvidencePDF.pieces(line.text, attributes: attributes, width: width, maxHeight: pageHeight)
            for (i, piece) in pieces.enumerated() {
                blocks.append(CoverBlock(text: piece,
                                         height: EvidencePDF.height(of: piece, width: width),
                                         spaceBefore: i == 0 ? EvidencePDF.spaceBefore(line.style) : 0,
                                         spaceAfter: EvidencePDF.spaceAfter(line.style),
                                         keepWithNext: line.style == EvidenceStyle.heading))
            }
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "ReceiptVault",
                               kCGPDFContextTitle as String: title]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { context in
            var page = 0
            var y = margin
            for (index, block) in blocks.enumerated() {
                var needed = block.height
                if block.keepWithNext, index + 1 < blocks.count {
                    needed += block.spaceAfter + min(blocks[index + 1].height, EvidencePDF.keepTogether)
                }
                var top = y + block.spaceBefore
                if page == 0 || top + needed > bottom {
                    context.beginPage()
                    page += 1
                    EvidencePDF.drawFooter(page: page, bounds: bounds)
                    top = margin
                }
                block.text.draw(in: CGRect(x: margin, y: top, width: width, height: block.height + 2))
                y = top + block.height + block.spaceAfter
            }
            if page == 0 {
                context.beginPage()
                EvidencePDF.drawFooter(page: 1, bounds: bounds)
            }
        }
    }

    private static func attributes(_ style: EvidenceStyle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let font: UIFont
        let color: UIColor
        switch style {
        case .title:
            font = UIFont.systemFont(ofSize: 20, weight: .bold)
            color = UIColor.black
        case .heading:
            font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            color = UIColor.black
        case .body:
            font = UIFont.systemFont(ofSize: 10.5)
            color = UIColor.black
            paragraph.lineSpacing = 1.5
        case .small:
            font = UIFont.systemFont(ofSize: 8.5)
            color = UIColor.darkGray
            paragraph.lineSpacing = 1
        }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// The small style on one line, shortened in the middle when too long.
    private static func captionAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = EvidencePDF.attributes(EvidenceStyle.small)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    private static func spaceBefore(_ style: EvidenceStyle) -> CGFloat {
        style == EvidenceStyle.heading ? 12 : 0
    }

    private static func spaceAfter(_ style: EvidenceStyle) -> CGFloat {
        switch style {
        case .title, .heading: return 4
        case .body, .small: return 3
        }
    }

    /// The height the text needs at `width`, rounded up.
    private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let rect = text.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }

    /// The paragraph as one piece, or cut into pieces no taller than
    /// `maxHeight`, at a space where there is one.
    private static func pieces(_ text: String, attributes: [NSAttributedString.Key: Any],
                               width: CGFloat, maxHeight: CGFloat) -> [NSAttributedString] {
        var out: [NSAttributedString] = []
        var rest = text as NSString
        while rest.length > 0 {
            let whole = NSAttributedString(string: rest as String, attributes: attributes)
            if EvidencePDF.height(of: whole, width: width) <= maxHeight {
                out.append(whole)
                break
            }
            // The longest prefix that fits, found by halving (at least one character).
            var low = 1
            var high = rest.length - 1
            var fit = 1
            while low <= high {
                let mid = (low + high) / 2
                let prefix = NSAttributedString(string: rest.substring(to: mid), attributes: attributes)
                if EvidencePDF.height(of: prefix, width: width) <= maxHeight {
                    fit = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            // Never cut inside a composed character; prefer the last space.
            var cut = NSMaxRange(rest.rangeOfComposedCharacterSequence(at: fit - 1))
            if !EvidencePDF.isSpace(rest, at: cut) {
                let space = rest.rangeOfCharacter(from: .whitespaces, options: .backwards,
                                                  range: NSRange(location: 0, length: cut))
                if space.location != NSNotFound && space.location > 0 { cut = space.location }
            }
            out.append(NSAttributedString(string: rest.substring(to: cut), attributes: attributes))
            rest = rest.substring(from: cut).trimmingCharacters(in: .whitespaces) as NSString
        }
        return out
    }

    private static func isSpace(_ s: NSString, at index: Int) -> Bool {
        guard index < s.length, let scalar = Unicode.Scalar(s.character(at: index)) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static func drawFooter(page: Int, bounds: CGRect) {
        let margin = EvidencePDF.margin
        let text = NSAttributedString(string: "ReceiptVault evidence summary · page \(page)",
                                      attributes: EvidencePDF.attributes(EvidenceStyle.small))
        text.draw(in: CGRect(x: margin, y: bounds.height - margin - 10, width: bounds.width - 2 * margin, height: 14))
    }

    // MARK: Original pages

    /// The image drawn aspect-fit on an A4 page (landscape for a wide image),
    /// with a one-line caption naming the original. Nil for an empty image.
    private static func imagePage(_ image: UIImage, caption: String) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let a4 = EvidencePDF.pageSize
        let bounds = size.width > size.height
            ? CGRect(x: 0, y: 0, width: a4.height, height: a4.width)
            : CGRect(x: 0, y: 0, width: a4.width, height: a4.height)
        let inset = EvidencePDF.imageMargin
        let area = CGRect(x: inset, y: inset, width: bounds.width - 2 * inset,
                          height: bounds.height - 2 * inset - EvidencePDF.captionSpace)
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let frame = CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2,
                           width: fitted.width, height: fitted.height)
        let captionRect = CGRect(x: inset, y: area.maxY + 6, width: area.width, height: EvidencePDF.captionSpace)
        let text = NSAttributedString(string: caption, attributes: EvidencePDF.captionAttributes())
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: UIGraphicsPDFRendererFormat())
        return renderer.pdfData { context in
            context.beginPage()
            image.draw(in: frame)
            text.draw(in: captionRect)
        }
    }

    /// An A4 page that says why an original is not included.
    private static func noticePage(_ message: String) -> Data {
        let bounds = CGRect(origin: .zero, size: EvidencePDF.pageSize)
        let margin = EvidencePDF.margin
        let text = NSAttributedString(string: message, attributes: EvidencePDF.attributes(EvidenceStyle.body))
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: UIGraphicsPDFRendererFormat())
        return renderer.pdfData { context in
            context.beginPage()
            text.draw(in: CGRect(x: margin, y: margin, width: bounds.width - 2 * margin, height: bounds.height - 2 * margin))
        }
    }

    private static func pad(_ n: Int) -> String {
        n >= 0 && n < 10 ? "0\(n)" : "\(n)"
    }
}

// MARK: - CSV

/// 'ReceiptVault CSV v1' for the share sheet (Files, AirDrop, Mail...).
enum CSVFile {
    /// All the given items, or only those marked tax-claimable, written to
    /// tmp/Export with complete protection as 'ReceiptVault-items.csv' or
    /// 'ReceiptVault-tax.csv'.
    @MainActor
    static func make(items: [VaultItem], onlyClaimable: Bool) throws -> URL {
        let chosen = onlyClaimable ? items.filter({ $0.taxTag != TaxTag.none }) : items
        let csv = ItemCSV.make(chosen.map { RecordService.csvRow($0) })
        // Exports older than an hour are purged, as for backups.
        FileVault.clearExports(olderThan: 3600)
        let url = FileVault.exportURL(onlyClaimable ? "ReceiptVault-tax.csv" : "ReceiptVault-items.csv")
        do {
            try Data(csv.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw AppError.message("The CSV file could not be saved. Check that your iPhone is unlocked and has free space.")
        }
        return url
    }
}

// MARK: - Backup

/// What a restore brought in.
struct RestoreSummary: Equatable {
    /// Items inserted.
    var added: Int
    /// Items left out because one with the same id is already on this iPhone.
    var skipped: Int
    /// Original files restored.
    var files: Int

    /// 'Restored 3 items with 5 files. 1 item was already on this iPhone and was left as it is.'
    var message: String {
        if added == 0 {
            if skipped == 0 { return "The backup contains no items." }
            return skipped == 1
                ? "Nothing new to restore: the item in this backup is already on this iPhone."
                : "Nothing new to restore: all \(skipped) items in this backup are already on this iPhone."
        }
        var text = "Restored " + RestoreSummary.count(added, "item", "items")
        text += files > 0 ? " with " + RestoreSummary.count(files, "file", "files") + "." : "."
        if skipped > 0 {
            text += skipped == 1
                ? " 1 item was already on this iPhone and was left as it is."
                : " \(skipped) items were already on this iPhone and were left as they are."
        }
        return text
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}

/// One original to back up, as plain values.
private struct BackupSource {
    var name: String
    var url: URL
}

/// A decrypted and fully verified backup, waiting in Staging/Restore.
private struct RestoredBackup {
    var manifest: BackupManifest
    /// Backup file name -> its decrypted copy in Staging/Restore.
    var files: [String: URL]
}

/// The background half of BackupService. Plain values in and out, so it runs
/// in Task.detached; nothing here touches SwiftData.
private enum BackupJobs {
    /// The manifest, then every original that is still on disk, then the end
    /// frame. A partly written file is deleted on any error.
    static func write(to target: URL, password: String, manifest: Data, files: [BackupSource],
                      progress: @Sendable (Double) -> Void) throws {
        do {
            let writer = try BackupWriter(url: target, password: password)
            try writer.append(.manifest(manifest))
            let steps = Double(files.count + 1)
            progress(1 / steps)
            for (index, file) in files.enumerated() {
                try autoreleasepool {
                    try BackupJobs.appendFile(file, to: writer)
                }
                progress(Double(index + 2) / steps)
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// A missing original is left out (its record stays in the manifest). A
    /// file that exists but cannot be read stops the backup, because that
    /// usually means the iPhone was locked. The file is read, not
    /// memory-mapped: a mapped file with complete protection faults (a
    /// crash, not an error) if the phone locks while it is being encrypted.
    private static func appendFile(_ file: BackupSource, to writer: BackupWriter) throws {
        guard FileManager.default.fileExists(atPath: file.url.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: file.url)
        } catch {
            throw AppError.message("A file could not be read, so the backup stopped. Keep your iPhone unlocked until the backup has finished.")
        }
        try writer.append(.file(name: file.name, data: data))
    }

    /// Reads and verifies the whole backup (down to its end frame) before
    /// anything is restored. Only originals referenced by items that are not
    /// on the phone yet are decrypted into `dir`; the reader has already
    /// checked every name against the UUID.(jpg|pdf) allow-list.
    static func read(from source: URL, password: String, into dir: URL, skipping existing: Set<UUID>,
                     progress: @Sendable (Double) -> Void) throws -> RestoredBackup {
        BackupJobs.ensureDirectory(dir)
        let reader = try BackupReader(url: source, password: password)
        defer { reader.close() }

        guard let first = try reader.next(), case .manifest(let json) = first else {
            throw BackupError.badEntry
        }
        let manifest = try BackupManifest.decode(json)
        guard manifest.formatVersion <= BackupManifest.currentFormatVersion else {
            throw BackupError.unsupportedVersion(manifest.formatVersion)
        }

        var wanted = Set<String>()
        var expected = 0
        for item in manifest.items {
            expected += item.files.count
            if existing.contains(item.id) { continue }
            for file in item.files where BackupEntry.isAllowedFileName(file.fileName) {
                wanted.insert(file.fileName)
            }
        }

        var files: [String: URL] = [:]
        var seen = 0
        var finished = false
        while !finished {
            try autoreleasepool {
                guard let entry = try reader.next() else {
                    finished = true
                    return
                }
                guard case .file(let name, let data) = entry else { throw BackupError.badEntry }
                seen += 1
                guard wanted.contains(name) else { return }
                let target = dir.appendingPathComponent(name, isDirectory: false)
                do {
                    try data.write(to: target, options: [.atomic, .completeFileProtection])
                } catch {
                    throw AppError.message("The backup could not be unpacked. Check that your iPhone is unlocked and has free space.")
                }
                files[name] = target
            }
            progress(Double(seen) / Double(max(expected, seen, 1)))
        }
        progress(1)
        return RestoredBackup(manifest: manifest, files: files)
    }

    /// Creates a missing staging folder with complete protection and keeps it
    /// out of device backups.
    static func ensureDirectory(_ dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        }
        var folder = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}

/// Password-encrypted backup export and restore, with progress for the sheet.
/// The password is only passed through; it is never stored.
@MainActor
final class BackupService: ObservableObject {
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0

    /// Bumped at every start and end, so progress from a finished run is ignored.
    private var run = 0

    /// Writes 'ReceiptVault-<yyyy-MM-dd>.rvault' to tmp/Export: a manifest
    /// of every item, then each original (thumbnails are rebuilt on restore),
    /// then the end frame. Records the backup time and replans, which moves
    /// the backup nudge.
    func export(password: String, context: ModelContext) async throws -> URL {
        guard password.count >= BackupPassword.minimumLength else { throw BackupError.passwordTooShort }
        let token = start("Preparing the backup…")
        defer { end(token) }

        if context.hasChanges { try context.save() }
        let items = try context.fetch(FetchDescriptor<VaultItem>()).sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.uuidString < b.id.uuidString
        }
        guard !items.isEmpty else { throw AppError.message("There is nothing to back up yet.") }

        var sources: [BackupSource] = []
        var seen = Set<String>()
        for item in items {
            for file in item.sortedFiles {
                let name = file.fileName
                guard BackupEntry.isAllowedFileName(name), seen.insert(name).inserted else { continue }
                sources.append(BackupSource(name: name, url: file.url))
            }
        }
        let manifest = BackupManifest(formatVersion: BackupManifest.currentFormatVersion,
                                      createdAt: Date(),
                                      appVersion: BackupService.appVersion,
                                      items: items.map { RecordService.dto($0) })
        let json = try manifest.encoded()

        FileVault.clearExports(olderThan: 3600)
        let target = FileVault.exportURL("ReceiptVault-\(RVCalendar.today().iso).rvault")
        let files = sources
        let report = reporter(token, from: 0, to: 1)
        phase = "Encrypting your backup…"
        try await Task.detached(priority: .userInitiated) {
            try BackupJobs.write(to: target, password: password, manifest: json, files: files, progress: report)
        }.value

        AppSettings.lastBackupAt = Date()
        await NotificationScheduler.replan(context: context)
        return target
    }

    /// Restores a backup. The file is staged first unless it already waits in
    /// Staging/Incoming, then read and verified to the end in the background.
    /// Only then, on the main actor, items whose id is not here yet are
    /// inserted, with their originals under NEW local names and fresh
    /// thumbnails. Nothing is inserted from a damaged file or with a wrong
    /// password (both give the same error).
    func restore(from url: URL, password: String, context: ModelContext) async throws -> RestoreSummary {
        let token = start("Opening the backup…")
        defer { end(token) }
        if context.hasChanges { try context.save() }

        let alreadyStaged = BackupService.isInside(url, Storage.incomingDirectory)
        let staged: URL
        if alreadyStaged {
            staged = url
        } else {
            staged = try FileVault.stageIncoming(url)
        }
        var succeeded = false
        defer {
            // A copy made here always goes; a file that came in staged goes once restored.
            if succeeded || !alreadyStaged { try? FileManager.default.removeItem(at: staged) }
        }

        let current = try context.fetch(FetchDescriptor<VaultItem>())
        let existing = Set(current.map { $0.id })
        let restoreDir = Storage.restoreDirectory
        FileVault.clearDirectory(restoreDir)
        defer { FileVault.clearDirectory(restoreDir) }

        phase = "Checking the password and decrypting…"
        let report = reporter(token, from: 0, to: 0.8)
        let backup = try await Task.detached(priority: .userInitiated) {
            try BackupJobs.read(from: staged, password: password, into: restoreDir, skipping: existing, progress: report)
        }.value

        phase = "Restoring items…"
        var waiting = backup.files
        var known = existing
        var added = 0
        var skipped = 0
        var fileCount = 0
        var newNames: [String] = []
        let total = max(backup.manifest.items.count, 1)
        for (index, dto) in backup.manifest.items.enumerated() {
            if known.insert(dto.id).inserted {
                var saved: [UUID: SavedFile] = [:]
                for record in dto.files where saved[record.id] == nil {
                    guard let file = waiting.removeValue(forKey: record.fileName),
                          let restored = BackupService.adopt(file, record: record) else { continue }
                    saved[record.id] = restored
                    newNames.append(restored.fileName)
                    if !restored.thumbName.isEmpty { newNames.append(restored.thumbName) }
                    fileCount += 1
                }
                RecordService.insert(dto, files: saved, context: context)
                added += 1
            } else {
                skipped += 1
            }
            advance(0.8 + 0.2 * Double(index + 1) / Double(total), token: token)
            await Task.yield()
        }

        if added > 0 {
            do {
                try context.save()
            } catch {
                context.rollback()
                FileVault.delete(newNames)
                throw error
            }
            // The store now holds records added after any 'Delete all data',
            // so the wipe at the next launch must not remove it (restored
            // items can have no files, which the Files/ check would miss).
            AppSettings.pendingWipe = false
        }
        succeeded = true
        // Restored items count as new items with reminders: permission is
        // asked here the first time, as after a capture.
        if added > 0 && !RecordService.reminderInputs(context: context).isEmpty {
            _ = await NotificationScheduler.requestIfNeeded()
        }
        await NotificationScheduler.replan(context: context)
        return RestoreSummary(added: added, skipped: skipped, files: fileCount)
    }

    // MARK: Helpers

    /// Moves one decrypted original into Files/ under a new name and makes its
    /// thumbnail. The capture-time hash and name come from the backup record.
    private static func adopt(_ staged: URL, record: FileDTO) -> SavedFile? {
        let ext = staged.pathExtension.lowercased()
        guard let name = try? FileVault.adoptRestored(staged, ext: ext) else { return nil }
        let isPDF = ext == "pdf"
        let thumb = FileVault.makeThumbnail(for: name, isPDF: isPDF) ?? ""
        let size = (try? FileVault.url(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return SavedFile(fileName: name, thumbName: thumb, isPDF: isPDF,
                         pageCount: max(record.pageCount, 1),
                         byteCount: size ?? record.byteCount,
                         originalName: record.originalName,
                         sha256: record.sha256.lowercased())
    }

    /// True when `url` lies inside `dir`.
    private static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix)
    }

    /// '1.0 (1)', from the bundle.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private func start(_ text: String) -> Int {
        run &+= 1
        phase = text
        progress = 0
        return run
    }

    private func end(_ token: Int) {
        guard token == run else { return }
        run &+= 1
        phase = ""
        progress = 0
    }

    /// Progress only moves forward within one run.
    private func advance(_ value: Double, token: Int) {
        guard token == run else { return }
        let clamped = min(max(value, 0), 1)
        if clamped > progress { progress = clamped }
    }

    /// A callback for the background work: its 0...1 is mapped onto
    /// low...high and delivered on the main actor.
    private func reporter(_ token: Int, from low: Double, to high: Double) -> @Sendable (Double) -> Void {
        return { [self] fraction in
            let value = low + (high - low) * fraction
            Task { @MainActor in
                self.advance(value, token: token)
            }
        }
    }
}
