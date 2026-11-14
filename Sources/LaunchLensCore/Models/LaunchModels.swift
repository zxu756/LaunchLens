import Foundation
import SwiftUI

public enum ServiceDomain: String, CaseIterable, Codable, Identifiable, Sendable {
    case userAgent = "User LaunchAgent"
    case orphanDaemon = "Orphan Daemon"
    case globalAgent = "Global LaunchAgent"
    case systemDaemon = "System LaunchDaemon"

    public var id: String { rawValue }

    public var shortBadge: String {
        switch self {
        case .userAgent: return "User agent"
        case .orphanDaemon: return "Orphan daemon"
        case .globalAgent: return "Global agent"
        case .systemDaemon: return "System daemon"
        }
    }

    @MainActor
    public func localizedBadge(_ localizer: AppLocalizer) -> String {
        switch self {
        case .userAgent: return localizer.L("User agent", "用户代理")
        case .orphanDaemon: return localizer.L("Orphan daemon", "孤儿进程")
        case .globalAgent: return localizer.L("Global agent", "全局代理")
        case .systemDaemon: return localizer.L("System daemon", "系统守护进程")
        }
    }

    public var color: Color {
        switch self {
        case .userAgent: return Color(red: 0.118, green: 0.337, blue: 0.627)     // Deep Cryo Cobalt #1E56A0
        case .orphanDaemon: return Color(red: 0.761, green: 0.255, blue: 0.114)  // Alert Terracotta #C2411D
        case .globalAgent: return Color(red: 0.392, green: 0.263, blue: 0.608)   // Mineral Plum #64439B
        case .systemDaemon: return Color(red: 0.333, green: 0.369, blue: 0.420)  // Graphite Slate #555E6B
        }
    }

    public var isReversibleByUser: Bool {
        self == .userAgent
    }
}

public struct LaunchItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var domain: ServiceDomain
    public var plistPath: String?
    public var programCommand: String
    public var pid: Int?
    public var rssBytes: Int64
    public var cpuPercent: Double
    public var listeningPorts: [Int]
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var lastExitStatus: Int?
    public var isAppleSystem: Bool
    public var isFrozen: Bool

    public init(
        id: String,
        label: String,
        domain: ServiceDomain,
        plistPath: String? = nil,
        programCommand: String,
        pid: Int? = nil,
        rssBytes: Int64 = 0,
        cpuPercent: Double = 0,
        listeningPorts: [Int] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        lastExitStatus: Int? = nil,
        isAppleSystem: Bool = false,
        isFrozen: Bool = false
    ) {
        self.id = id
        self.label = label
        self.domain = domain
        self.plistPath = plistPath
        self.programCommand = programCommand
        self.pid = pid
        self.rssBytes = max(0, rssBytes)
        self.cpuPercent = max(0, cpuPercent)
        self.listeningPorts = listeningPorts.sorted()
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.lastExitStatus = lastExitStatus
        self.isAppleSystem = isAppleSystem
        self.isFrozen = isFrozen
    }

    public var isRunning: Bool {
        (pid ?? 0) > 0
    }

    @MainActor
    public func localizedProgramCommand(_ localizer: AppLocalizer) -> String {
        if isFrozen {
            let fileName = plistPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "\(label).plist"
            return localizer.L(
                "Frozen snapshot (\(fileName))",
                "已冻结快照归档（\(fileName)）"
            )
        }
        return programCommand
    }
}

public enum FreezeRecordStatus: String, Codable, Equatable, Sendable {
    case inProgress
    case frozen

    @MainActor
    public func localizedLabel(_ localizer: AppLocalizer) -> String {
        switch self {
        case .inProgress:
            return localizer.L("In progress", "进行中")
        case .frozen:
            return localizer.L("Frozen", "已冻结")
        }
    }
}

public struct FreezeSnapshotRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var originalPlistPath: String
    public var snapshotFilePath: String
    public var stagedPlistPath: String?
    public var sha256Hex: String
    public var frozenAt: Date
    public var rssBytesAtFreeze: Int64
    public var status: FreezeRecordStatus

    public init(
        id: String = UUID().uuidString,
        label: String,
        originalPlistPath: String,
        snapshotFilePath: String,
        stagedPlistPath: String? = nil,
        sha256Hex: String,
        frozenAt: Date = Date(),
        rssBytesAtFreeze: Int64 = 0,
        status: FreezeRecordStatus = .frozen
    ) {
        self.id = id
        self.label = label
        self.originalPlistPath = originalPlistPath
        self.snapshotFilePath = snapshotFilePath
        self.stagedPlistPath = stagedPlistPath
        self.sha256Hex = sha256Hex
        self.frozenAt = frozenAt
        self.rssBytesAtFreeze = rssBytesAtFreeze
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case originalPlistPath
        case snapshotFilePath
        case stagedPlistPath
        case sha256Hex
        case frozenAt
        case rssBytesAtFreeze
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.originalPlistPath = try c.decode(String.self, forKey: .originalPlistPath)
        self.snapshotFilePath = try c.decode(String.self, forKey: .snapshotFilePath)
        self.stagedPlistPath = try c.decodeIfPresent(String.self, forKey: .stagedPlistPath)
        self.sha256Hex = try c.decode(String.self, forKey: .sha256Hex)
        self.frozenAt = try c.decode(Date.self, forKey: .frozenAt)
        self.rssBytesAtFreeze = try c.decodeIfPresent(Int64.self, forKey: .rssBytesAtFreeze) ?? 0
        self.status = try c.decodeIfPresent(FreezeRecordStatus.self, forKey: .status) ?? .frozen
    }
}

public struct RestoreConflictSummary: Codable, Equatable, Sendable {
    public var label: String
    public var existingPath: String
    public var backupPath: String
    public var existingBytes: Int
    public var backupBytes: Int
    public var existingSHA256: String
    public var backupSHA256: String
    public var diffSummary: String

    public init(
        label: String,
        existingPath: String,
        backupPath: String,
        existingBytes: Int,
        backupBytes: Int,
        existingSHA256: String,
        backupSHA256: String,
        diffSummary: String
    ) {
        self.label = label
        self.existingPath = existingPath
        self.backupPath = backupPath
        self.existingBytes = existingBytes
        self.backupBytes = backupBytes
        self.existingSHA256 = existingSHA256
        self.backupSHA256 = backupSHA256
        self.diffSummary = diffSummary
    }
}

public enum RestoreConflictResolution: String, Codable, Equatable, Sendable {
    case abort
    case overwriteExistingWithBackup
    case keepExistingAndClearRecord
}

public struct LedgerIntegrityReport: Codable, Equatable, Sendable {
    public var inProgressRecords: [FreezeSnapshotRecord]
    public var orphanedBackupPaths: [String]
    public var missingSnapshotRecords: [FreezeSnapshotRecord]
    public var corruptedLedgerError: String?

    public init(
        inProgressRecords: [FreezeSnapshotRecord] = [],
        orphanedBackupPaths: [String] = [],
        missingSnapshotRecords: [FreezeSnapshotRecord] = [],
        corruptedLedgerError: String? = nil
    ) {
        self.inProgressRecords = inProgressRecords
        self.orphanedBackupPaths = orphanedBackupPaths
        self.missingSnapshotRecords = missingSnapshotRecords
        self.corruptedLedgerError = corruptedLedgerError
    }

    public var hasIssues: Bool {
        !inProgressRecords.isEmpty
            || !orphanedBackupPaths.isEmpty
            || !missingSnapshotRecords.isEmpty
            || corruptedLedgerError != nil
    }
}

public struct LedgerRecoverySummary: Codable, Equatable, Sendable {
    public var recoveredInProgressLabels: [String]
    public var adoptedOrphanLabels: [String]
    public var cleanedDuplicatePaths: [String]

    public init(
        recoveredInProgressLabels: [String] = [],
        adoptedOrphanLabels: [String] = [],
        cleanedDuplicatePaths: [String] = []
    ) {
        self.recoveredInProgressLabels = recoveredInProgressLabels
        self.adoptedOrphanLabels = adoptedOrphanLabels
        self.cleanedDuplicatePaths = cleanedDuplicatePaths
    }
}

public struct LaunchSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var items: [LaunchItem]
    public var frozenRecords: [FreezeSnapshotRecord]

    public init(capturedAt: Date, items: [LaunchItem], frozenRecords: [FreezeSnapshotRecord]) {
        self.capturedAt = capturedAt
        self.items = items
        self.frozenRecords = frozenRecords
    }

    public var totalBackgroundRSSBytes: Int64 {
        items.filter { !$0.isAppleSystem }.map(\.rssBytes).reduce(0, +)
    }

    public var runningNonAppleCount: Int {
        items.filter { !$0.isAppleSystem && $0.isRunning }.count
    }

    public var orphanItems: [LaunchItem] {
        items.filter { $0.domain == .orphanDaemon }
    }

    public var orphanRSSBytes: Int64 {
        orphanItems.map(\.rssBytes).reduce(0, +)
    }

    public var totalListeningPortCount: Int {
        Set(items.filter { !$0.isAppleSystem }.flatMap(\.listeningPorts)).count
    }
}

public enum ByteFormatter {
    public static func memory(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        if mb >= 10.0 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.1f MB", mb)
    }
}
