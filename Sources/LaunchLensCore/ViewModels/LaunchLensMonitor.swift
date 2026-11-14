import AppKit
import Combine
import Foundation
import SwiftUI

public enum LaunchFilterTab: String, CaseIterable, Identifiable, Sendable {
    case all = "All services"
    case userAgents = "User agents"
    case orphans = "Orphan daemons"
    case globalAndSystem = "Global & system"
    case frozenVault = "Frozen vault"

    public var id: String { rawValue }

    @MainActor
    public func localizedTitle(_ localizer: AppLocalizer) -> String {
        switch self {
        case .all: return localizer.L("All services", "全部服务")
        case .userAgents: return localizer.L("User agents", "用户代理")
        case .orphans: return localizer.L("Orphan daemons", "孤儿进程")
        case .globalAndSystem: return localizer.L("Global & system", "全局与系统")
        case .frozenVault: return localizer.L("Frozen vault", "冻结保险库")
        }
    }
}

public enum LaunchStatusBanner: Equatable, Sendable {
    case frozenWithReclaim(label: String, reclaimed: String, shaPrefix: String)
    case frozenSaved(label: String, shaPrefix: String)
    case restored(label: String)
    case conflictKeptExisting(label: String)
    case missingSnapshot(label: String)
    case integrityRecovered(LedgerRecoverySummary)
    case freezeError(FreezeError)
    case custom(en: String, zh: String)

    @MainActor
    public func localizedText(_ localizer: AppLocalizer) -> String {
        switch self {
        case let .frozenWithReclaim(label, reclaimed, shaPrefix):
            return localizer.L(
                "Frozen \(label) — \(reclaimed) reclaimed, SHA-256 \(shaPrefix) verified.",
                "已冻结 \(label) — 已释放 \(reclaimed) 内存，SHA-256 (\(shaPrefix)) 校验通过。"
            )
        case let .frozenSaved(label, shaPrefix):
            return localizer.L(
                "Frozen \(label) — SHA-256 verified snapshot saved (\(shaPrefix)).",
                "已冻结 \(label) — SHA-256 校验快照已归档 (\(shaPrefix))。"
            )
        case let .restored(label):
            return localizer.L(
                "Restored \(label) back to LaunchAgents and bootstrapped.",
                "已将 \(label) 恢复至 LaunchAgents 并重新引导加载。"
            )
        case let .conflictKeptExisting(label):
            return localizer.L(
                "Kept existing plist for \(label) and cleared superseded frozen snapshot.",
                "已保留 \(label) 当前的新配置文件，并清理旧冻结快照记录。"
            )
        case let .missingSnapshot(label):
            return localizer.L(
                "No snapshot record found for \(label).",
                "未在快照保险库中找到 \(label) 的备份记录。"
            )
        case let .integrityRecovered(summary):
            let rCount = summary.recoveredInProgressLabels.count
            let oCount = summary.adoptedOrphanLabels.count
            return localizer.L(
                "Ledger recovery completed: \(rCount) interrupted transaction(s) resolved, \(oCount) orphan backup(s) recovered to vault.",
                "台账修复完成：已处理 \(rCount) 条中断事务，已将 \(oCount) 个孤儿备份纳入保险库。"
            )
        case let .freezeError(err):
            return err.localizedMessage(localizer)
        case let .custom(en, zh):
            return localizer.L(en, zh)
        }
    }
}

public enum PendingConfirmationAction: Identifiable, Equatable, Sendable {
    case freeze(LaunchItem)
    case restore(FreezeSnapshotRecord)
    case resolveRestoreConflict(record: FreezeSnapshotRecord, conflict: RestoreConflictSummary)
    case repairIntegrity(LedgerIntegrityReport)

    public var id: String {
        switch self {
        case .freeze(let item):
            return "freeze::\(item.id)"
        case .restore(let rec):
            return "restore::\(rec.id)"
        case .resolveRestoreConflict(let rec, _):
            return "conflict::\(rec.id)"
        case .repairIntegrity:
            return "repair::integrity"
        }
    }
}

public struct ActionConfirmationDetails: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var exactCommand: String
    public var sourcePathLabel: String
    public var sourcePath: String
    public var targetPathLabel: String
    public var targetPath: String
    public var diffSummary: String?
    public var confirmTitle: String
    public var cancelTitle: String

    public init(
        title: String,
        summary: String,
        exactCommand: String,
        sourcePathLabel: String,
        sourcePath: String,
        targetPathLabel: String,
        targetPath: String,
        diffSummary: String? = nil,
        confirmTitle: String,
        cancelTitle: String
    ) {
        self.title = title
        self.summary = summary
        self.exactCommand = exactCommand
        self.sourcePathLabel = sourcePathLabel
        self.sourcePath = sourcePath
        self.targetPathLabel = targetPathLabel
        self.targetPath = targetPath
        self.diffSummary = diffSummary
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }
}

@MainActor
public final class LaunchLensMonitor: ObservableObject {
    @Published public var snapshot: LaunchSnapshot
    @Published public var integrityReport: LedgerIntegrityReport
    @Published public var pendingConfirmation: PendingConfirmationAction?
    @Published public var selectedFilter: LaunchFilterTab = .all
    @Published public var searchQuery: String = ""
    @Published public var showAppleSystem: Bool = false
    @Published public var statusBanner: LaunchStatusBanner?
    @Published public var statusMessage: String?
    @Published public var statusIsError: Bool = false

    public let isStaticPreview: Bool
    public let ledgerStore: FreezeLedgerStore
    private let customPlistDirectories: [(URL, ServiceDomain)]?
    private var refreshTimer: Timer?

    public init(
        snapshot: LaunchSnapshot? = nil,
        ledgerStore: FreezeLedgerStore = FreezeLedgerStore(),
        plistDirectories: [(URL, ServiceDomain)]? = nil,
        isStaticPreview: Bool = false,
        autoRefreshSeconds: TimeInterval? = 10.0
    ) {
        self.ledgerStore = ledgerStore
        self.customPlistDirectories = plistDirectories
        self.isStaticPreview = isStaticPreview
        if let snapshot {
            self.snapshot = snapshot
            self.integrityReport = isStaticPreview
                ? LedgerIntegrityReport()
                : ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        } else {
            self.snapshot = LaunchScanner.scanLiveHost(ledgerStore: ledgerStore, plistDirectories: plistDirectories)
            self.integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        }

        if !isStaticPreview, let interval = autoRefreshSeconds, interval > 0 {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    public func refresh() {
        guard !isStaticPreview else { return }
        snapshot = LaunchScanner.scanLiveHost(ledgerStore: ledgerStore, plistDirectories: customPlistDirectories)
        integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
    }

    public func localizedStatusText(_ localizer: AppLocalizer) -> String? {
        if let statusBanner {
            return statusBanner.localizedText(localizer)
        }
        return statusMessage
    }

    public func localizedIntegrityBannerText(_ localizer: AppLocalizer) -> String? {
        guard integrityReport.hasIssues else { return nil }
        if let corrupt = integrityReport.corruptedLedgerError {
            return localizer.L(
                "Startup check detected corrupted ledger (\(corrupt)).",
                "启动自检发现台账文件损坏（\(corrupt)）。"
            )
        }
        let inProg = integrityReport.inProgressRecords.count
        let orphans = integrityReport.orphanedBackupPaths.count
        let missing = integrityReport.missingSnapshotRecords.count
        return localizer.L(
            "Startup integrity check: \(inProg) interrupted 'inProgress' transaction(s), \(orphans) orphaned backup plist(s), \(missing) missing backup(s).",
            "启动完整性自检：发现 \(inProg) 条未完成的「进行中」事务、\(orphans) 个无记录孤儿备份文件、\(missing) 条缺失备份记录。"
        )
    }

    public var filteredItems: [LaunchItem] {
        snapshot.items.filter { item in
            if !showAppleSystem && item.isAppleSystem {
                return false
            }
            switch selectedFilter {
            case .all:
                break
            case .userAgents:
                if item.domain != .userAgent { return false }
            case .orphans:
                if item.domain != .orphanDaemon { return false }
            case .globalAndSystem:
                if item.domain != .globalAgent && item.domain != .systemDaemon { return false }
            case .frozenVault:
                if !item.isFrozen { return false }
            }

            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return true }
            let portMatches = item.listeningPorts.contains { String($0).contains(trimmed) }
            return item.label.lowercased().contains(trimmed)
                || item.programCommand.lowercased().contains(trimmed)
                || (item.plistPath?.lowercased().contains(trimmed) ?? false)
                || portMatches
        }
    }

    public var menuBarSummaryText: String {
        ByteFormatter.memory(snapshot.totalBackgroundRSSBytes)
    }

    public var topMemoryConsumers: [LaunchItem] {
        Array(
            snapshot.items
                .filter { !$0.isAppleSystem && $0.rssBytes > 0 }
                .sorted { $0.rssBytes > $1.rssBytes }
                .prefix(5)
        )
    }

    // MARK: - M0 Item 5: Confirmation Request & Preview Flow

    public func requestFreeze(_ item: LaunchItem) {
        pendingConfirmation = .freeze(item)
    }

    public func requestRestore(_ record: FreezeSnapshotRecord) {
        pendingConfirmation = .restore(record)
    }

    public func requestRestoreByLabel(_ label: String) {
        let records = snapshot.frozenRecords.isEmpty ? ledgerStore.loadFrozenRecords() : snapshot.frozenRecords
        guard let record = records.first(where: { $0.label == label }) else {
            statusIsError = true
            statusBanner = .missingSnapshot(label: label)
            statusMessage = statusBanner?.localizedText(AppLocalizer(fixedLanguage: .en))
            return
        }
        pendingConfirmation = .restore(record)
    }

    public func requestRepairIntegrity() {
        guard integrityReport.hasIssues else { return }
        pendingConfirmation = .repairIntegrity(integrityReport)
    }

    public func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    public func confirmationDetails(
        for action: PendingConfirmationAction,
        localizer: AppLocalizer
    ) -> ActionConfirmationDetails {
        switch action {
        case .freeze(let item):
            let plistPath = item.plistPath ?? "<missing plist>"
            let cmd = ledgerStore.bootoutCommandPreview(plistPath: plistPath)
            return ActionConfirmationDetails(
                title: localizer.L("Confirm Freeze LaunchAgent", "确认冻结 LaunchAgent"),
                summary: localizer.L(
                    "LaunchLens will write and SHA-256 verify a backup copy, record an inProgress transaction, run launchctl bootout, and move the plist into the vault.",
                    "LaunchLens 将先写入备份并校验 SHA-256，记录「进行中」事务，执行 launchctl bootout 卸载服务，再将原 plist 移至保险库。"
                ),
                exactCommand: cmd,
                sourcePathLabel: localizer.L("Active plist", "当前配置文件"),
                sourcePath: plistPath,
                targetPathLabel: localizer.L("Snapshot vault", "快照保险库目录"),
                targetPath: ledgerStore.snapshotsDirectory.path,
                diffSummary: nil,
                confirmTitle: localizer.L("Freeze Service", "确认冻结"),
                cancelTitle: localizer.L("Cancel", "取消")
            )

        case .restore(let rec):
            let cmd = ledgerStore.bootstrapCommandPreview(plistPath: rec.originalPlistPath)
            return ActionConfirmationDetails(
                title: localizer.L("Confirm Restore LaunchAgent", "确认恢复 LaunchAgent"),
                summary: localizer.L(
                    "LaunchLens will verify backup SHA-256 (\(rec.sha256Hex.prefix(12))), refuse silent overwrite if a file already exists, copy the plist back, and run launchctl bootstrap.",
                    "LaunchLens 将先校验备份 SHA-256（\(rec.sha256Hex.prefix(12))），检测目标路径冲突（不静默覆盖），写回原字节并执行 launchctl bootstrap。"
                ),
                exactCommand: cmd,
                sourcePathLabel: localizer.L("Verified backup", "已校验备份文件"),
                sourcePath: rec.snapshotFilePath,
                targetPathLabel: localizer.L("Restore destination", "恢复目标路径"),
                targetPath: rec.originalPlistPath,
                diffSummary: nil,
                confirmTitle: localizer.L("Restore & Bootstrap", "确认恢复并加载"),
                cancelTitle: localizer.L("Cancel", "取消")
            )

        case let .resolveRestoreConflict(rec, conflict):
            let cmd = ledgerStore.bootstrapCommandPreview(plistPath: rec.originalPlistPath)
            return ActionConfirmationDetails(
                title: localizer.L("Target Plist Conflict Detected", "检测到目标配置文件冲突"),
                summary: localizer.L(
                    "A file already exists at the restore path (\(conflict.existingBytes) B, sha256:\(conflict.existingSHA256.prefix(10))) vs frozen backup (\(conflict.backupBytes) B, sha256:\(conflict.backupSHA256.prefix(10))). Choose how to proceed:",
                    "恢复目标路径已存在同名文件（\(conflict.existingBytes) 字节，sha256:\(conflict.existingSHA256.prefix(10))），与冻结备份（\(conflict.backupBytes) 字节，sha256:\(conflict.backupSHA256.prefix(10))）不一致。请选择处理方式："
                ),
                exactCommand: cmd,
                sourcePathLabel: localizer.L("Frozen backup", "冻结备份文件"),
                sourcePath: conflict.backupPath,
                targetPathLabel: localizer.L("Existing file on disk", "磁盘现有文件"),
                targetPath: conflict.existingPath,
                diffSummary: conflict.diffSummary,
                confirmTitle: localizer.L("Overwrite with Backup & Bootstrap", "用冻结备份覆盖并加载"),
                cancelTitle: localizer.L("Cancel (Keep Untouched)", "取消（保持现状）")
            )

        case .repairIntegrity(let report):
            let labels = report.inProgressRecords.map(\.label).joined(separator: ", ")
            let cmdNote = report.inProgressRecords.isEmpty
                ? localizer.L("Adopt \(report.orphanedBackupPaths.count) orphaned backup plist(s) into ledger.json", "将 \(report.orphanedBackupPaths.count) 个孤儿备份 plist 纳入 ledger.json")
                : "/bin/launchctl bootstrap gui/\(ledgerStore.uid) <interrupted-plist> (\(labels))"
            return ActionConfirmationDetails(
                title: localizer.L("Repair Interrupted Ledger & Orphan Backups", "修复中断事务与孤儿备份"),
                summary: localizer.L(
                    "Recovers \(report.inProgressRecords.count) interrupted inProgress transaction(s) and adopts \(report.orphanedBackupPaths.count) untracked backup plist(s) into the snapshot vault without deleting user data.",
                    "无损恢复 \(report.inProgressRecords.count) 条中断的「进行中」事务，并将 \(report.orphanedBackupPaths.count) 个未登记的孤儿备份纳入快照保险库，不删除用户数据。"
                ),
                exactCommand: cmdNote,
                sourcePathLabel: localizer.L("Snapshots directory", "快照备份目录"),
                sourcePath: ledgerStore.snapshotsDirectory.path,
                targetPathLabel: localizer.L("Ledger file", "台账文件"),
                targetPath: ledgerStore.ledgerFileURL.path,
                diffSummary: nil,
                confirmTitle: localizer.L("Repair / Recover", "修复 / 恢复"),
                cancelTitle: localizer.L("Cancel", "取消")
            )
        }
    }

    public func confirmPendingAction() {
        guard let action = pendingConfirmation else { return }
        pendingConfirmation = nil

        switch action {
        case .freeze(let item):
            executeFreezeConfirmed(item)
        case .restore(let record):
            executeRestoreConfirmed(record, conflictResolution: .abort)
        case .resolveRestoreConflict(let record, _):
            executeRestoreConfirmed(record, conflictResolution: .overwriteExistingWithBackup)
        case .repairIntegrity:
            executeRepairIntegrityConfirmed()
        }
    }

    public func resolveConflictKeepExisting() {
        guard case let .resolveRestoreConflict(record, _) = pendingConfirmation else { return }
        pendingConfirmation = nil
        executeRestoreConfirmed(record, conflictResolution: .keepExistingAndClearRecord)
    }

    // MARK: - Direct Validated Execution (Used after confirmation)

    public func freeze(_ item: LaunchItem) {
        executeFreezeConfirmed(item)
    }

    public func restore(
        _ record: FreezeSnapshotRecord,
        conflictResolution: RestoreConflictResolution = .abort
    ) {
        executeRestoreConfirmed(record, conflictResolution: conflictResolution)
    }

    public func repairLedgerIntegrity() {
        executeRepairIntegrityConfirmed()
    }

    private func executeFreezeConfirmed(_ item: LaunchItem) {
        do {
            let rec = try ledgerStore.freeze(item: item)
            let prefix = String(rec.sha256Hex.prefix(10))
            statusIsError = false
            statusBanner = .frozenSaved(label: rec.label, shaPrefix: prefix)
            statusMessage = statusBanner?.localizedText(AppLocalizer(fixedLanguage: .en))
            refresh()
        } catch let freezeErr as FreezeError {
            statusIsError = true
            statusBanner = .freezeError(freezeErr)
            statusMessage = freezeErr.errorDescription
            integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        } catch {
            statusIsError = true
            statusBanner = .custom(en: error.localizedDescription, zh: error.localizedDescription)
            statusMessage = error.localizedDescription
            integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        }
    }

    private func executeRestoreConfirmed(
        _ record: FreezeSnapshotRecord,
        conflictResolution: RestoreConflictResolution
    ) {
        do {
            try ledgerStore.restore(recordID: record.id, conflictResolution: conflictResolution)
            statusIsError = false
            if conflictResolution == .keepExistingAndClearRecord {
                statusBanner = .conflictKeptExisting(label: record.label)
            } else {
                statusBanner = .restored(label: record.label)
            }
            statusMessage = statusBanner?.localizedText(AppLocalizer(fixedLanguage: .en))
            refresh()
        } catch let freezeErr as FreezeError {
            statusIsError = true
            statusBanner = .freezeError(freezeErr)
            statusMessage = freezeErr.errorDescription
            if case .restoreTargetConflict(let conflict) = freezeErr, conflictResolution == .abort {
                pendingConfirmation = .resolveRestoreConflict(record: record, conflict: conflict)
            }
            integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        } catch {
            statusIsError = true
            statusBanner = .custom(en: error.localizedDescription, zh: error.localizedDescription)
            statusMessage = error.localizedDescription
            integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        }
    }

    private func executeRepairIntegrityConfirmed() {
        do {
            let summary = try ledgerStore.recoverInterruptedAndOrphanBackups()
            statusIsError = false
            statusBanner = .integrityRecovered(summary)
            statusMessage = statusBanner?.localizedText(AppLocalizer(fixedLanguage: .en))
            refresh()
        } catch let freezeErr as FreezeError {
            statusIsError = true
            statusBanner = .freezeError(freezeErr)
            statusMessage = freezeErr.errorDescription
            integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        } catch {
            statusIsError = true
            statusBanner = .custom(en: error.localizedDescription, zh: error.localizedDescription)
            statusMessage = error.localizedDescription
            integrityReport = ledgerStore.auditInterruptedTransactionsAndOrphanBackups()
        }
    }

    public static func displayPath(_ raw: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, raw.hasPrefix(home) {
            return "~" + raw.dropFirst(home.count)
        }
        return raw
    }

    // MARK: - Deterministic Demo Preview (Explicit --demo / ScreenshotExporter only)

    public static func preview() -> LaunchLensMonitor {
        let now = Date(timeIntervalSince1970: 1_794_556_800)
        let frozenRecord = FreezeSnapshotRecord(
            id: "snap-01",
            label: "com.updater.telemetry-helper",
            originalPlistPath: "~/Library/LaunchAgents/com.updater.telemetry-helper.plist",
            snapshotFilePath: "~/Library/Application Support/LaunchLens/Snapshots/com.updater.telemetry-helper-snap-01.plist",
            sha256Hex: "9f4c82b1e07a3d56c4189a02e7b11f88c04d6321a8e5b9704c2d193f80a65e12",
            frozenAt: now.addingTimeInterval(-7200),
            rssBytesAtFreeze: 432_013_312,
            status: .frozen
        )

        let items: [LaunchItem] = [
            LaunchItem(
                id: "user::ai.local.whisper-voice-agent",
                label: "ai.local.whisper-voice-agent",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/ai.local.whisper-voice-agent.plist",
                programCommand: "/opt/homebrew/bin/whisper-server --model large-v3-turbo --port 8787",
                pid: 31402,
                rssBytes: 5_175_435_264,
                cpuPercent: 6.4,
                listeningPorts: [8787],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "user::io.ollama.runner",
                label: "io.ollama.runner",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/io.ollama.runner.plist",
                programCommand: "/opt/homebrew/opt/ollama/bin/ollama serve",
                pid: 19844,
                rssBytes: 2_834_678_415,
                cpuPercent: 1.8,
                listeningPorts: [11434],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "orphan::48210",
                label: "node / mcp-server-playwright (PID 48210)",
                domain: .orphanDaemon,
                plistPath: nil,
                programCommand: "node /opt/homebrew/lib/node_modules/@playwright/mcp/cli.js --port 9222",
                pid: 48210,
                rssBytes: 935_329_792,
                cpuPercent: 3.1,
                listeningPorts: [9222]
            ),
            LaunchItem(
                id: "system::com.docker.vmnetd",
                label: "com.docker.vmnetd",
                domain: .systemDaemon,
                plistPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist",
                programCommand: "/Library/PrivilegedHelperTools/com.docker.vmnetd",
                pid: 612,
                rssBytes: 679_477_248,
                cpuPercent: 0.5,
                listeningPorts: [],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "orphan::51094",
                label: "uvx / scholar-mcp (PID 51094)",
                domain: .orphanDaemon,
                plistPath: nil,
                programCommand: "python3 -m scholar_mcp.server --transport stdio",
                pid: 51094,
                rssBytes: 333_447_168,
                cpuPercent: 0.4,
                listeningPorts: []
            ),
            LaunchItem(
                id: "user::homebrew.mxcl.postgresql@16",
                label: "homebrew.mxcl.postgresql@16",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist",
                programCommand: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16",
                pid: 1409,
                rssBytes: 255_852_544,
                cpuPercent: 0.2,
                listeningPorts: [5432],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "global::org.pqrs.karabiner.agent",
                label: "org.pqrs.karabiner.agent",
                domain: .globalAgent,
                plistPath: "/Library/LaunchAgents/org.pqrs.karabiner.agent.plist",
                programCommand: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_grabber",
                pid: 988,
                rssBytes: 96_468_992,
                cpuPercent: 0.3,
                listeningPorts: [],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "frozen::com.updater.telemetry-helper",
                label: "com.updater.telemetry-helper",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/com.updater.telemetry-helper.plist",
                programCommand: "Frozen snapshot (com.updater.telemetry-helper.plist)",
                pid: nil,
                rssBytes: 0,
                cpuPercent: 0.0,
                listeningPorts: [],
                runAtLoad: false,
                keepAlive: false,
                isFrozen: true
            )
        ]

        let inertStore = FreezeLedgerStore(
            vaultDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("LaunchLensInertPreview"),
            userLaunchAgentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("LaunchLensInertAgents")
        )
        let snap = LaunchSnapshot(capturedAt: now, items: items, frozenRecords: [frozenRecord])
        let monitor = LaunchLensMonitor(
            snapshot: snap,
            ledgerStore: inertStore,
            isStaticPreview: true,
            autoRefreshSeconds: nil
        )
        monitor.statusBanner = .custom(
            en: "[DEMO] Synthetic preview dataset — Frozen com.updater.telemetry-helper (412 MB reclaimed, SHA-256 9f4c82b1e0 verified).",
            zh: "[演示数据] 静态示例数据集 — 已冻结 com.updater.telemetry-helper（释放 412 MB，SHA-256 9f4c82b1e0 校验通过）。"
        )
        monitor.statusMessage = monitor.statusBanner?.localizedText(AppLocalizer(fixedLanguage: .en))
        return monitor
    }
}

public enum ScreenshotExporter {
    @MainActor
    public static func exportMarketingScreenshots(
        to directory: URL,
        language: AppLanguage = .en
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = LaunchLensMonitor.preview()
        let localizer = AppLocalizer(fixedLanguage: language)
        let suffix = (language == .zhHans) ? "-zh" : ""

        let mainView = MainDashboardView(monitor: monitor, localizer: localizer)
            .environment(\.locale, language.locale)
            .frame(width: 1115, height: 735)
            .environment(\.colorScheme, .light)

        try renderPNG(view: mainView, to: directory.appendingPathComponent("screenshot-main\(suffix).png"))

        let popoverView = MenuBarPopoverView(
            monitor: monitor,
            localizer: localizer,
            onOpenDashboard: {},
            onQuit: {}
        )
        .environment(\.locale, language.locale)
        .frame(width: 420, height: 438)
        .padding(14)
        .background(Color(red: 0.925, green: 0.918, blue: 0.890))
        .environment(\.colorScheme, .light)

        try renderPNG(view: popoverView, to: directory.appendingPathComponent("screenshot-menubar\(suffix).png"))
    }

    @MainActor
    public static func renderPNG<V: View>(view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = true
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "LaunchLens.ScreenshotExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to rasterize SwiftUI view to 2x PNG"
            ])
        }
        try png.write(to: url, options: .atomic)
    }
}
