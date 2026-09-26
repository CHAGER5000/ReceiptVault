import XCTest
import CryptoKit
@testable import ReceiptCore

// Fixtures shared by the backup tests. 1,000 PBKDF2 iterations (read back
// with minimumIterations 1,000) keep every test fast; passwords are at least
// 10 characters, as the writer requires.
private let testPassword = "correct horse battery"
private let testIterations: UInt32 = 1_000
private let jpgName = "3F2504E0-4F89-11D3-9A0C-0305E82C3301.jpg"
private let pdfName = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11.pdf"

/// A JPEG-looking original, big enough to need several reads.
private let sampleJPEG: Data = {
    var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
    bytes.append(contentsOf: (0..<200_000).map { i in UInt8(truncatingIfNeeded: i &* 7 &+ 3) })
    return Data(bytes)
}()

private let samplePDF = Data("%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n".utf8)

/// Backup (.rvault) and TextExport. Backups go to temporary files that are
/// deleted after each test. Fixed dates only (never Date() for today), and
/// amounts are compared as Money.plain text, never Money.format.
final class BackupExportTests: XCTestCase {
    // MARK: - Helpers

    /// A fresh file URL in the temporary folder, deleted after the test.
    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptVaultTests-\(UUID().uuidString)")
            .appendingPathExtension("rvault")
        addTeardownBlock {
            _ = try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Lowercase hex, two digits per byte.
    private func hex(_ b: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(b.count * 2)
        for byte in b {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    /// The BackupError that `body` throws; nil when it succeeds or throws something else.
    private func backupError(_ body: () throws -> Void) -> BackupError? {
        do {
            try body()
        } catch let error as BackupError {
            return error
        } catch {
            return nil
        }
        return nil
    }

    /// The value's bytes, most significant first.
    private func beBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        let size = T.bitWidth / 8
        return (0..<size).map { i in UInt8(truncatingIfNeeded: value >> ((size - 1 - i) * 8)) }
    }

    /// Writes raw bytes to a fresh temporary file.
    private func saved(_ bytes: [UInt8]) throws -> URL {
        let url = tempURL()
        try Data(bytes).write(to: url)
        return url
    }

    /// A finished backup of `entries` at 1,000 iterations.
    private func writeBackup(_ entries: [BackupEntry], password: String = testPassword) throws -> URL {
        let url = tempURL()
        let writer = try BackupWriter(url: url, password: password, iterations: testIterations)
        for entry in entries { try writer.append(entry) }
        try writer.finish()
        return url
    }

    /// Every entry up to the verified end frame.
    private func readAll(_ url: URL, password: String = testPassword) throws -> [BackupEntry] {
        let reader = try BackupReader(url: url, password: password, minimumIterations: testIterations)
        defer { reader.close() }
        var out: [BackupEntry] = []
        while let entry = try reader.next() { out.append(entry) }
        return out
    }

    /// The header, then each frame with its 4-byte length prefix.
    private func pieces(_ url: URL) throws -> [[UInt8]] {
        let bytes = try [UInt8](Data(contentsOf: url))
        var out: [[UInt8]] = [Array(bytes.prefix(BackupHeader.size))]
        var i = BackupHeader.size
        while i + 4 <= bytes.count {
            let length = bytes[i..<(i + 4)].reduce(0) { (acc: Int, b: UInt8) in (acc << 8) | Int(b) }
            let end = min(i + 4 + length, bytes.count)
            out.append(Array(bytes[i..<end]))
            i = end
        }
        return out
    }

    /// True when `needle` appears somewhere in `hay`.
    private func occurs(_ needle: [UInt8], in hay: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            if Array(hay[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private func uuid(_ s: String) -> UUID {
        UUID(uuidString: s)!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DayDate {
        DayDate(year: y, month: m, day: d)
    }

    /// Whole seconds, so the default JSON date strategy round-trips exactly.
    private let stamp = Date(timeIntervalSince1970: 1_741_780_320) // 2025-03-12 11:52:00 UTC

    /// A receipt with every field filled, one deadline and one file.
    private func fullItem() -> ItemDTO {
        let deadline = DeadlineDTO(id: uuid("7C9E6679-7425-40DE-944B-E07FC1F90AE7"),
                                   kind: DeadlineKind.returnWindow.rawValue,
                                   date: day(2025, 4, 9),
                                   label: "",
                                   remindersOn: true,
                                   offsets: [7, 1],
                                   isDone: false,
                                   basis: "Printed on the receipt: 28 days",
                                   certainty: Certainty.printed.rawValue)
        let file = FileDTO(id: uuid("3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
                           fileName: jpgName,
                           isPDF: false,
                           pageCount: 1,
                           byteCount: sampleJPEG.count,
                           originalName: "Receipt.jpg",
                           sha256: String(repeating: "ab", count: 32),
                           source: FileSource.scan.rawValue,
                           capturedAt: stamp,
                           capturedTimeZone: "Europe/London",
                           sortIndex: 0)
        return ItemDTO(id: uuid("6F9619FF-8B86-D011-B42D-00C04FC964FF"),
                       kind: ItemKind.receipt.rawValue,
                       title: "Samsung TV",
                       merchant: "Currys PC World",
                       purchaseDate: day(2025, 3, 12),
                       deliveryDate: day(2025, 3, 14),
                       totalMinor: 24_900,
                       currency: "GBP",
                       vatMinor: 4_150,
                       vatRatePermille: 200,
                       jurisdiction: Jurisdiction.englandWales.rawValue,
                       channel: PurchaseChannel.store.rawValue,
                       category: ProductCategory.electronics.rawValue,
                       taxTag: TaxTag.none.rawValue,
                       isUsed: false,
                       hasIssue: true,
                       issueNotedAt: stamp.addingTimeInterval(30 * 86_400),
                       returnDays: 28,
                       returnDaysIsPrinted: true,
                       warrantyMonths: 24,
                       warrantyIsPrinted: false,
                       contractPresetID: "",
                       termEnd: day(2026, 3, 11),
                       autoRenews: true,
                       renewalMonths: 12,
                       notice: NoticePeriod(value: 3, unit: .months),
                       cancelled: false,
                       noticeSentAt: stamp.addingTimeInterval(60 * 86_400),
                       itemLines: "55\" TV\t1\t24900",
                       notes: "Box kept in the loft",
                       ocrText: "CURRYS\nTOTAL £249.00",
                       needsReview: true,
                       checkFields: "total,date",
                       createdAt: stamp,
                       updatedAt: stamp.addingTimeInterval(3_600),
                       deadlines: [deadline],
                       files: [file])
    }

    /// An item with every optional left nil and no deadlines or files.
    private func bareItem() -> ItemDTO {
        ItemDTO(id: uuid("00000000-0000-0000-0000-000000000001"),
                kind: ItemKind.receipt.rawValue,
                title: "",
                merchant: "",
                purchaseDate: day(2025, 3, 12),
                deliveryDate: nil,
                totalMinor: nil,
                currency: "GBP",
                vatMinor: nil,
                vatRatePermille: nil,
                jurisdiction: Jurisdiction.englandWales.rawValue,
                channel: PurchaseChannel.store.rawValue,
                category: ProductCategory.otherGoods.rawValue,
                taxTag: TaxTag.none.rawValue,
                isUsed: false,
                hasIssue: false,
                issueNotedAt: nil,
                returnDays: nil,
                returnDaysIsPrinted: false,
                warrantyMonths: nil,
                warrantyIsPrinted: false,
                contractPresetID: "",
                termEnd: nil,
                autoRenews: true,
                renewalMonths: 12,
                notice: NoticePeriod(value: 3, unit: .months),
                cancelled: false,
                noticeSentAt: nil,
                itemLines: "",
                notes: "",
                ocrText: "",
                needsReview: false,
                checkFields: "",
                createdAt: stamp,
                updatedAt: stamp,
                deadlines: [],
                files: [])
    }

    private func sampleManifest() -> BackupManifest {
        BackupManifest(formatVersion: BackupManifest.currentFormatVersion,
                       createdAt: stamp,
                       appVersion: "1.0 (1)",
                       items: [fullItem()])
    }

    /// Manifest, then a JPEG and a PDF.
    private func sampleEntries() throws -> [BackupEntry] {
        let json = try sampleManifest().encoded()
        return [BackupEntry.manifest(json),
                BackupEntry.file(name: jpgName, data: sampleJPEG),
                BackupEntry.file(name: pdfName, data: samplePDF)]
    }

    /// Parses `query` and matches it against `blob`.
    private func finds(_ query: String, _ blob: String, total: Int64? = nil) -> Bool {
        SearchText.matches(SearchText.parse(query), blob: blob, totalMinor: total)
    }

    private let goodHash = String(repeating: "ab", count: 32)
    private let badHash = String(repeating: "cd", count: 32)

    /// A faulty TV with three key dates and two files, one of which has changed.
    private func evidenceInput() -> EvidenceInput {
        EvidenceInput(
            title: "Samsung TV",
            merchant: "Currys",
            kind: ItemKind.receipt,
            purchaseDate: day(2025, 3, 12),
            deliveryDate: day(2025, 3, 14),
            totalMinor: 24_900,
            currency: "GBP",
            vatMinor: 4_150,
            vatRatePermille: 200,
            items: [ItemLine(name: "USB-C cable", quantity: 2, amountMinor: 1_998),
                    ItemLine(name: "55\" TV", quantity: 1, amountMinor: 22_902)],
            jurisdiction: Jurisdiction.englandWales,
            channel: PurchaseChannel.store,
            hasIssue: true,
            issueNoted: day(2025, 3, 30),
            dates: [EvidenceDate(label: "Legal guarantee ends", date: day(2031, 3, 11), certainty: Certainty.law),
                    EvidenceDate(label: "Return by", date: day(2025, 4, 9), certainty: Certainty.printed),
                    EvidenceDate(label: "Cancel by", date: day(2025, 3, 26), certainty: Certainty.law)],
            notes: "Screen flickers after an hour.\n\nBox kept.",
            files: [EvidenceFile(name: "Receipt.jpg", pages: 1, sha256: goodHash,
                                 capturedAt: "12 Mar 2025, 14:32 (Europe/London)",
                                 source: FileSource.scan.label, matchesCapture: true),
                    EvidenceFile(name: "Invoice.pdf", pages: 2, sha256: badHash,
                                 capturedAt: "14 Mar 2025, 09:05 (Europe/London)",
                                 source: FileSource.files.label, matchesCapture: false)])
    }

    // MARK: - Key derivation

    /// RFC 7914 / RFC 6070-style vectors for PBKDF2-HMAC-SHA256, checked with Python hashlib.
    func testPBKDF2KnownAnswers() throws {
        let salt = Array("salt".utf8)
        XCTAssertEqual(hex(try BackupCrypto.pbkdf2SHA256(password: "passwd", salt: salt, iterations: 1, length: 64)),
                       "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        XCTAssertEqual(hex(try BackupCrypto.pbkdf2SHA256(password: "password", salt: salt, iterations: 1)),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(try BackupCrypto.pbkdf2SHA256(password: "password", salt: salt, iterations: 4_096)),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(try BackupCrypto.pbkdf2SHA256(password: "password", salt: salt, iterations: 1, length: 16).count, 16)

        XCTAssertEqual(backupError { _ = try BackupCrypto.pbkdf2SHA256(password: "password", salt: salt, iterations: 0) },
                       BackupError.keyDerivationFailed)
        XCTAssertEqual(backupError { _ = try BackupCrypto.pbkdf2SHA256(password: "password", salt: salt, iterations: 1, length: 0) },
                       BackupError.keyDerivationFailed)
    }

    /// The file key is PBKDF2 (32 bytes) then HKDF-SHA256 with the same salt and
    /// the info 'ReceiptVault backup v1'. Expected values computed with Python hashlib and hmac.
    func testBackupKeyKnownAnswer() throws {
        let salt: [UInt8] = (0..<16).map { UInt8($0) }
        let header = BackupHeader(version: 1, kdf: 1, iterations: testIterations, salt: salt)
        XCTAssertEqual(hex(try BackupCrypto.pbkdf2SHA256(password: testPassword, salt: salt, iterations: testIterations)),
                       "02169e674d80c0fc7292e8610c8f17be140df062af9aa33ea85eaabecffdf08d")
        let key = try BackupCrypto.key(password: testPassword, header: header)
        let keyBytes: [UInt8] = key.withUnsafeBytes { Array($0) }
        XCTAssertEqual(key.bitCount, 256)
        XCTAssertEqual(hex(keyBytes), "0195b5cedbc572263e6b01f982939ccca9ffa67adf8bed4cb402dfce2c01ac31")
    }

    /// A password typed with composed or decomposed accents opens the same backup.
    func testNFCandNFDPasswordsGiveSameKey() throws {
        let nfc = "Cr\u{00E8}me br\u{00FB}l\u{00E9}e 2025"
        let nfd = "Cre\u{0300}me bru\u{0302}le\u{0301}e 2025"
        // Swift already compares them as equal, but their bytes differ.
        XCTAssertEqual(nfc, nfd)
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))

        let salt = [UInt8](repeating: 0x5A, count: 16)
        let a = try BackupCrypto.pbkdf2SHA256(password: nfc, salt: salt, iterations: testIterations)
        let b = try BackupCrypto.pbkdf2SHA256(password: nfd, salt: salt, iterations: testIterations)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, try BackupCrypto.pbkdf2SHA256(password: "Creme brulee 2025", salt: salt, iterations: testIterations))

        let header = BackupHeader.make(iterations: testIterations)
        let k1: [UInt8] = try BackupCrypto.key(password: nfc, header: header).withUnsafeBytes { Array($0) }
        let k2: [UInt8] = try BackupCrypto.key(password: nfd, header: header).withUnsafeBytes { Array($0) }
        XCTAssertEqual(k1, k2)

        // Written with one spelling, read with the other.
        let url = try writeBackup(try sampleEntries(), password: nfd)
        XCTAssertEqual(try readAll(url, password: nfc), try sampleEntries())
    }

    // MARK: - Round trip

    func testRoundTripManifestAndFiles() throws {
        let url = tempURL()
        let manifest = sampleManifest()
        let json = try manifest.encoded()
        let writer = try BackupWriter(url: url, password: testPassword, iterations: testIterations)
        try writer.append(BackupEntry.manifest(json))
        try writer.append(BackupEntry.file(name: jpgName, data: sampleJPEG))
        try writer.append(BackupEntry.file(name: pdfName, data: samplePDF))
        try writer.finish()

        let reader = try BackupReader(url: url, password: testPassword, minimumIterations: testIterations)
        XCTAssertEqual(reader.header, writer.header)
        XCTAssertEqual(reader.header.iterations, testIterations)
        XCTAssertEqual(try reader.next(), BackupEntry.manifest(json))
        XCTAssertEqual(try reader.next(), BackupEntry.file(name: jpgName, data: sampleJPEG))
        XCTAssertEqual(try reader.next(), BackupEntry.file(name: pdfName, data: samplePDF))
        XCTAssertNil(try reader.next())
        XCTAssertNil(try reader.next()) // stays at the end; .end is never returned
        reader.close()

        XCTAssertEqual(try BackupManifest.decode(json), manifest)

        // Nothing readable is left on disk.
        let onDisk = try [UInt8](Data(contentsOf: url))
        XCTAssertEqual(Array(onDisk.prefix(4)), BackupHeader.magic)
        XCTAssertFalse(occurs(Array("Currys PC World".utf8), in: onDisk))
        XCTAssertFalse(occurs(Array("%PDF-1.7".utf8), in: onDisk))
        XCTAssertFalse(occurs(Array("appVersion".utf8), in: onDisk))

        // A backup of the manifest alone is valid too.
        let small = try writeBackup([BackupEntry.manifest(json)])
        XCTAssertEqual(try readAll(small), [BackupEntry.manifest(json)])
    }

    /// The bytes on disk follow the documented layout, checked with CryptoKit directly.
    func testFrameLayoutMatchesTheFormat() throws {
        let json = try sampleManifest().encoded()
        let p = try pieces(try writeBackup(try sampleEntries()))
        XCTAssertEqual(p.count, 5) // header, manifest, 2 files, end
        XCTAssertEqual(p[0].count, BackupHeader.size)
        XCTAssertEqual(Array(p[0][0..<8]), [0x52, 0x56, 0x4C, 0x54, 1, 1, 0, 0])
        XCTAssertEqual(Array(p[0][8..<12]), beBytes(testIterations))
        XCTAssertEqual(Array(p[0][28..<32]), [0, 0, 0, 0])

        // length (4) | nonce (12) | ciphertext | tag (16); a file entry adds
        // type (1), name length (2) and the 40-byte name.
        let overhead = 32
        let fileHead = 43
        XCTAssertEqual(p[1].count, overhead + 1 + json.count)
        XCTAssertEqual(p[2].count, overhead + fileHead + sampleJPEG.count)
        XCTAssertEqual(p[3].count, overhead + fileHead + samplePDF.count)
        XCTAssertEqual(p[4].count, overhead + 9)
        for frame in p.dropFirst() {
            XCTAssertEqual(Array(frame[0..<4]), beBytes(UInt32(frame.count - 4)))
        }

        // AAD = header bytes + UInt64 BE frame index.
        let header = try BackupHeader.parse(Data(p[0]))
        let key = try BackupCrypto.key(password: testPassword, header: header)
        let manifestBox = try AES.GCM.SealedBox(combined: Data(p[1][4...]))
        let manifestPlain = try [UInt8](AES.GCM.open(manifestBox, using: key, authenticating: header.bytes + beBytes(UInt64(0))))
        XCTAssertEqual(manifestPlain.first, 1)
        XCTAssertEqual(try BackupManifest.decode(Data(manifestPlain.dropFirst())), sampleManifest())

        let fileBox = try AES.GCM.SealedBox(combined: Data(p[3][4...]))
        let filePlain = try [UInt8](AES.GCM.open(fileBox, using: key, authenticating: header.bytes + beBytes(UInt64(2))))
        XCTAssertEqual(Array(filePlain.prefix(3)), [2, 0, 40])
        XCTAssertEqual(String(decoding: filePlain[3..<43], as: UTF8.self), pdfName)
        XCTAssertEqual(Data(filePlain[43...]), samplePDF)

        let endBox = try AES.GCM.SealedBox(combined: Data(p[4][4...]))
        let endPlain = try [UInt8](AES.GCM.open(endBox, using: key, authenticating: header.bytes + beBytes(UInt64(3))))
        XCTAssertEqual(hex(endPlain), "030000000000000003")
    }

    func testEntryEncoding() throws {
        let entries = [BackupEntry.manifest(Data("{}".utf8)),
                       BackupEntry.file(name: jpgName, data: Data([1, 2, 3])),
                       BackupEntry.file(name: pdfName, data: Data()),
                       BackupEntry.end(frames: 3)]
        for entry in entries {
            XCTAssertEqual(try BackupEntry.decode(entry.encoded()), entry)
        }
        XCTAssertEqual(hex([UInt8](BackupEntry.end(frames: 3).encoded())), "030000000000000003")
        XCTAssertEqual(hex([UInt8](BackupEntry.file(name: "a", data: Data([0xFF])).encoded())), "02000161ff")
        XCTAssertEqual(hex([UInt8](BackupEntry.manifest(Data("{}".utf8)).encoded())), "017b7d")

        let malformed: [[UInt8]] = [[], [9], [2, 0], [2, 0, 5, 0x61], [3, 0, 0, 0]]
        for bytes in malformed {
            XCTAssertEqual(backupError { _ = try BackupEntry.decode(Data(bytes)) }, BackupError.badEntry, hex(bytes))
        }
    }

    // MARK: - Wrong password and tampering

    func testWrongPasswordFails() throws {
        let url = try writeBackup(try sampleEntries())
        let reader = try BackupReader(url: url, password: "correct horse battery staple", minimumIterations: testIterations)
        XCTAssertEqual(backupError { _ = try reader.next() }, BackupError.wrongPasswordOrDamaged)
        XCTAssertEqual(backupError { _ = try reader.next() }, BackupError.wrongPasswordOrDamaged) // stays failed

        // Case and spaces matter; nothing is trimmed.
        for wrong in ["Correct horse battery", "correct horse battery ", "correcthorsebattery"] {
            XCTAssertEqual(backupError { _ = try readAll(url, password: wrong) }, BackupError.wrongPasswordOrDamaged, wrong)
        }
        XCTAssertEqual(BackupError.wrongPasswordOrDamaged.errorDescription, "Wrong password or damaged file.")

        // The right password still works.
        XCTAssertEqual(try readAll(url), try sampleEntries())
    }

    func testFlippedCiphertextByteFails() throws {
        let url = try writeBackup(try sampleEntries())
        let original = try [UInt8](Data(contentsOf: url))
        let p = try pieces(url)

        // First nonce byte, first ciphertext byte and last tag byte of every frame.
        var offsets: [Int] = []
        var start = BackupHeader.size
        for frame in p.dropFirst() {
            offsets.append(start + 4)
            offsets.append(start + 4 + 12)
            offsets.append(start + frame.count - 1)
            start += frame.count
        }
        XCTAssertEqual(start, original.count)

        for offset in offsets {
            var bytes = original
            bytes[offset] ^= 0x01
            let damaged = try saved(bytes)
            XCTAssertEqual(backupError { _ = try readAll(damaged) }, BackupError.wrongPasswordOrDamaged, "offset \(offset)")
        }

        // A changed length prefix misaligns the frame: always an error.
        start = BackupHeader.size
        for frame in p.dropFirst() {
            var bytes = original
            bytes[start + 3] ^= 0x01
            let damaged = try saved(bytes)
            XCTAssertNotNil(backupError { _ = try readAll(damaged) }, "length at \(start)")
            start += frame.count
        }
    }

    /// Every header byte is checked or authenticated, so any change fails.
    func testFlippedHeaderByteFails() throws {
        let url = try writeBackup(try sampleEntries())
        let original = try [UInt8](Data(contentsOf: url))
        // 1,000 iterations = 00 00 03 E8 in bytes 8...11.
        let expected: [Int: BackupError] = [
            0: .badHeader,                // magic
            4: .unsupportedVersion(0),    // version
            5: .badHeader,                // KDF id
            6: .badHeader,                // reserved
            8: .weakParameters,           // 16,778,216 iterations
            10: .weakParameters,          // 744 iterations
            11: .wrongPasswordOrDamaged,  // 1,001 iterations: another key
            12: .wrongPasswordOrDamaged,  // salt
            27: .wrongPasswordOrDamaged,  // salt
            31: .badHeader,               // reserved
        ]
        for i in 0..<BackupHeader.size {
            var bytes = original
            bytes[i] ^= 0x01
            let damaged = try saved(bytes)
            let error = backupError { _ = try readAll(damaged) }
            XCTAssertNotNil(error, "byte \(i)")
            if let want = expected[i] {
                XCTAssertEqual(error, want, "byte \(i)")
            }
        }
    }

    func testTruncatedFails() throws {
        let url = try writeBackup(try sampleEntries())
        let original = try [UInt8](Data(contentsOf: url))
        let p = try pieces(url)
        let endStart = original.count - p[4].count
        let cuts = [
            20,                                   // inside the header
            BackupHeader.size,                    // header only
            BackupHeader.size + 2,                // inside a length prefix
            BackupHeader.size + 4 + 10,           // inside the manifest frame
            BackupHeader.size + p[1].count,       // after the manifest
            BackupHeader.size + p[1].count + 500, // inside the JPEG
            endStart,                             // end frame missing
            endStart + 3,                         // inside the end frame's length
            original.count - 1,                   // last tag byte missing
        ]
        for cut in cuts {
            let short = try saved(Array(original.prefix(cut)))
            XCTAssertEqual(backupError { _ = try readAll(short) }, BackupError.truncated, "cut at \(cut)")
        }
    }

    func testReorderedFramesFail() throws {
        let entries = try sampleEntries()
        let p = try pieces(try writeBackup(entries))
        let q = try pieces(try writeBackup(entries)) // same password, other salt
        XCTAssertEqual(p.count, 5)

        let variants: [[[UInt8]]] = [
            [p[0], p[1], p[3], p[2], p[4]],       // files swapped
            [p[0], p[2], p[1], p[3], p[4]],       // manifest moved
            [p[0], p[1], p[3], p[4]],             // a file dropped
            [p[0], p[1], p[2], p[2], p[3], p[4]], // a file repeated
            [p[0], p[1], q[2], p[3], p[4]],       // a frame from another backup
            [q[0], p[1], p[2], p[3], p[4]],       // another backup's header
        ]
        for (i, parts) in variants.enumerated() {
            let url = try saved(parts.flatMap { $0 })
            XCTAssertEqual(backupError { _ = try readAll(url) }, BackupError.wrongPasswordOrDamaged, "variant \(i)")
        }
        // Unchanged, the pieces still make a valid backup.
        XCTAssertEqual(try readAll(try saved(p.flatMap { $0 })), entries)

        // A frame opens only at its own index and under its own header.
        let header = BackupHeader.make(iterations: testIterations)
        let key = try BackupCrypto.key(password: testPassword, header: header)
        let plain = Data("frame".utf8)
        let sealed = try [UInt8](BackupCrypto.sealFrame(plain, index: 3, header: header, key: key))
        let body = Data(sealed.dropFirst(4))
        XCTAssertEqual(try BackupCrypto.openFrame(body, index: 3, header: header, key: key), plain)
        XCTAssertEqual(backupError { _ = try BackupCrypto.openFrame(body, index: 4, header: header, key: key) },
                       BackupError.wrongPasswordOrDamaged)
        let other = BackupHeader.make(iterations: testIterations)
        XCTAssertEqual(backupError { _ = try BackupCrypto.openFrame(body, index: 3, header: other, key: key) },
                       BackupError.wrongPasswordOrDamaged)
        XCTAssertEqual(backupError { _ = try BackupCrypto.openFrame(Data(count: 27), index: 3, header: header, key: key) },
                       BackupError.wrongPasswordOrDamaged)
    }

    /// The end frame must carry the right count and be the last thing in the file.
    func testTrailingBytesAfterEndFail() throws {
        let entries = try sampleEntries()
        let url = try writeBackup(entries)
        let original = try [UInt8](Data(contentsOf: url))
        let p = try pieces(url)

        let oneByte = try saved(original + [0x00])
        XCTAssertEqual(backupError { _ = try readAll(oneByte) }, BackupError.wrongPasswordOrDamaged)
        let secondEnd = try saved(original + p[4])
        XCTAssertEqual(backupError { _ = try readAll(secondEnd) }, BackupError.wrongPasswordOrDamaged)

        // Frames sealed with the real key (as only the owner could).
        let header = try BackupHeader.parse(Data(p[0]))
        let key = try BackupCrypto.key(password: testPassword, header: header)
        func end(_ frames: UInt64, at index: UInt64) throws -> [UInt8] {
            try [UInt8](BackupCrypto.sealFrame(BackupEntry.end(frames: frames).encoded(), index: index, header: header, key: key))
        }

        // A correct re-sealed end frame reads fine, so the failures below are about the count and position.
        let rightEnd = try end(3, at: 3)
        let resealed = try saved([p[0], p[1], p[2], p[3], rightEnd].flatMap { $0 })
        XCTAssertEqual(try readAll(resealed), entries)

        let wrongEnd = try end(2, at: 3)
        let wrongCount = try saved([p[0], p[1], p[2], p[3], wrongEnd].flatMap { $0 })
        XCTAssertEqual(backupError { _ = try readAll(wrongCount) }, BackupError.wrongPasswordOrDamaged)

        let earlyEnd = try end(1, at: 1)
        let manifestOnly = try saved([p[0], p[1], earlyEnd].flatMap { $0 })
        XCTAssertEqual(try readAll(manifestOnly), [entries[0]])
        let afterEarlyEnd = try saved([p[0], p[1], earlyEnd, p[2], p[3], p[4]].flatMap { $0 })
        XCTAssertEqual(backupError { _ = try readAll(afterEarlyEnd) }, BackupError.wrongPasswordOrDamaged)
    }

    // MARK: - Header and limits

    func testBadMagicAndUnsupportedVersion() throws {
        let good = BackupHeader.make(iterations: testIterations)
        XCTAssertEqual(good.bytes.count, BackupHeader.size)
        XCTAssertEqual(BackupHeader.magic, Array("RVLT".utf8))
        XCTAssertEqual(Array(good.bytes.prefix(4)), BackupHeader.magic)
        XCTAssertEqual(try BackupHeader.parse(Data(good.bytes)), good)

        var badMagic = good.bytes
        badMagic[3] = 0x58 // 'RVLX'
        XCTAssertEqual(backupError { _ = try BackupHeader.parse(Data(badMagic)) }, BackupError.badHeader)
        var version2 = good.bytes
        version2[4] = 2
        XCTAssertEqual(backupError { _ = try BackupHeader.parse(Data(version2)) }, BackupError.unsupportedVersion(2))
        var kdf2 = good.bytes
        kdf2[5] = 2
        XCTAssertEqual(backupError { _ = try BackupHeader.parse(Data(kdf2)) }, BackupError.badHeader)

        // Whole files through the reader.
        let original = try [UInt8](Data(contentsOf: try writeBackup(try sampleEntries())))
        var v2 = original
        v2[4] = 2
        let v2URL = try saved(v2)
        XCTAssertEqual(backupError { _ = try readAll(v2URL) }, BackupError.unsupportedVersion(2))
        var zipBytes = original
        zipBytes.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x03, 0x04])
        let zipURL = try saved(zipBytes)
        XCTAssertEqual(backupError { _ = try readAll(zipURL) }, BackupError.badHeader)
        let csvURL = try saved(Array("Date,Merchant,Total\n2025-03-12,Currys,249.00\n".utf8))
        XCTAssertEqual(backupError { _ = try readAll(csvURL) }, BackupError.badHeader)
        let emptyURL = try saved([])
        XCTAssertEqual(backupError { _ = try readAll(emptyURL) }, BackupError.badHeader)

        XCTAssertNotNil(BackupError.unsupportedVersion(2).errorDescription)
        XCTAssertEqual(BackupError.badHeader.errorDescription, "This file is not a ReceiptVault backup.")
    }

    func testIterationsOutOfRangeRejected() throws {
        XCTAssertGreaterThanOrEqual(BackupCrypto.defaultIterations, 100_000)
        XCTAssertLessThanOrEqual(BackupCrypto.defaultIterations, 10_000_000)

        // Written at 1,000: below the default floor of 100,000.
        let url = try writeBackup(try sampleEntries())
        XCTAssertEqual(backupError { _ = try BackupReader(url: url, password: testPassword) }, BackupError.weakParameters)
        XCTAssertEqual(backupError { _ = try BackupReader(url: url, password: testPassword, minimumIterations: 1_001) },
                       BackupError.weakParameters)
        XCTAssertEqual(backupError { _ = try BackupReader(url: url, password: testPassword, minimumIterations: 1, maximumIterations: 999) },
                       BackupError.weakParameters)
        XCTAssertNoThrow(try BackupReader(url: url, password: testPassword, minimumIterations: 1_000, maximumIterations: 1_000))

        // Crafted headers are refused before any key is derived: 20 million
        // iterations would take seconds, a refusal takes microseconds.
        let salt = [UInt8](repeating: 7, count: 16)
        let counts: [UInt32] = [0, 99_999, 10_000_001, 20_000_000]
        let started = Date()
        for count in counts {
            let header = BackupHeader(version: 1, kdf: 1, iterations: count, salt: salt)
            let crafted = try saved(header.bytes)
            XCTAssertEqual(backupError { _ = try BackupReader(url: crafted, password: testPassword) },
                           BackupError.weakParameters, "\(count) iterations")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)

        // The default floor itself is accepted.
        let floorURL = try saved(BackupHeader(version: 1, kdf: 1, iterations: 100_000, salt: salt).bytes)
        let reader = try BackupReader(url: floorURL, password: testPassword)
        XCTAssertEqual(backupError { _ = try reader.next() }, BackupError.truncated)
    }

    /// Lengths are checked before anything that size is read: an oversize
    /// length fails as damaged, not as a short read.
    func testOversizeFrameLengthRejectedWithoutAllocating() throws {
        XCTAssertEqual(BackupCrypto.maxFrameBytes, 48 * 1_048_576 + 28)
        let header = BackupHeader.make(iterations: testIterations)
        let tail = [UInt8](repeating: 0xAB, count: 64)

        let rejected: [UInt32] = [UInt32(BackupCrypto.maxFrameBytes + 1), UInt32.max, 0, 27]
        for length in rejected {
            let url = try saved([header.bytes, beBytes(length), tail].flatMap { $0 })
            let reader = try BackupReader(url: url, password: testPassword, minimumIterations: testIterations)
            XCTAssertEqual(backupError { _ = try reader.next() }, BackupError.wrongPasswordOrDamaged, "length \(length)")
        }

        // The largest allowed length passes the check, then the short file shows.
        let url = try saved([header.bytes, beBytes(UInt32(BackupCrypto.maxFrameBytes)), tail].flatMap { $0 })
        let reader = try BackupReader(url: url, password: testPassword, minimumIterations: testIterations)
        XCTAssertEqual(backupError { _ = try reader.next() }, BackupError.truncated)
    }

    // MARK: - Entry rules

    func testFileNameAllowList() throws {
        let base = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let jpg = base + ".jpg"
        XCTAssertTrue(BackupEntry.isAllowedFileName(jpg))
        XCTAssertTrue(BackupEntry.isAllowedFileName(base.lowercased() + ".pdf"))
        XCTAssertTrue(BackupEntry.isAllowedFileName(UUID().uuidString + ".jpg"))
        XCTAssertTrue(BackupEntry.isAllowedFileName(pdfName))

        let sixtyFourHex = String(repeating: "a", count: 64)
        let noDashes = base.replacingOccurrences(of: "-", with: "")
        let rejected: [String] = [
            "../x.jpg", "/etc/x", "x.exe", sixtyFourHex, "", base, noDashes,
            "3F2504E0-4F89-11D3-9A0C-0305E82C330G.jpg",
            "3F2504E0/4F89-11D3-9A0C-0305E82C3301.jpg",
        ]
        for name in rejected {
            XCTAssertFalse(BackupEntry.isAllowedFileName(name), name)
        }
        for suffix in [".png", ".JPG", ".jpeg", ".jpg\n", ".jpg.exe"] {
            XCTAssertFalse(BackupEntry.isAllowedFileName(base + suffix), suffix)
        }
        for prefix in [" ", "../", "/", "Files/"] {
            XCTAssertFalse(BackupEntry.isAllowedFileName(prefix + jpg), prefix)
        }
        XCTAssertFalse(BackupEntry.isAllowedFileName(sixtyFourHex + ".jpg"))
        XCTAssertFalse(BackupEntry.isAllowedFileName(noDashes + ".jpg"))

        // The reader applies the list to every file entry.
        let json = try sampleManifest().encoded()
        for name in ["../evil.jpg", sixtyFourHex + ".jpg", "x.exe"] {
            let url = try writeBackup([BackupEntry.manifest(json), BackupEntry.file(name: name, data: Data([1]))])
            XCTAssertEqual(backupError { _ = try readAll(url) }, BackupError.badEntry, name)
        }
    }

    func testManifestMustComeFirst() throws {
        let json = try sampleManifest().encoded()
        let fileFirst = try writeBackup([BackupEntry.file(name: jpgName, data: samplePDF), BackupEntry.manifest(json)])
        XCTAssertEqual(backupError { _ = try readAll(fileFirst) }, BackupError.badEntry)
        let twoManifests = try writeBackup([BackupEntry.manifest(json), BackupEntry.manifest(json)])
        XCTAssertEqual(backupError { _ = try readAll(twoManifests) }, BackupError.badEntry)
        let nothing = try writeBackup([])
        XCTAssertEqual(backupError { _ = try readAll(nothing) }, BackupError.badEntry)
    }

    func testFreshSaltAndNoncesEachTime() throws {
        let entries = try sampleEntries()
        let a = try pieces(try writeBackup(entries))
        let b = try pieces(try writeBackup(entries))
        XCTAssertEqual(Array(a[0][0..<12]), Array(b[0][0..<12]))    // magic, version, KDF, iterations
        XCTAssertNotEqual(Array(a[0][12..<28]), Array(b[0][12..<28])) // salt
        XCTAssertEqual(a.count, b.count)
        for i in 1..<min(a.count, b.count) {
            XCTAssertNotEqual(a[i], b[i], "frame \(i)")
        }
        let nonces = (Array(a.dropFirst()) + Array(b.dropFirst())).map { hex(Array($0[4..<16])) }
        XCTAssertEqual(Set(nonces).count, nonces.count)

        let salts = (0..<10).map { _ in hex(BackupHeader.make(iterations: testIterations).salt) }
        XCTAssertEqual(Set(salts).count, salts.count)
        XCTAssertFalse(salts.contains(String(repeating: "0", count: 32)))

        // The same plain text at the same index seals differently each time.
        let header = BackupHeader.make(iterations: testIterations)
        let key = try BackupCrypto.key(password: testPassword, header: header)
        let plain = Data("same plain text".utf8)
        let s1 = try [UInt8](BackupCrypto.sealFrame(plain, index: 0, header: header, key: key))
        let s2 = try [UInt8](BackupCrypto.sealFrame(plain, index: 0, header: header, key: key))
        XCTAssertEqual(s1.count, 4 + 12 + plain.count + 16)
        XCTAssertEqual(Array(s1[0..<4]), beBytes(UInt32(12 + plain.count + 16)))
        XCTAssertNotEqual(Array(s1[4..<16]), Array(s2[4..<16]))
        XCTAssertNotEqual(s1, s2)
    }

    // MARK: - Passwords

    func testPasswordRules() throws {
        XCTAssertEqual(BackupPassword.minimumLength, 10)
        XCTAssertEqual(BackupPassword.problems(testPassword, confirm: testPassword), [])
        XCTAssertEqual(BackupPassword.problems("blue-tulip", confirm: "blue-tulip"), [])
        XCTAssertEqual(BackupPassword.problems("blue-tuli", confirm: "blue-tuli"), ["Use at least 10 characters"])
        XCTAssertEqual(BackupPassword.problems("", confirm: ""), ["Use at least 10 characters"])
        XCTAssertEqual(BackupPassword.problems(testPassword, confirm: "correct horse batterie"), ["The passwords do not match"])
        for common in ["password123", "Password1234!", "aaaaaaaaaaaa", "ababababab", "Receipt Vault 2025"] {
            XCTAssertEqual(BackupPassword.problems(common, confirm: common), ["Too common"], common)
        }
        XCTAssertEqual(BackupPassword.problems("qwerty", confirm: "qwertz"),
                       ["Use at least 10 characters", "The passwords do not match", "Too common"])
        XCTAssertTrue(BackupPassword.advice.contains("Passwords"))
        XCTAssertTrue(BackupPassword.advice.contains("four"))

        // The writer refuses a short password before creating anything.
        let url = tempURL()
        XCTAssertEqual(backupError { _ = try BackupWriter(url: url, password: "blue-tuli", iterations: testIterations) },
                       BackupError.passwordTooShort)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(BackupError.passwordTooShort.errorDescription, "Use a password of at least 10 characters.")
        XCTAssertNoThrow(try BackupWriter(url: url, password: "blue-tulip", iterations: testIterations).finish())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Manifest

    func testManifestJSONRoundTripWithNils() throws {
        let manifest = BackupManifest(formatVersion: BackupManifest.currentFormatVersion,
                                      createdAt: stamp,
                                      appVersion: "1.0 (1)",
                                      items: [bareItem(), fullItem()])
        let json = try manifest.encoded()
        let decoded = try BackupManifest.decode(json)
        XCTAssertEqual(decoded, manifest)
        XCTAssertNil(decoded.items[0].totalMinor)
        XCTAssertNil(decoded.items[0].deliveryDate)
        XCTAssertNil(decoded.items[0].issueNotedAt)
        XCTAssertNil(decoded.items[0].termEnd)
        XCTAssertNil(decoded.items[0].vatRatePermille)
        XCTAssertEqual(decoded.items[1], fullItem())

        // Sorted keys: the same manifest always gives the same bytes.
        XCTAssertEqual(try manifest.encoded(), json)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).hasPrefix("{\"appVersion\""))

        // Nil values are left out rather than written as null.
        let bareOnly = BackupManifest(formatVersion: 1, createdAt: stamp, appVersion: "1.0 (1)", items: [bareItem()])
        let bareText = String(decoding: try bareOnly.encoded(), as: UTF8.self)
        XCTAssertFalse(bareText.contains("totalMinor"))
        XCTAssertEqual(try BackupManifest.decode(try bareOnly.encoded()), bareOnly)

        XCTAssertEqual(backupError { _ = try BackupManifest.decode(Data("not json".utf8)) }, BackupError.badEntry)
        XCTAssertEqual(backupError { _ = try BackupManifest.decode(Data("{}".utf8)) }, BackupError.badEntry)
    }

    // MARK: - Search

    func testSearchFolding() {
        XCTAssertEqual(SearchText.tokens("Müller, Zürich (CH)"), ["muller", "zurich", "ch"])
        let blob = SearchText.blob(["Müller Elektro", "Hohe Straße 12, Zürich"])
        XCTAssertTrue(blob.hasPrefix(" "))
        XCTAssertTrue(blob.hasSuffix(" "))
        for query in ["zurich", "Zürich", "ZURICH", "zuerich", "zür", "strasse", "Straße", "mueller", "muller", "Müller", "elektro"] {
            XCTAssertTrue(finds(query, blob), query)
        }
        XCTAssertFalse(finds("munich", blob))

        // Decomposed accents (as some OCR and keyboards give) fold the same way.
        let decomposed = SearchText.blob(["Mu\u{0308}ller"])
        XCTAssertTrue(finds("muller", decomposed))
        XCTAssertTrue(finds("mueller", decomposed))
        XCTAssertTrue(finds("Müller", decomposed))
    }

    func testSearchAllTokensAndPrefix() {
        let blob = SearchText.blob(["Samsung TV", "Currys"])
        XCTAssertTrue(finds("sams tv", blob))
        XCTAssertTrue(finds("tv sams", blob))
        XCTAssertTrue(finds("SAMS", blob))
        XCTAssertTrue(finds("curr samsung", blob))
        XCTAssertFalse(finds("sams phone", blob)) // every word must match
        XCTAssertFalse(finds("sung", blob))       // word prefixes only

        XCTAssertEqual(SearchText.parse("Sams, TV!").words, ["sams", "tv"])
        XCTAssertTrue(SearchText.parse("   ").isEmpty)
        XCTAssertTrue(finds("", blob))
        XCTAssertTrue(finds("", blob, total: nil))
        XCTAssertEqual(SearchText.blob(["TV", "tv"]), " tv ")
        XCTAssertEqual(SearchText.maxOCRCharacters, 20_000)
    }

    func testSearchAmounts() {
        XCTAssertEqual(SearchText.amountTerms(24_900), ["249.00", "249,00", "249"])
        XCTAssertEqual(SearchText.amountTerms(1_999), ["19.99", "19,99"])
        XCTAssertEqual(SearchText.amountTerms(-1_250), ["12.50", "12,50"])

        let blob = SearchText.blob(["Samsung TV"])
        for query in ["249", "249.00", "249,00", "tv 249"] {
            XCTAssertTrue(finds(query, blob, total: 24_900), query)
        }
        XCTAssertFalse(finds("250", blob, total: 24_900))
        XCTAssertFalse(finds("249", blob, total: nil))

        // A blob built with the amount terms finds them without a total.
        let withAmounts = SearchText.blob(["Samsung TV"] + SearchText.amountTerms(24_900))
        XCTAssertTrue(finds("249.00", withAmounts))
        XCTAssertTrue(finds("249,00", withAmounts))

        XCTAssertEqual(SearchText.parse(">500"), SearchQuery(words: [], minMinor: 50_000, maxMinor: nil))
        XCTAssertEqual(SearchText.parse("> 500"), SearchQuery(words: [], minMinor: 50_000, maxMinor: nil))
        XCTAssertEqual(SearchText.parse("<20"), SearchQuery(words: [], minMinor: nil, maxMinor: 2_000))
        XCTAssertEqual(SearchText.parse("50-200"), SearchQuery(words: [], minMinor: 5_000, maxMinor: 20_000))
        XCTAssertEqual(SearchText.parse("tv >200"), SearchQuery(words: ["tv"], minMinor: 20_000, maxMinor: nil))
        XCTAssertEqual(SearchText.parse("<12,50").maxMinor, 1_250)
        XCTAssertEqual(SearchText.parse(">1.000").minMinor, 100_000)
        XCTAssertEqual(SearchText.parse("2025-03").words, ["2025-03"]) // a month, not a range

        XCTAssertTrue(finds(">200", blob, total: 24_900))
        XCTAssertFalse(finds("<100", blob, total: 24_900))
        XCTAssertTrue(finds("200-300", blob, total: 24_900))
        XCTAssertFalse(finds("300-400", blob, total: 24_900))
        XCTAssertTrue(finds("tv >200", blob, total: 24_900))
        XCTAssertFalse(finds("phone >200", blob, total: 24_900))
        XCTAssertFalse(finds(">200", blob, total: nil)) // bounds need a total
    }

    func testSearchMonthNames() {
        let terms = SearchText.dateTerms(day(2025, 3, 12))
        for term in ["2025-03-12", "12.03.2025", "12/03/2025", "2025", "12.3.2025", "march", "marz", "maerz", "mars", "marzo"] {
            XCTAssertTrue(terms.contains(term), term)
        }
        let december = SearchText.dateTerms(day(2024, 12, 5))
        for term in ["2024-12-05", "05.12.2024", "05/12/2024", "5.12.2024", "december", "dezember", "decembre", "dicembre"] {
            XCTAssertTrue(december.contains(term), term)
        }

        let blob = SearchText.blob(["Samsung TV"] + terms)
        for query in ["märz 2025", "MÄRZ", "maerz", "mars", "march", "marzo", "12.03.2025", "2025-03", "samsung march"] {
            XCTAssertTrue(finds(query, blob), query)
        }
        for query in ["april", "avril", "märz 2024"] {
            XCTAssertFalse(finds(query, blob), query)
        }
        XCTAssertTrue(finds("décembre", SearchText.blob(december)))
    }

    // MARK: - CSV

    func testCSVHeaderIsStable() {
        let header = "Date,Delivered,Merchant,Title,Kind,Category,Total,Currency,VAT,VAT rate %,Claimable,Return by,Warranty until,Legal cover until,Notice by,Notes,ID"
        XCTAssertEqual(ItemCSV.header.joined(separator: ","), header)
        XCTAssertEqual(ItemCSV.header.count, 17)
        XCTAssertEqual(ItemCSV.make([]), header + "\n")
    }

    func testCSVEscapingAndAmounts() {
        XCTAssertEqual(ItemCSV.escape("Currys"), "Currys")
        XCTAssertEqual(ItemCSV.escape(""), "")
        XCTAssertEqual(ItemCSV.escape("Currys, Oxford St"), "\"Currys, Oxford St\"")
        XCTAssertEqual(ItemCSV.escape("55\" TV"), "\"55\"\" TV\"")
        XCTAssertEqual(ItemCSV.escape("one\ntwo"), "\"one\ntwo\"")
        XCTAssertEqual(ItemCSV.escape("one\rtwo"), "\"one\rtwo\"")
        XCTAssertEqual(ItemCSV.escape("one\r\ntwo"), "\"one\r\ntwo\"")

        let tvID = uuid("A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF")
        let refundID = uuid("B2C3D4E5-F6A7-4822-9900-BBCCDDEEFF00")
        let cardID = uuid("C3D4E5F6-A7B8-4933-8011-CCDDEEFF0011")
        let tv = ItemCSVRow(date: day(2025, 3, 12), delivered: day(2025, 3, 14),
                            merchant: "Currys, Oxford St", title: "55\" TV",
                            kind: ItemKind.receipt, category: ProductCategory.electronics,
                            totalMinor: 24_900, currency: "GBP", vatMinor: 4_150, vatRatePermille: 200,
                            taxTag: TaxTag.none,
                            returnBy: day(2025, 4, 9), warrantyUntil: nil, legalCoverUntil: day(2031, 3, 11), noticeBy: nil,
                            notes: "Box kept\nin the loft", id: tvID)
        let refund = ItemCSVRow(date: day(2025, 1, 5), delivered: nil,
                                merchant: "Galaxus", title: "Refund: cable",
                                kind: ItemKind.invoice, category: ProductCategory.service,
                                totalMinor: -1_250, currency: "CHF", vatMinor: -94, vatRatePermille: 81,
                                taxTag: TaxTag.both,
                                returnBy: nil, warrantyUntil: nil, legalCoverUntil: nil, noticeBy: nil,
                                notes: "", id: refundID)
        let card = ItemCSVRow(date: day(2025, 3, 12), delivered: nil,
                              merchant: "Boots", title: "Hair dryer warranty",
                              kind: ItemKind.warranty, category: ProductCategory.appliance,
                              totalMinor: nil, currency: "GBP", vatMinor: nil, vatRatePermille: nil,
                              taxTag: TaxTag.uk,
                              returnBy: nil, warrantyUntil: day(2027, 3, 12), legalCoverUntil: nil, noticeBy: nil,
                              notes: "Keep the \"blue\" copy", id: cardID)

        // Sorted by date; rows on the same day keep their order.
        let lines: [String] = [
            ItemCSV.header.joined(separator: ","),
            "2025-01-05,,Galaxus,Refund: cable,Invoice,Service,-12.50,CHF,-0.94,8.1,UK and Switzerland,,,,,,\(refundID.uuidString)",
            "2025-03-12,2025-03-14,\"Currys, Oxford St\",\"55\"\" TV\",Receipt,Electronics,249.00,GBP,41.50,20,,2025-04-09,,2031-03-11,,\"Box kept\nin the loft\",\(tvID.uuidString)",
            "2025-03-12,,Boots,Hair dryer warranty,Warranty card,Appliances,,GBP,,,UK,,2027-03-12,,,\"Keep the \"\"blue\"\" copy\",\(cardID.uuidString)",
        ]
        let csv = ItemCSV.make([tv, refund, card])
        XCTAssertEqual(csv, lines.joined(separator: "\n") + "\n")
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    // MARK: - Evidence summary

    func testEvidenceSummary() {
        let today = day(2025, 4, 2)
        let legal = [
            LegalNote(text: "You can ask the shop for a repair or a replacement.",
                      basis: "Consumer Rights Act 2015, s. 23", isAssumption: false),
            LegalNote(text: "A fault found within six months is presumed to have been there at delivery.",
                      basis: "Consumer Rights Act 2015, s. 19(14)", isAssumption: true),
        ]
        let lines = EvidenceSummary.lines(evidenceInput(), today: today, notes: legal, generatedAt: "2 Apr 2025, 10:15")
        let texts = lines.map { $0.text }

        XCTAssertEqual(lines.first, EvidenceLine(style: .title, text: "Samsung TV"))
        XCTAssertEqual(lines.dropFirst().first, EvidenceLine(style: .small, text: "Evidence summary prepared with ReceiptVault on 2 Apr 2025, 10:15"))
        let expectedLines: [EvidenceLine] = [
            EvidenceLine(style: .heading, text: "Details"),
            EvidenceLine(style: .body, text: "Merchant: Currys"),
            EvidenceLine(style: .body, text: "Document: Receipt"),
            EvidenceLine(style: .body, text: "Purchased: 2025-03-12"),
            EvidenceLine(style: .body, text: "Delivered: 2025-03-14"),
            EvidenceLine(style: .body, text: "Bought: In store"),
            EvidenceLine(style: .body, text: "Rules: \(Jurisdiction.englandWales.label)"),
            EvidenceLine(style: .body, text: "Total 249.00 GBP (VAT 41.50 at 20%)"),
            EvidenceLine(style: .heading, text: "Items"),
            EvidenceLine(style: .body, text: "2 \u{00D7} USB-C cable \u{00B7} 19.98 GBP"),
            EvidenceLine(style: .body, text: "55\" TV \u{00B7} 229.02 GBP"),
            EvidenceLine(style: .small, text: "Status as of 2025-04-02."),
            EvidenceLine(style: .heading, text: "Fault"),
            EvidenceLine(style: .body, text: "Fault noticed on 2025-03-30."),
            EvidenceLine(style: .body, text: "Screen flickers after an hour."),
            EvidenceLine(style: .body, text: "Box kept."),
            EvidenceLine(style: .body, text: "1. Receipt.jpg \u{00B7} 1 page \u{00B7} Camera scan \u{00B7} saved 12 Mar 2025, 14:32 (Europe/London)"),
            EvidenceLine(style: .small, text: "SHA-256 \(goodHash), matches the fingerprint taken at capture"),
            EvidenceLine(style: .body, text: "2. Invoice.pdf \u{00B7} 2 pages \u{00B7} Files \u{00B7} saved 14 Mar 2025, 09:05 (Europe/London)"),
            EvidenceLine(style: .small, text: EvidenceSummary.integrityNote),
            EvidenceLine(style: .heading, text: "General information about your rights"),
            EvidenceLine(style: .small, text: "Basis: Consumer Rights Act 2015, s. 23"),
            EvidenceLine(style: .small, text: "Basis: Consumer Rights Act 2015, s. 19(14) (Assumed)"),
        ]
        for line in expectedLines {
            XCTAssertTrue(lines.contains(line), line.text)
        }

        // Key dates in date order, each with its status and source.
        let cancel = texts.firstIndex(of: "Cancel by: 2025-03-26 (7 days ago) \u{00B7} Source: Law")
        let back = texts.firstIndex(of: "Return by: 2025-04-09 (in 7 days) \u{00B7} Source: From document")
        let guarantee = texts.firstIndex(of: "Legal guarantee ends: 2031-03-11 (in 72 months) \u{00B7} Source: Law")
        XCTAssertNotNil(cancel)
        XCTAssertNotNil(back)
        XCTAssertNotNil(guarantee)
        if let c = cancel, let r = back, let g = guarantee {
            XCTAssertLessThan(c, r)
            XCTAssertLessThan(r, g)
        }

        // Only the changed file is flagged, loudly.
        let warnings = lines.filter { $0.text.contains("DOES NOT MATCH") }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.style, EvidenceStyle.body)
        XCTAssertTrue(warnings.first?.text.contains(badHash) == true)
        XCTAssertFalse(texts.contains("SHA-256 \(badHash), matches the fingerprint taken at capture"))

        // The disclaimer is always last, and only once.
        XCTAssertEqual(lines.last, EvidenceLine(style: .small, text: LegalNotes.disclaimer))
        XCTAssertEqual(texts.filter { $0 == LegalNotes.disclaimer }.count, 1)

        // A bare contract: no amounts, dates, files or legal notes.
        var contract = evidenceInput()
        contract.kind = ItemKind.contract
        contract.title = ""
        contract.merchant = "Sunrise"
        contract.totalMinor = nil
        contract.vatMinor = nil
        contract.vatRatePermille = nil
        contract.items = []
        contract.dates = []
        contract.files = []
        contract.notes = ""
        contract.hasIssue = false
        let bare = EvidenceSummary.lines(contract, today: today, notes: [], generatedAt: "")
        let bareTexts = bare.map { $0.text }
        XCTAssertEqual(bare.first, EvidenceLine(style: .title, text: "Sunrise"))
        XCTAssertTrue(bareTexts.contains("Evidence summary prepared with ReceiptVault"))
        XCTAssertTrue(bareTexts.contains("Date: 2025-03-12"))
        XCTAssertFalse(bareTexts.contains("Purchased: 2025-03-12"))
        XCTAssertFalse(bareTexts.contains { $0.hasPrefix("Bought:") })
        XCTAssertTrue(bareTexts.contains("Total not recorded"))
        XCTAssertTrue(bareTexts.contains("No original files are attached."))
        XCTAssertTrue(bareTexts.contains(EvidenceSummary.integrityNote))
        XCTAssertFalse(bareTexts.contains("Key dates"))
        XCTAssertFalse(bareTexts.contains("Fault"))
        XCTAssertFalse(bareTexts.contains("General information about your rights"))
        XCTAssertEqual(bare.last, EvidenceLine(style: .small, text: LegalNotes.disclaimer))

        // Without a title or merchant, the kind is the title.
        contract.merchant = ""
        XCTAssertEqual(EvidenceSummary.lines(contract, today: today, notes: [], generatedAt: "").first,
                       EvidenceLine(style: .title, text: "Contract"))

        // A fault without a date.
        var undated = evidenceInput()
        undated.issueNoted = nil
        XCTAssertTrue(EvidenceSummary.lines(undated, today: today, notes: [], generatedAt: "").map { $0.text }
            .contains("A fault has been noted; the date was not recorded."))

        // Amount line variants, always Money.plain plus the ISO code.
        func amountLine(_ input: EvidenceInput) -> String? {
            EvidenceSummary.lines(input, today: today, notes: [], generatedAt: "").map { $0.text }.first { $0.hasPrefix("Total") }
        }
        var chf = evidenceInput()
        chf.currency = "CHF"
        chf.totalMinor = 10_000
        chf.vatMinor = 750
        chf.vatRatePermille = 81
        XCTAssertEqual(amountLine(chf), "Total 100.00 CHF (VAT 7.50 at 8.1%)")
        chf.vatMinor = nil
        XCTAssertEqual(amountLine(chf), "Total 100.00 CHF (VAT rate 8.1%)")
        chf.vatRatePermille = nil
        XCTAssertEqual(amountLine(chf), "Total 100.00 CHF")
        chf.totalMinor = nil
        chf.vatMinor = 750
        XCTAssertEqual(amountLine(chf), "Total not recorded (VAT 7.50 CHF)")
    }

    func testStatusText() {
        let today = day(2025, 3, 12)
        func status(_ days: Int) -> String {
            EvidenceSummary.status(of: RVCalendar.adding(days: days, to: today), today: today)
        }
        XCTAssertEqual(status(0), "today")
        XCTAssertEqual(status(1), "tomorrow")
        XCTAssertEqual(status(-1), "yesterday")
        XCTAssertEqual(status(2), "in 2 days")
        XCTAssertEqual(status(-2), "2 days ago")
        XCTAssertEqual(status(5), "in 5 days")
        XCTAssertEqual(status(-5), "5 days ago")
        XCTAssertEqual(status(90), "in 90 days")
        XCTAssertEqual(status(-90), "90 days ago")
        XCTAssertEqual(status(91), "in 3 months")
        XCTAssertEqual(status(120), "in 4 months")
        XCTAssertEqual(status(-120), "4 months ago")
        XCTAssertEqual(status(365), "in 12 months")

        // Across month, year and leap-day boundaries.
        XCTAssertEqual(EvidenceSummary.status(of: day(2025, 3, 1), today: day(2025, 2, 28)), "tomorrow")
        XCTAssertEqual(EvidenceSummary.status(of: day(2024, 3, 1), today: day(2024, 2, 28)), "in 2 days")
        XCTAssertEqual(EvidenceSummary.status(of: day(2024, 12, 31), today: day(2025, 1, 1)), "yesterday")
    }
}
