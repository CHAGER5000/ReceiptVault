import UIKit
import PDFKit
import CryptoKit

/// One original saved into the vault. Both names are relative to Files/.
struct SavedFile: Equatable {
    var fileName: String
    var thumbName: String
    var isPDF: Bool
    var pageCount: Int
    var byteCount: Int
    var originalName: String
    var sha256: String
}

/// Protected file storage for originals, thumbnails, incoming files and exports.
///
/// Every write uses iOS "complete" protection, so the files are encrypted
/// whenever the phone is locked. Scans and photos are drawn upright, downscaled
/// and saved once as JPEG: that first encoding is the original, and its
/// metadata (EXIF, GPS) is dropped. PDFs are kept byte for byte.
enum FileVault {
    static let maxPDFBytes = 40_000_000
    /// Long edge of a stored scan or photo, in pixels.
    static let maxLongEdge: CGFloat = 2400
    /// Long edge of a thumbnail, in pixels.
    static let thumbnailEdge: CGFloat = 360
    /// Long edge, in points, of the first-page preview of a PDF.
    static let pdfPreviewEdge: CGFloat = 1000
    static let jpegQuality: CGFloat = 0.7

    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    /// Longest file name (in UTF-8 bytes) that sanitized(_:) returns.
    private static let maxNameBytes = 200

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    // MARK: Saving originals

    /// Scans and photos: drawn upright, at most 2400 px on the long edge, JPEG at 0.7.
    static func save(image: UIImage, originalName: String) throws -> SavedFile {
        guard let upright = drawn(image, longEdge: maxLongEdge),
              let data = upright.jpegData(compressionQuality: jpegQuality) else {
            throw AppError.message("That image could not be saved.")
        }
        let fileName = UUID().uuidString + ".jpg"
        try write(data, to: fileName)
        let thumb = writeThumbnail(upright, for: fileName)
        let hash = FileVault.sha256(data: data)
        return SavedFile(fileName: fileName, thumbName: thumb ?? "", isPDF: false, pageCount: 1,
                         byteCount: data.count, originalName: originalName, sha256: hash)
    }

    /// Image files and Photos data (JPEG, PNG, HEIC).
    static func save(imageData: Data, originalName: String) throws -> SavedFile {
        guard let image = UIImage(data: imageData) else {
            throw AppError.message("That image could not be opened.")
        }
        return try save(image: image, originalName: originalName)
    }

    /// PDFs are copied byte for byte. The url is already local (staged).
    static func save(pdfAt url: URL, originalName: String) throws -> SavedFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxPDFBytes { throw tooLarge }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AppError.message("That PDF could not be opened.")
        }
        if data.count > maxPDFBytes { throw tooLarge }
        guard let document = PDFDocument(data: data) else {
            throw AppError.message("That PDF could not be opened.")
        }
        if document.isLocked {
            throw AppError.message("That PDF is password-protected. Open it in Files, remove the password and try again.")
        }
        guard document.pageCount > 0 else {
            throw AppError.message("That PDF has no pages.")
        }
        let fileName = UUID().uuidString + ".pdf"
        try write(data, to: fileName)
        var thumb: String? = nil
        if let page = document.page(at: 0), let firstPage = preview(of: page, longEdge: thumbnailEdge) {
            thumb = writeThumbnail(firstPage, for: fileName)
        }
        let hash = FileVault.sha256(data: data)
        return SavedFile(fileName: fileName, thumbName: thumb ?? "", isPDF: true, pageCount: document.pageCount,
                         byteCount: data.count, originalName: originalName, sha256: hash)
    }

    private static var tooLarge: AppError {
        AppError.message("That PDF is larger than 40 MB, which is the limit for one file.")
    }

    // MARK: Reading

    static func url(_ name: String) -> URL {
        Storage.filesDirectory.appendingPathComponent(name, isDirectory: false)
    }

    static func exists(_ name: String) -> Bool {
        !name.isEmpty && FileManager.default.fileExists(atPath: url(name).path)
    }

    /// The stored page for a JPEG; the first page for a PDF. Not cached.
    static func image(_ name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let fileURL = url(name)
        if fileURL.pathExtension.lowercased() == "pdf" {
            guard let page = PDFDocument(url: fileURL)?.page(at: 0) else { return nil }
            return preview(of: page, longEdge: pdfPreviewEdge)
        }
        return UIImage(contentsOfFile: fileURL.path)
    }

    /// A thumbnail by its name ('<base>-t.jpg'), decoded once and cached.
    static func thumbnail(_ name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let loaded = UIImage(contentsOfFile: url(name).path) else { return nil }
        let image = loaded.preparingForDisplay() ?? loaded
        cache.setObject(image, forKey: key)
        return image
    }

    /// Writes '<base>-t.jpg' next to the original and returns its name.
    @discardableResult
    static func makeThumbnail(for fileName: String, isPDF: Bool) -> String? {
        guard !fileName.isEmpty else { return nil }
        let source: UIImage?
        if isPDF {
            if let page = PDFDocument(url: url(fileName))?.page(at: 0) {
                source = preview(of: page, longEdge: thumbnailEdge)
            } else {
                source = nil
            }
        } else {
            source = UIImage(contentsOfFile: url(fileName).path)
        }
        guard let image = source else { return nil }
        return writeThumbnail(image, for: fileName)
    }

    /// Deletes originals and thumbnails by name. Only bare names are accepted,
    /// so a damaged record ('', '.', '..', 'a/b') can never remove a folder.
    static func delete(_ names: [String]) {
        for name in names where isPlainName(name) {
            try? FileManager.default.removeItem(at: url(name))
            cache.removeObject(forKey: name as NSString)
        }
    }

    // MARK: Hashes

    /// SHA-256 of the stored bytes, or nil when the file cannot be read.
    /// The file is read, not memory-mapped: a mapped file with complete
    /// protection faults (a crash, not an error) if the phone locks meanwhile.
    static func sha256(_ name: String) -> String? {
        guard !name.isEmpty,
              let data = try? Data(contentsOf: url(name)) else { return nil }
        return FileVault.sha256(data: data)
    }

    /// Lowercase hex.
    static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Incoming files

    /// Copies a picked or shared file into Staging/Incoming as '<UUID>.<ext>'
    /// with complete protection. A file that iOS put in this app's own
    /// Documents/Inbox is then removed, so it only ever waits in the protected
    /// folder. (A file picked from another app's 'Inbox' folder is left alone.)
    static func stageIncoming(_ url: URL) throws -> URL {
        try stage(url, removingSource: isInInbox(url))
    }

    /// Files waiting in Staging/Incoming, oldest first. Leftovers in
    /// Documents/Inbox are staged first.
    static func pendingIncoming() -> [URL] {
        for leftover in regularFiles(in: inboxDirectory) {
            // Always moved out (or left untouched on failure), so the same
            // leftover can never be staged twice.
            _ = try? stage(leftover, removingSource: true)
        }
        return regularFiles(in: Storage.incomingDirectory).sorted { a, b in
            let da = modified(a)
            let db = modified(b)
            if da == db { return a.lastPathComponent < b.lastPathComponent }
            return da < db
        }
    }

    /// Moves a decrypted backup file into Files/ under a new '<UUID>.<ext>'
    /// name, stamps complete protection and returns the name.
    static func adoptRestored(_ staged: URL, ext: String) throws -> String {
        let clean = ext.lowercased()
        guard clean == "jpg" || clean == "pdf" else {
            throw AppError.message("The backup contains a file that is not a JPEG or PDF.")
        }
        ensureDirectory(Storage.filesDirectory)
        let name = UUID().uuidString + "." + clean
        let destination = url(name)
        try FileManager.default.moveItem(at: staged, to: destination)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                  ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return name
    }

    // MARK: Exports

    /// SlimScan's rule: characters that are not allowed in file names become
    /// '-', and the ends are trimmed. Line breaks and control characters are
    /// treated the same way, and very long names are shortened.
    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        var cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.utf8.count > maxNameBytes {
            let rawExt = (cleaned as NSString).pathExtension
            let ext = rawExt.utf8.count <= 10 ? rawExt : ""
            var base = ext.isEmpty ? cleaned : (cleaned as NSString).deletingPathExtension
            let room = maxNameBytes - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while base.utf8.count > room && !base.isEmpty { base.removeLast() }
            base = base.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned = ext.isEmpty ? base : base + "." + ext
        }
        return cleaned.isEmpty ? "Export" : cleaned
    }

    /// Where an export is written: tmp/Export, created with complete protection.
    static func exportURL(_ fileName: String) -> URL {
        let dir = Storage.exportDirectory
        ensureDirectory(dir)
        return dir.appendingPathComponent(sanitized(fileName), isDirectory: false)
    }

    /// Deletes exports last modified more than `seconds` ago; 0 deletes them all.
    static func clearExports(olderThan seconds: TimeInterval = 0) {
        let cutoff = Date().addingTimeInterval(-seconds)
        for file in entries(in: Storage.exportDirectory) {
            if seconds <= 0 || modified(file) < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Empties a folder but keeps the folder itself.
    static func clearDirectory(_ dir: URL) {
        for entry in entries(in: dir) {
            try? FileManager.default.removeItem(at: entry)
        }
        cache.removeAllObjects()
    }

    /// Everything in the vault folder: the database, originals, thumbnails and staging.
    static func totalBytes() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: Storage.directory,
                                                          includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Helpers

    private static func write(_ data: Data, to name: String) throws {
        ensureDirectory(Storage.filesDirectory)
        do {
            try data.write(to: url(name), options: writeOptions)
        } catch {
            throw AppError.message("The file could not be saved. Check that your iPhone is unlocked and has free space.")
        }
    }

    /// Copies `url` into Staging/Incoming as '<UUID>.<ext lowercased>' with
    /// complete protection. With `removingSource` the source is deleted
    /// afterwards; when that fails the copy is deleted instead, so a file is
    /// either moved or left where it was, never staged twice.
    private static func stage(_ url: URL, removingSource: Bool) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dir = Storage.incomingDirectory
        ensureDirectory(dir, excludeFromBackup: true)
        let ext = url.pathExtension.lowercased()
        let name = ext.isEmpty ? UUID().uuidString : UUID().uuidString + "." + ext
        let destination = dir.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw AppError.message("That file could not be copied into ReceiptVault.")
        }
        // The modification date records the arrival order for pendingIncoming().
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete,
                                                   .modificationDate: Date()]
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw AppError.message("That file could not be protected, so it was not kept.")
        }
        if removingSource {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw AppError.message("That file could not be moved into ReceiptVault.")
            }
        }
        return destination
    }

    /// Where iOS copies files opened with 'Open in ReceiptVault'.
    private static var inboxDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// True for a file inside this app's own Documents/Inbox.
    private static func isInInbox(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let inbox = comparablePath(inboxDirectory) + "/"
        return comparablePath(url).hasPrefix(inbox)
    }

    /// The standardized path without the '/private' prefix iOS sometimes
    /// adds, so '/var/…' and '/private/var/…' compare equal.
    private static func comparablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = "/private/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count - 1))
    }

    /// A bare file name: not empty, no folder separator, not '.' or '..'.
    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// Creates a missing folder with complete protection.
    private static func ensureDirectory(_ dir: URL, excludeFromBackup: Bool = false) {
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        if excludeFromBackup {
            var folder = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
    }

    private static func thumbName(for fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + "-t.jpg"
    }

    /// Writes the 360 px thumbnail and returns its name, or nil on failure.
    private static func writeThumbnail(_ image: UIImage, for fileName: String) -> String? {
        let name = thumbName(for: fileName)
        guard let small = drawn(image, longEdge: thumbnailEdge),
              let data = small.jpegData(compressionQuality: jpegQuality) else { return nil }
        do {
            try data.write(to: url(name), options: writeOptions)
        } catch {
            return nil
        }
        cache.removeObject(forKey: name as NSString)
        return name
    }

    /// Draws the image upright on white at scale 1, at most `longEdge` pixels
    /// on its long side. The result carries no metadata.
    private static func drawn(_ image: UIImage, longEdge: CGFloat) -> UIImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth >= 1, pixelHeight >= 1 else { return nil }
        let factor = min(1, longEdge / max(pixelWidth, pixelHeight))
        let target = CGSize(width: max(1, floor(pixelWidth * factor)), height: max(1, floor(pixelHeight * factor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// A PDF page drawn with PDFPage.thumbnail, `longEdge` points on its long
    /// side. The crop box is the page as PDF viewers show it (it is the media
    /// box when the PDF sets none).
    private static func preview(of page: PDFPage, longEdge: CGFloat) -> UIImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = longEdge / max(bounds.width, bounds.height)
        var size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        return page.thumbnail(of: size, for: .cropBox)
    }

    /// Everything directly inside a folder, hidden files included.
    private static func entries(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
    }

    /// Visible regular files directly inside a folder.
    private static func regularFiles(in dir: URL) -> [URL] {
        entries(in: dir).filter { file in
            if file.lastPathComponent.hasPrefix(".") { return false }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
