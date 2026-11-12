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
}

public struct FreezeSnapshotRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var originalPlistPath: String
    public var snapshotFilePath: String
    public var sha256Hex: String
    public var frozenAt: Date
    public var rssBytesAtFreeze: Int64

    public init(
        id: String = UUID().uuidString,
        label: String,
        originalPlistPath: String,
        snapshotFilePath: String,
        sha256Hex: String,
        frozenAt: Date = Date(),
        rssBytesAtFreeze: Int64 = 0
    ) {
        self.id = id
        self.label = label
        self.originalPlistPath = originalPlistPath
        self.snapshotFilePath = snapshotFilePath
        self.sha256Hex = sha256Hex
        self.frozenAt = frozenAt
        self.rssBytesAtFreeze = rssBytesAtFreeze
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
