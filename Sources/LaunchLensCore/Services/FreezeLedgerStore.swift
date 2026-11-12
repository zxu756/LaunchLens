import CryptoKit
import Darwin
import Foundation

public enum FreezeError: LocalizedError, Equatable {
    case unsupportedDomain(String)
    case appleSystemProtected(String)
    case missingPlistPath
    case plistNotFound(String)
    case snapshotCorrupted(String)
    case recordNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedDomain(let dom):
            return "Only User LaunchAgents can be frozen without root privileges (got \(dom))."
        case .appleSystemProtected(let label):
            return "Apple system service '\(label)' is protected and cannot be frozen."
        case .missingPlistPath:
            return "Item has no backing .plist path."
        case .plistNotFound(let path):
            return "LaunchAgent plist does not exist at \(path)."
        case .snapshotCorrupted(let label):
            return "Snapshot SHA-256 verification failed for '\(label)'; aborting restore."
        case .recordNotFound(let id):
            return "No frozen snapshot found with id '\(id)'."
        }
    }
}

public final class FreezeLedgerStore: @unchecked Sendable {
    public let vaultDirectory: URL
    public let snapshotsDirectory: URL
    public let ledgerFileURL: URL
    private let bootoutHandler: @Sendable (String) -> Void
    private let bootstrapHandler: @Sendable (String) -> Void

    public init(
        vaultDirectory: URL? = nil,
        bootoutHandler: (@Sendable (String) -> Void)? = nil,
        bootstrapHandler: (@Sendable (String) -> Void)? = nil
    ) {
        let base = vaultDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LaunchLens")
        self.vaultDirectory = base
        self.snapshotsDirectory = base.appendingPathComponent("Snapshots")
        self.ledgerFileURL = base.appendingPathComponent("ledger.json")

        self.bootoutHandler = bootoutHandler ?? { plistPath in
            let uid = getuid()
            Self.execLaunchctl(["bootout", "gui/\(uid)", plistPath])
        }
        self.bootstrapHandler = bootstrapHandler ?? { plistPath in
            let uid = getuid()
            Self.execLaunchctl(["bootstrap", "gui/\(uid)", plistPath])
        }
    }

    public func loadRecords() -> [FreezeSnapshotRecord] {
        guard let data = try? Data(contentsOf: ledgerFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FreezeSnapshotRecord].self, from: data)) ?? []
    }

    @discardableResult
    public func freeze(item: LaunchItem) throws -> FreezeSnapshotRecord {
        guard item.domain == .userAgent else {
            throw FreezeError.unsupportedDomain(item.domain.rawValue)
        }
        guard !item.isAppleSystem && !item.label.lowercased().hasPrefix("com.apple.") else {
            throw FreezeError.appleSystemProtected(item.label)
        }
        guard let plistPath = item.plistPath else {
            throw FreezeError.missingPlistPath
        }
        let fm = FileManager.default
        let srcURL = URL(fileURLWithPath: plistPath)
        guard fm.fileExists(atPath: srcURL.path) else {
            throw FreezeError.plistNotFound(plistPath)
        }

        try fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)

        let rawBytes = try Data(contentsOf: srcURL)
        let digest = sha256Hex(rawBytes)
        let recID = UUID().uuidString
        let safeLabel = item.label.replacingOccurrences(of: "/", with: "_")
        let snapURL = snapshotsDirectory.appendingPathComponent("\(safeLabel)-\(recID).plist")

        // 1. Write immutable byte-exact backup FIRST before touching launchd or original plist
        try rawBytes.write(to: snapURL, options: .atomic)

        // 2. Unload active service from user GUI domain
        bootoutHandler(srcURL.path)

        // 3. Remove active plist only after snapshot is verified on disk
        let verifyBytes = try Data(contentsOf: snapURL)
        guard sha256Hex(verifyBytes) == digest else {
            throw FreezeError.snapshotCorrupted(item.label)
        }
        try fm.removeItem(at: srcURL)

        // 4. Record in persistent ledger
        var records = loadRecords().filter { $0.label != item.label }
        let record = FreezeSnapshotRecord(
            id: recID,
            label: item.label,
            originalPlistPath: plistPath,
            snapshotFilePath: snapURL.path,
            sha256Hex: digest,
            frozenAt: Date(),
            rssBytesAtFreeze: item.rssBytes
        )
        records.insert(record, at: 0)
        try saveRecords(records)
        return record
    }

    public func restore(recordID: String) throws {
        var records = loadRecords()
        guard let idx = records.firstIndex(where: { $0.id == recordID || $0.label == recordID }) else {
            throw FreezeError.recordNotFound(recordID)
        }
        let rec = records[idx]
        let snapURL = URL(fileURLWithPath: rec.snapshotFilePath)
        let dstURL = URL(fileURLWithPath: rec.originalPlistPath)

        let snapBytes = try Data(contentsOf: snapURL)
        guard sha256Hex(snapBytes) == rec.sha256Hex else {
            throw FreezeError.snapshotCorrupted(rec.label)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try snapBytes.write(to: dstURL, options: .atomic)

        bootstrapHandler(dstURL.path)

        try? fm.removeItem(at: snapURL)
        records.remove(at: idx)
        try saveRecords(records)
    }

    public func terminateOrphan(pid: Int) -> Bool {
        guard pid > 1 else { return false }
        return Darwin.kill(pid_t(pid), SIGTERM) == 0
    }

    private func saveRecords(_ records: [FreezeSnapshotRecord]) throws {
        try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: ledgerFileURL, options: .atomic)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func execLaunchctl(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
