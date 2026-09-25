import Foundation
import CryptoKit
import CommonCrypto

// The password-encrypted .rvault backup format.
//
// File layout:
//   header (32 bytes)  'RVLT' | version 1 | kdf 1 | 0 0 | iterations UInt32 BE | salt (16) | 0 0 0 0
//   frames, each       length UInt32 BE | nonce (12) | ciphertext | tag (16)
//
// Key: PBKDF2-HMAC-SHA256 over the NFC password (32 bytes), then
// HKDF<SHA256>(salt: salt, info: 'ReceiptVault backup v1', 32 bytes).
// Each frame is one AES-256-GCM box with a random nonce and
// AAD = header bytes + UInt64 BE frame index, so reordering is detected.
//
// Plain entries: 1 = manifest JSON; 2 = file (UInt16 BE name length, UTF-8
// name, data); 3 = end (UInt64 BE count of frames before it). The end frame
// makes truncation and trailing data detectable.
//
// Foundation, CryptoKit and CommonCrypto only, so it runs under `swift test`.

// MARK: - Errors

enum BackupError: Error, Equatable, LocalizedError {
    case badHeader
    case unsupportedVersion(Int)
    case weakParameters
    case wrongPasswordOrDamaged
    case truncated
    case passwordTooShort
    case keyDerivationFailed
    case badEntry

    var errorDescription: String? {
        switch self {
        case .badHeader:
            return "This file is not a ReceiptVault backup."
        case .unsupportedVersion(let version):
            return "This backup uses format version \(version), which this version of ReceiptVault cannot read."
        case .weakParameters:
            return "This backup uses encryption settings ReceiptVault does not accept."
        case .wrongPasswordOrDamaged:
            return "Wrong password or damaged file."
        case .truncated:
            return "The backup file is incomplete. Copy it again and retry."
        case .passwordTooShort:
            return "Use a password of at least \(BackupPassword.minimumLength) characters."
        case .keyDerivationFailed:
            return "The backup key could not be created."
        case .badEntry:
            return "The backup contains an entry ReceiptVault cannot read."
        }
    }
}

// MARK: - Byte helpers

private enum BackupBytes {
    /// The value's bytes, most significant first.
    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        let size = T.bitWidth / 8
        return (0..<size).map { i in UInt8(truncatingIfNeeded: value >> ((size - 1 - i) * 8)) }
    }

    /// Reads big-endian bytes; the caller passes exactly T's width.
    static func value<T: FixedWidthInteger, C: Collection>(_ type: T.Type, from bytes: C) -> T where C.Element == UInt8 {
        var result: T = 0
        for byte in bytes { result = (result << 8) | T(byte) }
        return result
    }
}

// MARK: - Header

/// The fixed 32-byte file header. Its bytes are part of every frame's AAD.
struct BackupHeader: Equatable {
    static let magic: [UInt8] = [0x52, 0x56, 0x4C, 0x54]  // 'RVLT'
    static let size = 32
    static let currentVersion: UInt8 = 1
    /// KDF id 1: PBKDF2-HMAC-SHA256 then HKDF-SHA256.
    static let pbkdf2HKDF: UInt8 = 1
    static let saltSize = 16

    var version: UInt8
    var kdf: UInt8
    var iterations: UInt32
    var salt: [UInt8]

    /// Magic, version, kdf, 2 reserved zero bytes, iterations (BE), salt, 4 zero bytes.
    var bytes: [UInt8] {
        var out = BackupHeader.magic
        out.reserveCapacity(BackupHeader.size)
        out.append(version)
        out.append(kdf)
        out.append(contentsOf: [0, 0])
        out.append(contentsOf: BackupBytes.bigEndian(iterations))
        var fixedSalt = Array(salt.prefix(BackupHeader.saltSize))
        if fixedSalt.count < BackupHeader.saltSize {
            fixedSalt.append(contentsOf: [UInt8](repeating: 0, count: BackupHeader.saltSize - fixedSalt.count))
        }
        out.append(contentsOf: fixedSalt)
        out.append(contentsOf: [0, 0, 0, 0])
        return out
    }

    /// A version 1 header with a fresh random salt.
    static func make(iterations: UInt32) -> BackupHeader {
        var rng = SystemRandomNumberGenerator()
        let salt = (0..<BackupHeader.saltSize).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        return BackupHeader(version: BackupHeader.currentVersion, kdf: BackupHeader.pbkdf2HKDF,
                            iterations: iterations, salt: salt)
    }

    /// Reads the first 32 bytes. Wrong magic, an unknown KDF or non-zero
    /// reserved bytes throw .badHeader; a short header throws .truncated.
    static func parse(_ data: Data) throws -> BackupHeader {
        let b = [UInt8](data.prefix(BackupHeader.size))
        guard b.count >= BackupHeader.magic.count,
              Array(b[0..<BackupHeader.magic.count]) == BackupHeader.magic else { throw BackupError.badHeader }
        guard b.count == BackupHeader.size else { throw BackupError.truncated }
        guard b[4] == BackupHeader.currentVersion else { throw BackupError.unsupportedVersion(Int(b[4])) }
        guard b[5] == BackupHeader.pbkdf2HKDF, b[6] == 0, b[7] == 0,
              b[28..<32].allSatisfy({ $0 == 0 }) else { throw BackupError.badHeader }
        return BackupHeader(version: b[4], kdf: b[5],
                            iterations: BackupBytes.value(UInt32.self, from: b[8..<12]),
                            salt: Array(b[12..<28]))
    }
}

// MARK: - Crypto

enum BackupCrypto {
    static let defaultIterations: UInt32 = 600_000
    /// Largest sealed frame (without its length prefix): 48 MiB of plain text plus nonce and tag.
    static let maxFrameBytes = 48 * 1_048_576 + 28
    static let nonceBytes = 12
    static let tagBytes = 16
    /// Nonce plus tag: the smallest possible sealed frame.
    static let overhead = 28
    static let info = "ReceiptVault backup v1"

    /// PBKDF2-HMAC-SHA256 (CommonCrypto) over the NFC-normalised password,
    /// so a password typed with composed or decomposed accents gives the same key.
    static func pbkdf2SHA256(password: String, salt: [UInt8], iterations: UInt32, length: Int = 32) throws -> [UInt8] {
        guard iterations > 0, length > 0 else { throw BackupError.keyDerivationFailed }
        let pw: [CChar] = password.precomposedStringWithCanonicalMapping.utf8.map { CChar(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: length)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          pw, pw.count,
                                          salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          iterations,
                                          &out, length)
        guard status == Int32(kCCSuccess) else { throw BackupError.keyDerivationFailed }
        return out
    }

    /// The AES-256 key for a file: PBKDF2 with the header's salt and
    /// iterations, then HKDF-SHA256 with the same salt.
    static func key(password: String, header: BackupHeader) throws -> SymmetricKey {
        guard header.kdf == BackupHeader.pbkdf2HKDF, header.salt.count == BackupHeader.saltSize else {
            throw BackupError.badHeader
        }
        let master = try pbkdf2SHA256(password: password, salt: header.salt, iterations: header.iterations)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master),
                                      salt: header.salt,
                                      info: Data(BackupCrypto.info.utf8),
                                      outputByteCount: 32)
    }

    /// Header bytes followed by the frame index (UInt64 BE).
    static func aad(header: BackupHeader, index: UInt64) -> [UInt8] {
        header.bytes + BackupBytes.bigEndian(index)
    }

    /// One frame as written to disk: UInt32 BE length, then nonce | ciphertext | tag.
    static func sealFrame(_ plain: Data, index: UInt64, header: BackupHeader, key: SymmetricKey) throws -> Data {
        guard plain.count <= BackupCrypto.maxFrameBytes - BackupCrypto.overhead else { throw BackupError.badEntry }
        let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(),
                                   authenticating: aad(header: header, index: index))
        guard let combined = box.combined else { throw BackupError.badEntry }
        var out = Data(capacity: 4 + combined.count)
        out.append(contentsOf: BackupBytes.bigEndian(UInt32(combined.count)))
        out.append(combined)
        return out
    }

    /// Opens nonce | ciphertext | tag (no length prefix). Any failure,
    /// including a wrong key, is .wrongPasswordOrDamaged.
    static func openFrame(_ sealed: Data, index: UInt64, header: BackupHeader, key: SymmetricKey) throws -> Data {
        guard sealed.count >= BackupCrypto.overhead else { throw BackupError.wrongPasswordOrDamaged }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: aad(header: header, index: index))
        } catch {
            throw BackupError.wrongPasswordOrDamaged
        }
    }
}

// MARK: - Entries

/// The plain content of one frame.
enum BackupEntry: Equatable {
    case manifest(Data)
    case file(name: String, data: Data)
    case end(frames: UInt64)

    private static let manifestByte: UInt8 = 1
    private static let fileByte: UInt8 = 2
    private static let endByte: UInt8 = 3

    func encoded() -> Data {
        var out = Data()
        switch self {
        case .manifest(let json):
            out.reserveCapacity(1 + json.count)
            out.append(BackupEntry.manifestByte)
            out.append(json)
        case .file(let name, let data):
            let nameBytes = Array(name.utf8.prefix(Int(UInt16.max)))
            out.reserveCapacity(3 + nameBytes.count + data.count)
            out.append(BackupEntry.fileByte)
            out.append(contentsOf: BackupBytes.bigEndian(UInt16(nameBytes.count)))
            out.append(contentsOf: nameBytes)
            out.append(data)
        case .end(let frames):
            out.append(BackupEntry.endByte)
            out.append(contentsOf: BackupBytes.bigEndian(frames))
        }
        return out
    }

    /// Throws .badEntry for an unknown type or a malformed body.
    static func decode(_ data: Data) throws -> BackupEntry {
        guard let kind = data.first else { throw BackupError.badEntry }
        let start = data.startIndex + 1
        let dataEnd = data.endIndex
        switch kind {
        case BackupEntry.manifestByte:
            return .manifest(data.subdata(in: start..<dataEnd))
        case BackupEntry.fileByte:
            guard dataEnd - start >= 2 else { throw BackupError.badEntry }
            let nameLength = Int(BackupBytes.value(UInt16.self, from: data[start..<(start + 2)]))
            let nameStart = start + 2
            let nameEnd = nameStart + nameLength
            guard nameEnd <= dataEnd,
                  let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) else {
                throw BackupError.badEntry
            }
            return .file(name: name, data: data.subdata(in: nameEnd..<dataEnd))
        case BackupEntry.endByte:
            guard dataEnd - start == 8 else { throw BackupError.badEntry }
            return .end(frames: BackupBytes.value(UInt64.self, from: data[start..<dataEnd]))
        default:
            throw BackupError.badEntry
        }
    }

    /// Only '<UUID>.jpg' or '<UUID>.pdf' (hex in either case), the same as
    /// ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.(jpg|pdf)$
    /// but checked byte by byte, so no path, no trailing newline and no other extension gets through.
    static func isAllowedFileName(_ name: String) -> Bool {
        let b = Array(name.utf8)
        guard b.count == 40 else { return false }
        let dashes: Set<Int> = [8, 13, 18, 23]
        for i in 0..<36 {
            if dashes.contains(i) {
                guard b[i] == 0x2D else { return false }  // '-'
            } else {
                let c = b[i]
                let isHex = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
                guard isHex else { return false }
            }
        }
        let ext = String(decoding: b[36..<40], as: UTF8.self)
        return ext == ".jpg" || ext == ".pdf"
    }
}

// MARK: - Writer

/// Writes a backup frame by frame, so large files never sit in memory together.
/// Append the manifest first, then each file, then call finish().
final class BackupWriter {
    let header: BackupHeader
    private let key: SymmetricKey
    private var handle: FileHandle?
    private var index: UInt64 = 0

    /// Derives the key, then creates the file (with complete protection on
    /// iOS) and writes the header. Throws .passwordTooShort below
    /// BackupPassword.minimumLength characters.
    init(url: URL, password: String, iterations: UInt32 = BackupCrypto.defaultIterations) throws {
        guard password.count >= BackupPassword.minimumLength else { throw BackupError.passwordTooShort }
        guard iterations > 0 else { throw BackupError.weakParameters }
        let header = BackupHeader.make(iterations: iterations)
        let key = try BackupCrypto.key(password: password, header: header)

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        #if os(iOS)
        let attributes: [FileAttributeKey: Any]? = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        guard fm.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: header.bytes)
        } catch {
            try? handle.close()
            throw error
        }
        self.header = header
        self.key = key
        self.handle = handle
    }

    deinit {
        try? handle?.close()
    }

    /// Seals the entry as the next frame.
    func append(_ entry: BackupEntry) throws {
        guard let handle = handle else { throw BackupError.badEntry }
        let frame = try BackupCrypto.sealFrame(entry.encoded(), index: index, header: header, key: key)
        try handle.write(contentsOf: frame)
        index += 1
    }

    /// Writes the end frame (the count of frames before it) and closes the file.
    func finish() throws {
        try append(.end(frames: index))
        guard let handle = handle else { return }
        self.handle = nil
        try handle.synchronize()
        try handle.close()
    }
}

// MARK: - Reader

/// Reads and verifies a backup frame by frame.
final class BackupReader {
    let header: BackupHeader
    private let key: SymmetricKey
    private var handle: FileHandle?
    private var index: UInt64 = 0
    private var finished = false
    private var failure: Error?

    /// Reads the header and checks the iteration count BEFORE deriving the
    /// key, so a crafted file cannot make the phone spin. A wrong password
    /// is only noticed by next().
    init(url: URL, password: String, minimumIterations: UInt32 = 100_000, maximumIterations: UInt32 = 10_000_000) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            let header = try BackupHeader.parse(BackupReader.read(handle, count: BackupHeader.size))
            guard header.iterations >= minimumIterations, header.iterations <= maximumIterations else {
                throw BackupError.weakParameters
            }
            self.header = header
            self.key = try BackupCrypto.key(password: password, header: header)
            self.handle = handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle?.close()
    }

    /// The next manifest or file entry. Never returns .end: nil means the end
    /// frame was verified (right count, nothing after it). The first entry is
    /// always the manifest. After an error, every later call throws it again.
    func next() throws -> BackupEntry? {
        if let failure = failure { throw failure }
        guard !finished, let handle = handle else { return nil }
        do {
            return try readEntry(handle)
        } catch {
            failure = error
            close()
            throw error
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func readEntry(_ handle: FileHandle) throws -> BackupEntry? {
        let prefix = try BackupReader.read(handle, count: 4)
        guard prefix.count == 4 else { throw BackupError.truncated }
        let length = Int(BackupBytes.value(UInt32.self, from: prefix))
        // Checked before anything of that size is read or allocated.
        guard length >= BackupCrypto.overhead, length <= BackupCrypto.maxFrameBytes else {
            throw BackupError.wrongPasswordOrDamaged
        }
        let sealed = try BackupReader.read(handle, count: length)
        guard sealed.count == length else { throw BackupError.truncated }
        let position = index
        let plain = try BackupCrypto.openFrame(sealed, index: position, header: header, key: key)
        let entry = try BackupEntry.decode(plain)
        index += 1

        if position == 0 {
            guard case .manifest = entry else { throw BackupError.badEntry }
            return entry
        }
        switch entry {
        case .manifest:
            throw BackupError.badEntry
        case .file(let name, _):
            guard BackupEntry.isAllowedFileName(name) else { throw BackupError.badEntry }
            return entry
        case .end(let frames):
            guard frames == position else { throw BackupError.wrongPasswordOrDamaged }
            if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
                throw BackupError.wrongPasswordOrDamaged
            }
            finished = true
            close()
            return nil
        }
    }

    /// Up to `count` bytes; fewer only at the end of the file.
    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }
}

// MARK: - Manifest and DTOs

/// The first entry of every backup: all items with their dates and file records.
struct BackupManifest: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var items: [ItemDTO]

    /// JSON with sorted keys and the default date strategy.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Throws .badEntry when the JSON does not describe a manifest.
    static func decode(_ data: Data) throws -> BackupManifest {
        do {
            return try JSONDecoder().decode(BackupManifest.self, from: data)
        } catch {
            throw BackupError.badEntry
        }
    }
}

/// One VaultItem. Enums are carried as their raw strings.
struct ItemDTO: Codable, Equatable {
    var id: UUID
    var kind: String
    var title: String
    var merchant: String
    var purchaseDate: DayDate
    var deliveryDate: DayDate?
    var totalMinor: Int64?
    var currency: String
    var vatMinor: Int64?
    var vatRatePermille: Int?
    var jurisdiction: String
    var channel: String
    var category: String
    var taxTag: String
    var isUsed: Bool
    var hasIssue: Bool
    var issueNotedAt: Date?
    var returnDays: Int?
    var returnDaysIsPrinted: Bool
    var warrantyMonths: Int?
    var warrantyIsPrinted: Bool
    var contractPresetID: String
    var termEnd: DayDate?
    var autoRenews: Bool
    var renewalMonths: Int
    var notice: NoticePeriod
    var cancelled: Bool
    var noticeSentAt: Date?
    var itemLines: String
    var notes: String
    var ocrText: String
    var needsReview: Bool
    var checkFields: String
    var createdAt: Date
    var updatedAt: Date
    var deadlines: [DeadlineDTO]
    var files: [FileDTO]
}

/// One Deadline row.
struct DeadlineDTO: Codable, Equatable {
    var id: UUID
    var kind: String
    var date: DayDate
    var label: String
    var remindersOn: Bool
    var offsets: [Int]
    var isDone: Bool
    var basis: String
    var certainty: String
}

/// One StoredFile record. The original's bytes follow in a file entry named fileName.
struct FileDTO: Codable, Equatable {
    var id: UUID
    var fileName: String
    var isPDF: Bool
    var pageCount: Int
    var byteCount: Int
    var originalName: String
    var sha256: String
    var source: String
    var capturedAt: Date
    var capturedTimeZone: String
    var sortIndex: Int
}

// MARK: - Password rules

enum BackupPassword {
    static let minimumLength = 10

    static let advice = "Use a passphrase of four or more random words and save it in the iPhone Passwords app. ReceiptVault never stores this password, and a lost password cannot be recovered."

    /// Lowercased, spaces removed. Built from an array, so a repeated word cannot crash.
    private static let common: Set<String> = Set([
        "password", "password1", "password12", "password123", "password1234", "password12345",
        "passw0rd", "p@ssw0rd", "p@ssword", "passwordpassword", "mypassword", "newpassword",
        "changeme", "secret", "letmein", "welcome", "iloveyou", "trustno1", "admin", "administrator",
        "qwerty", "qwertyuiop", "qwertzuiop", "azertyuiop", "asdfghjkl", "zxcvbnm", "qazwsxedc",
        "1qaz2wsx", "1q2w3e4r", "1q2w3e4r5t", "q1w2e3r4t5", "zaq12wsx", "abc123", "abcdefghij",
        "abcdefghijklmnopqrstuvwxyz", "123456", "1234567", "12345678", "123456789", "1234567890",
        "12345678910", "0123456789", "0987654321", "9876543210", "1111111111", "0000000000",
        "123123123", "1234512345", "12341234", "football", "baseball", "sunshine", "princess",
        "dragon", "monkey", "shadow", "master", "superman", "batman", "starwars", "whatever",
        "freedom", "hello", "helloworld", "backup", "mybackup", "receipt", "receipts",
        "receiptvault", "iphone", "apple",
    ])

    /// Problems in display order; empty means the password is acceptable.
    static func problems(_ password: String, confirm: String) -> [String] {
        var out: [String] = []
        if password.count < BackupPassword.minimumLength {
            out.append("Use at least \(BackupPassword.minimumLength) characters")
        }
        if password != confirm {
            out.append("The passwords do not match")
        }
        if isTooCommon(password) {
            out.append("Too common")
        }
        return out
    }

    /// On the built-in list (also with trailing digits or symbols removed),
    /// or made of fewer than three different characters.
    private static func isTooCommon(_ password: String) -> Bool {
        let key = password.lowercased().filter { !$0.isWhitespace }
        guard !key.isEmpty else { return false }
        if BackupPassword.common.contains(key) || Set(key).count < 3 { return true }
        var base = key
        while let last = base.last, !last.isLetter { base.removeLast() }
        return !base.isEmpty && BackupPassword.common.contains(base)
    }
}
