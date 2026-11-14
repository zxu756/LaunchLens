import CryptoKit
import Darwin
import Foundation

public struct LaunchctlResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol LaunchctlExecuting: Sendable {
    func runLaunchctl(_ arguments: [String]) -> LaunchctlResult
}

public struct SystemLaunchctlExecutor: LaunchctlExecuting {
    public let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/bin/launchctl")) {
        self.executableURL = executableURL
    }

    public func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return LaunchctlResult(
                exitCode: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return LaunchctlResult(
                exitCode: 127,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }
}

private struct ClosureLaunchctlExecutor: LaunchctlExecuting {
    let bootoutHandler: @Sendable (String) -> Void
    let bootstrapHandler: @Sendable (String) -> Void

    func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        guard let sub = arguments.first, let plistPath = arguments.last else {
            return LaunchctlResult(exitCode: 2, stderr: "Invalid launchctl arguments")
        }
        switch sub {
        case "print":
            return LaunchctlResult(exitCode: 113, stderr: "Service not loaded")
        case "bootout":
            bootoutHandler(plistPath)
            return LaunchctlResult(exitCode: 0)
        case "bootstrap":
            bootstrapHandler(plistPath)
            return LaunchctlResult(exitCode: 0)
        default:
            return LaunchctlResult(exitCode: 2, stderr: "Unsupported launchctl subcommand: \(sub)")
        }
    }
}

public enum FreezeError: LocalizedError, Equatable {
    case unsupportedDomain(String)
    case appleSystemProtected(String)
    case missingPlistPath
    case plistNotFound(String)
    case symlinkRejected(String)
    case notRegularFile(String)
    case outsideLaunchAgentsDirectory(path: String, requiredDirectory: String)
    case alreadyFrozen(label: String, status: FreezeRecordStatus)
    case ledgerCorruptedOrUnreadable(path: String, detail: String)
    case backupWriteFailed(label: String, detail: String)
    case ledgerWriteFailed(step: String, detail: String, stateSummaryEN: String, stateSummaryZH: String)
    case bootoutFailed(label: String, exitCode: Int32, stderr: String, originalPath: String)
    case stageMoveFailed(label: String, detail: String, rollbackBootstrapped: Bool, originalPath: String)
    case snapshotMissing(label: String, path: String)
    case snapshotCorrupted(String)
    case recordNotFound(String)
    case restoreTargetConflict(RestoreConflictSummary)
    case bootstrapFailed(label: String, exitCode: Int32, stderr: String, snapshotPath: String)
    case recoveryBootstrapFailed(label: String, exitCode: Int32, stderr: String, plistPath: String, snapshotPath: String)
    case restoreWriteFailed(label: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedDomain(let dom):
            return "[Freeze Precondition] Only User LaunchAgents can be frozen without root privileges (got \(dom)). State: service and plist untouched."
        case .appleSystemProtected(let label):
            return "[Freeze Precondition] Apple system service '\(label)' is protected and cannot be frozen. State: service and plist untouched."
        case .missingPlistPath:
            return "[Freeze Precondition] Item has no backing .plist path. State: nothing modified."
        case .plistNotFound(let path):
            return "[Freeze Precondition] LaunchAgent plist does not exist at \(path). State: nothing modified."
        case .symlinkRejected(let path):
            return "[Freeze Precondition] Symbolic link plist rejected at \(path); only regular files inside LaunchAgents may be frozen. State: symlink and target untouched."
        case .notRegularFile(let path):
            return "[Freeze Precondition] Path \(path) is not a regular file. State: nothing modified."
        case let .outsideLaunchAgentsDirectory(path, requiredDir):
            return "[Freeze Precondition] Refusing to freeze \(path): canonical parent directory is outside \(requiredDir). State: file untouched."
        case let .alreadyFrozen(label, status):
            return "[Freeze Precondition] '\(label)' already has an active ledger entry (\(status.rawValue)). State: existing snapshot and service untouched."
        case let .ledgerCorruptedOrUnreadable(path, detail):
            return "[Ledger Read] Cannot read or decode ledger at \(path) (\(detail)). State: operation aborted before any changes."
        case let .backupWriteFailed(label, detail):
            return "[Freeze Step 2/6 Backup] Failed to write/verify snapshot backup for '\(label)' (\(detail)). State: launchctl bootout was NOT run; original plist untouched."
        case let .ledgerWriteFailed(step, detail, stateEN, _):
            return "[Freeze \(step)] Failed to persist ledger (\(detail)). State: \(stateEN)"
        case let .bootoutFailed(label, exitCode, stderr, originalPath):
            let errNote = stderr.isEmpty ? "no stderr" : stderr
            return "[Freeze Step 4/6 launchctl bootout] bootout failed for '\(label)' with exit code \(exitCode) (\(errNote)). State: rolled back inProgress record and backup; original plist left intact at \(originalPath)."
        case let .stageMoveFailed(label, detail, rollbackBootstrapped, originalPath):
            let rb = rollbackBootstrapped ? "launchctl bootstrap rollback succeeded" : "launchctl bootstrap rollback failed"
            return "[Freeze Step 5/6 Stage Move] Failed to move plist for '\(label)' (\(detail)). State: \(rb), temporary backup and inProgress record cleaned; original plist remains at \(originalPath)."
        case let .snapshotMissing(label, path):
            return "[Restore Step 1/4 Verify Backup] Backup file for '\(label)' is missing at \(path). State: target LaunchAgents directory untouched and ledger record preserved."
        case .snapshotCorrupted(let label):
            return "[Restore Step 1/4 Verify SHA-256] Snapshot SHA-256 verification failed for '\(label)'; aborting restore. State: target plist NOT written and launchctl bootstrap NOT executed."
        case .recordNotFound(let id):
            return "[Restore Precondition] No frozen snapshot found with id or label '\(id)'. State: nothing modified."
        case .restoreTargetConflict(let summary):
            return "[Restore Step 2/4 Target Conflict] Refusing to overwrite existing file for '\(summary.label)'. Existing file: \(summary.existingPath) (\(summary.existingBytes) bytes, sha256:\(summary.existingSHA256.prefix(12))). Frozen backup: \(summary.backupPath) (\(summary.backupBytes) bytes, sha256:\(summary.backupSHA256.prefix(12))). Diff: \(summary.diffSummary). State: existing file, backup, and ledger record all preserved."
        case let .bootstrapFailed(label, exitCode, stderr, snapshotPath):
            let errNote = stderr.isEmpty ? "no stderr" : stderr
            return "[Restore Step 3/4 launchctl bootstrap] bootstrap failed for '\(label)' with exit code \(exitCode) (\(errNote)). State: newly placed target copy removed; verified backup (\(snapshotPath)) and frozen ledger record preserved."
        case let .recoveryBootstrapFailed(label, exitCode, stderr, plistPath, snapshotPath):
            let errNote = stderr.isEmpty ? "no stderr" : stderr
            return "[Startup Recovery launchctl bootstrap] bootstrap failed for '\(label)' with exit code \(exitCode) (\(errNote)). State: plist (\(plistPath)), verified backup (\(snapshotPath)), and inProgress recovery record preserved."
        case let .restoreWriteFailed(label, detail):
            return "[Restore Step 2/4 Write Target] Failed writing restored plist for '\(label)' (\(detail)). State: backup and frozen ledger record preserved."
        }
    }

    @MainActor
    public func localizedMessage(_ localizer: AppLocalizer) -> String {
        switch self {
        case .unsupportedDomain(let dom):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] 无需 root 权限仅可冻结用户级 LaunchAgents（当前为 \(dom)）。当前状态：服务与原 plist 未做任何修改。"
            )
        case .appleSystemProtected(let label):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] Apple 系统服务「\(label)」受保护不可冻结。当前状态：服务与原 plist 未做任何修改。"
            )
        case .missingPlistPath:
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] 该服务缺少关联的 .plist 路径。当前状态：未做任何修改。"
            )
        case .plistNotFound(let path):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] 未找到 LaunchAgent 配置文件：\(path)。当前状态：未做任何修改。"
            )
        case .symlinkRejected(let path):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] 已拒绝符号链接 plist（\(path)）：仅允许冻结 LaunchAgents 目录下的普通文件。当前状态：符号链接与目标文件均未改动。"
            )
        case .notRegularFile(let path):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] 路径 \(path) 不是普通文件。当前状态：未做任何修改。"
            )
        case let .outsideLaunchAgentsDirectory(path, requiredDir):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查] 已拒绝冻结 \(path)：其解析后的所在目录不在 \(requiredDir) 下。当前状态：原文件未改动。"
            )
        case let .alreadyFrozen(label, status):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结前置检查]「\(label)」在台账中已存在记录（状态：\(status.localizedLabel(localizer))），拒绝重复冻结。当前状态：原有快照与服务未改动。"
            )
        case let .ledgerCorruptedOrUnreadable(path, detail):
            return localizer.L(
                self.errorDescription ?? "",
                "[台账读取] 无法读取或解析台账文件 \(path)（\(detail)）。当前状态：已在修改任何文件前中止操作。"
            )
        case let .backupWriteFailed(label, detail):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结步骤 2/6 写入备份] 为「\(label)」写入或校验快照失败（\(detail)）。当前状态：未调用 launchctl bootout，原 plist 完好未动。"
            )
        case let .ledgerWriteFailed(step, detail, _, stateZH):
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结 \(step)] 写入台账失败（\(detail)）。当前状态：\(stateZH)"
            )
        case let .bootoutFailed(label, exitCode, stderr, originalPath):
            let errNote = stderr.isEmpty ? "无错误输出" : stderr
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结步骤 4/6 launchctl bootout] 卸载「\(label)」失败，退出码 \(exitCode)（\(errNote)）。当前状态：已清理「进行中」台账记录与临时备份，原 plist 仍完好保留在 \(originalPath)。"
            )
        case let .stageMoveFailed(label, detail, rollbackBootstrapped, originalPath):
            let rb = rollbackBootstrapped ? "已重新执行 launchctl bootstrap 回滚加载" : "launchctl bootstrap 回滚加载失败"
            return localizer.L(
                self.errorDescription ?? "",
                "[冻结步骤 5/6 暂存移出] 移出「\(label)」原 plist 失败（\(detail)）。当前状态：\(rb)，已清理临时备份与「进行中」记录，原 plist 仍在 \(originalPath)。"
            )
        case let .snapshotMissing(label, path):
            return localizer.L(
                self.errorDescription ?? "",
                "[恢复步骤 1/4 校验备份]「\(label)」的备份文件缺失（\(path)）。当前状态：目标目录未改动，台账记录已保留。"
            )
        case .snapshotCorrupted(let label):
            return localizer.L(
                self.errorDescription ?? "",
                "[恢复步骤 1/4 SHA-256 校验]「\(label)」备份快照 SHA-256 完整性校验失败，已中止恢复。当前状态：未写入目标 plist，未调用 launchctl bootstrap。"
            )
        case .recordNotFound(let id):
            return localizer.L(
                self.errorDescription ?? "",
                "[恢复前置检查] 未找到标识为「\(id)」的冻结记录。当前状态：未做任何修改。"
            )
        case .restoreTargetConflict(let summary):
            return localizer.L(
                self.errorDescription ?? "",
                "[恢复步骤 2/4 目标文件冲突] 目标位置已存在同名文件，拒绝静默覆盖「\(summary.label)」。目标现有文件：\(summary.existingPath)（\(summary.existingBytes) 字节，sha256:\(summary.existingSHA256.prefix(12))）；冻结备份文件：\(summary.backupPath)（\(summary.backupBytes) 字节，sha256:\(summary.backupSHA256.prefix(12))）。差异摘要：\(summary.diffSummary)。当前状态：现有文件、备份与台账记录均完整保留。"
            )
        case let .bootstrapFailed(label, exitCode, stderr, snapshotPath):
            let errNote = stderr.isEmpty ? "无错误输出" : stderr
            return localizer.L(
                self.errorDescription ?? "",
                "[恢复步骤 3/4 launchctl bootstrap] 重新加载「\(label)」失败，退出码 \(exitCode)（\(errNote)）。当前状态：已移除刚放置的副本，完整保留备份文件（\(snapshotPath)）与台账记录。"
            )
        case let .recoveryBootstrapFailed(label, exitCode, stderr, plistPath, snapshotPath):
            let errNote = stderr.isEmpty ? "无错误输出" : stderr
            return localizer.L(
                self.errorDescription ?? "",
                "[启动恢复 launchctl bootstrap] 重新加载「\(label)」失败，退出码 \(exitCode)（\(errNote)）。当前状态：配置文件（\(plistPath)）、备份文件（\(snapshotPath)）与「进行中」恢复记录均完整保留。"
            )
        case let .restoreWriteFailed(label, detail):
            return localizer.L(
                self.errorDescription ?? "",
                "[恢复步骤 2/4 写回目标] 写回「\(label)」配置文件失败（\(detail)）。当前状态：备份文件与台账记录完整保留。"
            )
        }
    }
}

public final class FreezeLedgerStore: @unchecked Sendable {
    public let vaultDirectory: URL
    public let snapshotsDirectory: URL
    public let stagingDirectory: URL
    public let ledgerFileURL: URL
    public let userLaunchAgentsDirectory: URL
    public let uid: uid_t

    private let launchctlExecutor: any LaunchctlExecuting
    private let ledgerWriteHook: (@Sendable (_ writeSequence: Int, _ records: [FreezeSnapshotRecord]) throws -> Void)?
    private let writeLock = NSLock()
    private var writeCounter: Int = 0

    public init(
        vaultDirectory: URL? = nil,
        userLaunchAgentsDirectory: URL? = nil,
        uid: uid_t = getuid(),
        launchctlExecutor: (any LaunchctlExecuting)? = nil,
        ledgerWriteHook: (@Sendable (_ writeSequence: Int, _ records: [FreezeSnapshotRecord]) throws -> Void)? = nil
    ) {
        let base = vaultDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LaunchLens")
        self.vaultDirectory = base
        self.snapshotsDirectory = base.appendingPathComponent("Snapshots")
        self.stagingDirectory = base.appendingPathComponent("Staged")
        self.ledgerFileURL = base.appendingPathComponent("ledger.json")
        self.userLaunchAgentsDirectory = userLaunchAgentsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        self.uid = uid
        self.launchctlExecutor = launchctlExecutor ?? SystemLaunchctlExecutor()
        self.ledgerWriteHook = ledgerWriteHook
    }

    public convenience init(
        vaultDirectory: URL? = nil,
        userLaunchAgentsDirectory: URL? = nil,
        bootoutHandler: @escaping @Sendable (String) -> Void,
        bootstrapHandler: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            vaultDirectory: vaultDirectory,
            userLaunchAgentsDirectory: userLaunchAgentsDirectory,
            launchctlExecutor: ClosureLaunchctlExecutor(
                bootoutHandler: bootoutHandler,
                bootstrapHandler: bootstrapHandler
            )
        )
    }

    // MARK: - Read-Only Queries (Never create directories on disk)

    public func loadRecords() -> [FreezeSnapshotRecord] {
        (try? loadRecordsStrict()) ?? []
    }

    public func loadFrozenRecords() -> [FreezeSnapshotRecord] {
        loadRecords().filter { $0.status == .frozen }
    }

    public func loadRecordsStrict() throws -> [FreezeSnapshotRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ledgerFileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: ledgerFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([FreezeSnapshotRecord].self, from: data)
        } catch {
            throw FreezeError.ledgerCorruptedOrUnreadable(
                path: ledgerFileURL.path,
                detail: error.localizedDescription
            )
        }
    }

    // MARK: - Exact Command Preview Helpers (for UI Confirmation Dialogs)

    public func bootoutCommandPreview(plistPath: String) -> String {
        "/bin/launchctl bootout gui/\(uid) \"\(plistPath)\""
    }

    public func bootstrapCommandPreview(plistPath: String) -> String {
        "/bin/launchctl bootstrap gui/\(uid) \"\(plistPath)\""
    }

    // MARK: - M0 Item 1 & Item 4: Rollback-Safe Transactional Freeze

    @discardableResult
    public func freeze(item: LaunchItem) throws -> FreezeSnapshotRecord {
        // Step 1/6: Precondition & path containment checks
        guard item.domain == .userAgent else {
            throw FreezeError.unsupportedDomain(item.domain.rawValue)
        }
        guard !item.isAppleSystem && !item.label.lowercased().hasPrefix("com.apple.") else {
            throw FreezeError.appleSystemProtected(item.label)
        }
        guard let rawPlistPath = item.plistPath, !rawPlistPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FreezeError.missingPlistPath
        }

        let expandedPath = (rawPlistPath as NSString).expandingTildeInPath
        let rawURL = URL(fileURLWithPath: expandedPath)

        // lstat BEFORE resolving leaf symlinks so symbolic links are rejected immediately
        var st = stat()
        if lstat(rawURL.path, &st) != 0 {
            if errno == ENOENT {
                throw FreezeError.plistNotFound(rawPlistPath)
            }
            let msg = String(cString: strerror(errno))
            throw FreezeError.backupWriteFailed(label: item.label, detail: msg)
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            throw FreezeError.symlinkRejected(rawPlistPath)
        }
        guard fileType == S_IFREG else {
            throw FreezeError.notRegularFile(rawPlistPath)
        }

        // Canonicalize parent directory and verify strict containment inside userLaunchAgentsDirectory
        let canonicalParent = rawURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoot = canonicalizedDirectoryPath(userLaunchAgentsDirectory)
        guard canonicalParent == allowedRoot || canonicalParent.hasPrefix(allowedRoot + "/") else {
            throw FreezeError.outsideLaunchAgentsDirectory(
                path: rawPlistPath,
                requiredDirectory: userLaunchAgentsDirectory.path
            )
        }
        // Also ensure raw path didn't traverse via '..' or symlinked intermediate directory inside LaunchAgents
        let canonicalSrcURL = URL(fileURLWithPath: canonicalParent).appendingPathComponent(rawURL.lastPathComponent)
        var canonicalStat = stat()
        guard lstat(canonicalSrcURL.path, &canonicalStat) == 0,
              (canonicalStat.st_mode & S_IFMT) == S_IFREG,
              canonicalStat.st_ino == st.st_ino,
              canonicalStat.st_dev == st.st_dev else {
            throw FreezeError.outsideLaunchAgentsDirectory(
                path: rawPlistPath,
                requiredDirectory: userLaunchAgentsDirectory.path
            )
        }

        let existingRecords = try loadRecordsStrict()
        if let duplicate = existingRecords.first(where: { $0.label == item.label }) {
            throw FreezeError.alreadyFrozen(label: item.label, status: duplicate.status)
        }

        // Preflight vault & ledger writability BEFORE creating directories or writing any backup file (L19)
        do {
            try verifyVaultWritablePreflight(requireSubdirectoriesWritable: true)
        } catch {
            throw FreezeError.ledgerWriteFailed(
                step: "Step 1/6 Vault Writability Preflight",
                detail: error.localizedDescription,
                stateSummaryEN: "No files written to vault, launchctl bootout was NOT called, and original plist remains untouched at \(canonicalSrcURL.path).",
                stateSummaryZH: "未向保险库写入任何文件，未调用 launchctl bootout，原 plist 仍完好保留在 \(canonicalSrcURL.path)。"
            )
        }

        let fm = FileManager.default
        let rawBytes: Data
        do {
            rawBytes = try Data(contentsOf: canonicalSrcURL)
        } catch {
            throw FreezeError.backupWriteFailed(label: item.label, detail: error.localizedDescription)
        }

        let digest = Self.sha256Hex(rawBytes)
        let recID = UUID().uuidString
        let safeLabel = item.label
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        // Step 2/6: Write byte-exact backup and verify SHA-256 on disk
        let snapURL = snapshotsDirectory.appendingPathComponent("\(safeLabel)-\(recID).plist")
        let stagedURL = stagingDirectory.appendingPathComponent("\(safeLabel)-\(recID).staged.plist")
        do {
            try fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try rawBytes.write(to: snapURL, options: .atomic)
            let verifyBytes = try Data(contentsOf: snapURL)
            guard verifyBytes == rawBytes, Self.sha256Hex(verifyBytes) == digest else {
                try? fm.removeItem(at: snapURL)
                throw FreezeError.backupWriteFailed(label: item.label, detail: "Read-back SHA-256 mismatch")
            }
        } catch let err as FreezeError {
            throw err
        } catch {
            try? fm.removeItem(at: snapURL)
            throw FreezeError.backupWriteFailed(label: item.label, detail: error.localizedDescription)
        }

        // Step 3/6: Persist "inProgress" record to ledger BEFORE calling bootout or touching original plist
        var txRecord = FreezeSnapshotRecord(
            id: recID,
            label: item.label,
            originalPlistPath: canonicalSrcURL.path,
            snapshotFilePath: snapURL.path,
            stagedPlistPath: stagedURL.path,
            sha256Hex: digest,
            frozenAt: Date(),
            rssBytesAtFreeze: item.rssBytes,
            status: .inProgress
        )
        do {
            try saveRecords([txRecord] + existingRecords)
        } catch {
            try? fm.removeItem(at: snapURL)
            throw FreezeError.ledgerWriteFailed(
                step: "Step 3/6 Record inProgress",
                detail: error.localizedDescription,
                stateSummaryEN: "Temporary backup removed, launchctl bootout was NOT called, and original plist remains untouched at \(canonicalSrcURL.path).",
                stateSummaryZH: "已清理临时备份，未调用 launchctl bootout，原 plist 仍完好保留在 \(canonicalSrcURL.path)。"
            )
        }

        // Step 4/6: Unload service via launchctl bootout and require exitCode == 0
        let bootoutResult = launchctlExecutor.runLaunchctl(["bootout", "gui/\(uid)", canonicalSrcURL.path])
        if bootoutResult.exitCode != 0 {
            try? saveRecords(existingRecords, invokeHook: false)
            try? fm.removeItem(at: snapURL)
            throw FreezeError.bootoutFailed(
                label: item.label,
                exitCode: bootoutResult.exitCode,
                stderr: bootoutResult.stderr,
                originalPath: canonicalSrcURL.path
            )
        }

        // Step 5/6: Move (do NOT delete!) original plist into staging directory next to Snapshots
        do {
            if fm.fileExists(atPath: stagedURL.path) {
                try? fm.removeItem(at: stagedURL)
            }
            try fm.moveItem(at: canonicalSrcURL, to: stagedURL)
        } catch {
            let rb = launchctlExecutor.runLaunchctl(["bootstrap", "gui/\(uid)", canonicalSrcURL.path])
            try? saveRecords(existingRecords, invokeHook: false)
            try? fm.removeItem(at: snapURL)
            try? fm.removeItem(at: stagedURL)
            throw FreezeError.stageMoveFailed(
                label: item.label,
                detail: error.localizedDescription,
                rollbackBootstrapped: rb.exitCode == 0,
                originalPath: canonicalSrcURL.path
            )
        }

        // Re-verify backup integrity before committing final ledger state
        guard let verifySnap = try? Data(contentsOf: snapURL), Self.sha256Hex(verifySnap) == digest else {
            try? fm.moveItem(at: stagedURL, to: canonicalSrcURL)
            _ = launchctlExecutor.runLaunchctl(["bootstrap", "gui/\(uid)", canonicalSrcURL.path])
            try? saveRecords(existingRecords, invokeHook: false)
            try? fm.removeItem(at: snapURL)
            throw FreezeError.backupWriteFailed(
                label: item.label,
                detail: "Snapshot verification failed after staging; rolled back plist and bootstrapped service"
            )
        }

        // Step 6/6: Update ledger record status from "inProgress" to "frozen" and remove staged duplicate
        txRecord.status = .frozen
        txRecord.stagedPlistPath = nil
        do {
            try saveRecords([txRecord] + existingRecords)
            try? fm.removeItem(at: stagedURL)
            return txRecord
        } catch {
            // Reverse rollback of Step 5 & Step 4 so user never loses their service!
            var movedBack = false
            if fm.fileExists(atPath: stagedURL.path) && !fm.fileExists(atPath: canonicalSrcURL.path) {
                movedBack = (try? fm.moveItem(at: stagedURL, to: canonicalSrcURL)) != nil
            }
            let rbResult = movedBack
                ? launchctlExecutor.runLaunchctl(["bootstrap", "gui/\(uid)", canonicalSrcURL.path])
                : LaunchctlResult(exitCode: -1, stderr: "staged move-back failed")
            let cleanedLedger = (try? saveRecords(existingRecords, invokeHook: false)) != nil
            if cleanedLedger {
                try? fm.removeItem(at: snapURL)
            }
            let stateEN = "Rolled back staged plist to \(canonicalSrcURL.path) (\(movedBack ? "ok" : "failed")), re-ran launchctl bootstrap (exit \(rbResult.exitCode)), ledger cleanup \(cleanedLedger ? "succeeded" : "left inProgress entry for startup recovery")."
            let stateZH = "已将暂存 plist 移回 \(canonicalSrcURL.path)（\(movedBack ? "成功" : "失败")），重新执行 launchctl bootstrap（退出码 \(rbResult.exitCode)），台账清理\(cleanedLedger ? "已完成" : "保留进行中记录供启动自检修复")。"
            throw FreezeError.ledgerWriteFailed(
                step: "Step 6/6 Finalize Frozen Record",
                detail: error.localizedDescription,
                stateSummaryEN: stateEN,
                stateSummaryZH: stateZH
            )
        }
    }

    // MARK: - M0 Item 2: Safe Restore Without Data Loss or Silent Overwrite

    public func restore(
        recordID: String,
        conflictResolution: RestoreConflictResolution = .abort
    ) throws {
        var records = try loadRecordsStrict()
        guard let idx = records.firstIndex(where: { $0.id == recordID || $0.label == recordID }) else {
            throw FreezeError.recordNotFound(recordID)
        }
        let rec = records[idx]
        let fm = FileManager.default
        let snapURL = URL(fileURLWithPath: rec.snapshotFilePath)
        let dstURL = URL(fileURLWithPath: rec.originalPlistPath)

        // Step 1/4: Verify backup existence & SHA-256 BEFORE touching target path or calling bootstrap
        guard fm.fileExists(atPath: snapURL.path), let snapBytes = try? Data(contentsOf: snapURL) else {
            throw FreezeError.snapshotMissing(label: rec.label, path: snapURL.path)
        }
        guard Self.sha256Hex(snapBytes) == rec.sha256Hex else {
            throw FreezeError.snapshotCorrupted(rec.label)
        }

        // Step 2/4: Check if a file or symlink already exists at target originalPlistPath
        var dstStat = stat()
        let targetExists = (lstat(dstURL.path, &dstStat) == 0) || fm.fileExists(atPath: dstURL.path)
        var overwrittenExistingBytes: Data?

        if targetExists {
            let existingData = (try? Data(contentsOf: dstURL)) ?? Data()
            let existingHash = Self.sha256Hex(existingData)
            let summary = RestoreConflictSummary(
                label: rec.label,
                existingPath: dstURL.path,
                backupPath: snapURL.path,
                existingBytes: existingData.count,
                backupBytes: snapBytes.count,
                existingSHA256: existingHash,
                backupSHA256: rec.sha256Hex,
                diffSummary: Self.describePlistDiff(backupBytes: snapBytes, existingBytes: existingData, dstStat: dstStat)
            )

            switch conflictResolution {
            case .abort:
                throw FreezeError.restoreTargetConflict(summary)
            case .keepExistingAndClearRecord:
                do {
                    try verifyVaultWritablePreflight(requireSubdirectoriesWritable: false)
                } catch {
                    throw FreezeError.ledgerWriteFailed(
                        step: "Restore Preflight Vault Writability",
                        detail: error.localizedDescription,
                        stateSummaryEN: "Existing target file untouched, backup and ledger record preserved.",
                        stateSummaryZH: "目标现有文件未改动，备份与台账记录已保留。"
                    )
                }
                records.remove(at: idx)
                try saveRecords(records)
                try? fm.removeItem(at: snapURL)
                if let staged = rec.stagedPlistPath {
                    try? fm.removeItem(at: URL(fileURLWithPath: staged))
                }
                return
            case .overwriteExistingWithBackup:
                do {
                    try verifyVaultWritablePreflight(requireSubdirectoriesWritable: false)
                } catch {
                    throw FreezeError.ledgerWriteFailed(
                        step: "Restore Preflight Vault Writability",
                        detail: error.localizedDescription,
                        stateSummaryEN: "Existing target file untouched, launchctl bootstrap was NOT called, and backup/ledger remain preserved.",
                        stateSummaryZH: "目标现有文件未改动，未调用 launchctl bootstrap，备份与台账记录已保留。"
                    )
                }
                overwrittenExistingBytes = existingData
                if (dstStat.st_mode & S_IFMT) == S_IFLNK {
                    try? fm.removeItem(at: dstURL)
                }
            }
        } else {
            // Preflight vault & ledger writability BEFORE writing target plist or calling launchctl bootstrap
            do {
                try verifyVaultWritablePreflight(requireSubdirectoriesWritable: false)
            } catch {
                throw FreezeError.ledgerWriteFailed(
                    step: "Restore Preflight Vault Writability",
                    detail: error.localizedDescription,
                    stateSummaryEN: "Target plist was NOT written, launchctl bootstrap was NOT called, and backup/ledger remain preserved.",
                    stateSummaryZH: "未写入目标 plist，未调用 launchctl bootstrap，备份与台账记录已保留。"
                )
            }
        }

        // Copy verified backup bytes to originalPlistPath (keeping snapURL intact!)
        do {
            try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapBytes.write(to: dstURL, options: .atomic)
            let writtenVerify = try Data(contentsOf: dstURL)
            guard Self.sha256Hex(writtenVerify) == rec.sha256Hex else {
                throw FreezeError.restoreWriteFailed(label: rec.label, detail: "Target write SHA-256 verification failed")
            }
        } catch let err as FreezeError {
            throw err
        } catch {
            throw FreezeError.restoreWriteFailed(label: rec.label, detail: error.localizedDescription)
        }

        // Step 3/4: Run launchctl bootstrap and verify exitCode == 0
        let bootstrapResult = launchctlExecutor.runLaunchctl(["bootstrap", "gui/\(uid)", dstURL.path])
        if bootstrapResult.exitCode != 0 {
            // Roll back target file so both backup and ledger record remain the clean source of truth
            if let prior = overwrittenExistingBytes {
                try? prior.write(to: dstURL, options: .atomic)
            } else {
                try? fm.removeItem(at: dstURL)
            }
            throw FreezeError.bootstrapFailed(
                label: rec.label,
                exitCode: bootstrapResult.exitCode,
                stderr: bootstrapResult.stderr,
                snapshotPath: snapURL.path
            )
        }

        // Step 4/4: Persist updated ledger FIRST, then delete backup/staged files
        records.remove(at: idx)
        try saveRecords(records)
        try? fm.removeItem(at: snapURL)
        if let staged = rec.stagedPlistPath {
            try? fm.removeItem(at: URL(fileURLWithPath: staged))
        }
    }

    // MARK: - M0 Item 3: Startup Integrity Check & Recovery

    public func auditInterruptedTransactionsAndOrphanBackups() -> LedgerIntegrityReport {
        let fm = FileManager.default
        let records: [FreezeSnapshotRecord]
        do {
            records = try loadRecordsStrict()
        } catch {
            return LedgerIntegrityReport(corruptedLedgerError: error.localizedDescription)
        }

        let inProgress = records.filter { $0.status == .inProgress }
        let missingSnapshots = records.filter { !fm.fileExists(atPath: $0.snapshotFilePath) }

        var trackedPaths = Set<String>()
        for rec in records {
            trackedPaths.insert(URL(fileURLWithPath: rec.snapshotFilePath).resolvingSymlinksInPath().standardizedFileURL.path)
            if let staged = rec.stagedPlistPath {
                trackedPaths.insert(URL(fileURLWithPath: staged).resolvingSymlinksInPath().standardizedFileURL.path)
            }
        }

        var orphans: [String] = []
        for dir in [snapshotsDirectory, stagingDirectory] {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in urls where url.pathExtension == "plist" {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                if !trackedPaths.contains(canonical) {
                    orphans.append(canonical)
                }
            }
        }
        orphans.sort()

        return LedgerIntegrityReport(
            inProgressRecords: inProgress,
            orphanedBackupPaths: orphans,
            missingSnapshotRecords: missingSnapshots,
            corruptedLedgerError: nil
        )
    }

    @discardableResult
    public func recoverInterruptedAndOrphanBackups() throws -> LedgerRecoverySummary {
        let fm = FileManager.default
        var records = try loadRecordsStrict()
        var recoveredInProgress: [String] = []
        var adoptedOrphans: [String] = []
        var cleanedDuplicates: [String] = []

        // 1. Recover any interrupted "inProgress" transactions without losing service or plist
        var updatedRecords: [FreezeSnapshotRecord] = []
        var firstRecoveryError: FreezeError?
        for var rec in records {
            guard rec.status == .inProgress else {
                updatedRecords.append(rec)
                continue
            }

            let dstURL = URL(fileURLWithPath: rec.originalPlistPath)
            let snapURL = URL(fileURLWithPath: rec.snapshotFilePath)
            let stagedURL = rec.stagedPlistPath.map { URL(fileURLWithPath: $0) }

            if fm.fileExists(atPath: dstURL.path),
               let dstBytes = try? Data(contentsOf: dstURL),
               Self.sha256Hex(dstBytes) == rec.sha256Hex {
                // Original plist is still in LaunchAgents matching backup bytes.
                // Check via read-only `launchctl print gui/<uid>/<label>` whether the service is still loaded:
                // - exitCode == 0: crash occurred BEFORE Step 4 `bootout` unloaded the service; skip `bootstrap`
                //   (which would fail on an already-loaded service) and clean temporary artifacts.
                // - exitCode != 0: crash occurred AFTER Step 4 `bootout` unloaded the service and BEFORE Step 5
                //   moved the plist to Staged/; re-run `launchctl bootstrap` and verify exitCode == 0
                // before removing the backup or clearing the inProgress record.
                let printRes = launchctlExecutor.runLaunchctl(["print", "gui/\(uid)/\(rec.label)"])
                if printRes.exitCode == 0 {
                    try? fm.removeItem(at: snapURL)
                    if let stagedURL { try? fm.removeItem(at: stagedURL) }
                    recoveredInProgress.append(rec.label)
                } else {
                    // Service is NOT loaded: re-bootstrap before removing backup or clearing inProgress
                    let res = launchctlExecutor.runLaunchctl(["bootstrap", "gui/\(uid)", dstURL.path])
                    if res.exitCode == 0 {
                        try? fm.removeItem(at: snapURL)
                        if let stagedURL { try? fm.removeItem(at: stagedURL) }
                        recoveredInProgress.append(rec.label)
                    } else {
                        updatedRecords.append(rec)
                        if firstRecoveryError == nil {
                            firstRecoveryError = .recoveryBootstrapFailed(
                                label: rec.label,
                                exitCode: res.exitCode,
                                stderr: res.stderr,
                                plistPath: dstURL.path,
                                snapshotPath: snapURL.path
                            )
                        }
                    }
                }
            } else if let sourceBytes = (try? Data(contentsOf: snapURL)) ?? stagedURL.flatMap({ try? Data(contentsOf: $0) }),
                      Self.sha256Hex(sourceBytes) == rec.sha256Hex {
                // Ensure verified backup sits in Snapshots, restore to LaunchAgents, and bootstrap
                if !fm.fileExists(atPath: snapURL.path) {
                    try fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
                    try sourceBytes.write(to: snapURL, options: .atomic)
                }
                if !fm.fileExists(atPath: dstURL.path) {
                    try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try sourceBytes.write(to: dstURL, options: .atomic)
                    let res = launchctlExecutor.runLaunchctl(["bootstrap", "gui/\(uid)", dstURL.path])
                    if res.exitCode == 0 {
                        try? fm.removeItem(at: snapURL)
                        if let stagedURL { try? fm.removeItem(at: stagedURL) }
                        recoveredInProgress.append(rec.label)
                    } else {
                        // Branch 2: plist was already moved out of LaunchAgents prior to interruption.
                        // Remove the unbootstrapped destination copy and downgrade to .frozen in the vault
                        // so disk state matches .frozen and the user can inspect or restore manually.
                        try? fm.removeItem(at: dstURL)
                        if let stagedURL, stagedURL.standardizedFileURL != snapURL.standardizedFileURL {
                            try? fm.removeItem(at: stagedURL)
                        }
                        rec.status = .frozen
                        rec.stagedPlistPath = nil
                        updatedRecords.append(rec)
                        recoveredInProgress.append(rec.label)
                    }
                } else {
                    // Different file already exists at dstURL: promote backup to .frozen so user can inspect conflict diff
                    if let stagedURL { try? fm.removeItem(at: stagedURL) }
                    rec.status = .frozen
                    rec.stagedPlistPath = nil
                    updatedRecords.append(rec)
                    recoveredInProgress.append(rec.label)
                }
            } else {
                updatedRecords.append(rec)
            }
        }
        records = updatedRecords

        // 2. Adopt orphaned backup plists into the ledger (or clean byte-identical staged duplicates)
        var trackedPaths = Set(records.map {
            URL(fileURLWithPath: $0.snapshotFilePath).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let knownDigests = Set(records.map(\.sha256Hex))

        for dir in [snapshotsDirectory, stagingDirectory] {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "plist" {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard !trackedPaths.contains(canonical),
                      let bytes = try? Data(contentsOf: url) else { continue }
                let digest = Self.sha256Hex(bytes)

                if knownDigests.contains(digest) {
                    // Exact duplicate of an already-tracked snapshot backup
                    try? fm.removeItem(at: url)
                    cleanedDuplicates.append(url.path)
                    continue
                }

                // Parse Label from orphaned plist (e.g. left behind by a prior L1 failure) and adopt into Vault
                let inferredLabel: String = {
                    if let raw = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil),
                       let dict = raw as? [String: Any],
                       let plistLabel = dict["Label"] as? String,
                       !plistLabel.isEmpty {
                        return plistLabel
                    }
                    return url.deletingPathExtension().lastPathComponent
                }()

                let destSnapURL: URL
                if dir.standardizedFileURL == snapshotsDirectory.standardizedFileURL {
                    destSnapURL = url
                } else {
                    try fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
                    let target = snapshotsDirectory.appendingPathComponent("\(inferredLabel)-\(UUID().uuidString).plist")
                    try bytes.write(to: target, options: .atomic)
                    try? fm.removeItem(at: url)
                    destSnapURL = target
                }

                let originalTarget = userLaunchAgentsDirectory
                    .appendingPathComponent("\(inferredLabel).plist")
                    .path
                let adopted = FreezeSnapshotRecord(
                    id: UUID().uuidString,
                    label: inferredLabel,
                    originalPlistPath: originalTarget,
                    snapshotFilePath: destSnapURL.path,
                    stagedPlistPath: nil,
                    sha256Hex: digest,
                    frozenAt: Date(),
                    rssBytesAtFreeze: 0,
                    status: .frozen
                )
                records.insert(adopted, at: 0)
                trackedPaths.insert(destSnapURL.resolvingSymlinksInPath().standardizedFileURL.path)
                adoptedOrphans.append(inferredLabel)
            }
        }

        if !recoveredInProgress.isEmpty || !adoptedOrphans.isEmpty || fm.fileExists(atPath: ledgerFileURL.path) {
            try saveRecords(records, invokeHook: false)
        }

        if let firstRecoveryError {
            throw firstRecoveryError
        }

        return LedgerRecoverySummary(
            recoveredInProgressLabels: recoveredInProgress,
            adoptedOrphanLabels: adoptedOrphans,
            cleanedDuplicatePaths: cleanedDuplicates
        )
    }

    // MARK: - Persistence & Helpers

    private func verifyVaultWritablePreflight(requireSubdirectoriesWritable: Bool) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: vaultDirectory.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [
                    NSLocalizedDescriptionKey: "Vault path is not a directory: \(vaultDirectory.path)"
                ])
            }
            if !fm.isWritableFile(atPath: vaultDirectory.path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                    NSLocalizedDescriptionKey: "Vault directory is not writable: \(vaultDirectory.path)"
                ])
            }
        } else {
            var ancestor = vaultDirectory.standardizedFileURL.deletingLastPathComponent()
            while !fm.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            var ancestorIsDir: ObjCBool = false
            if !fm.fileExists(atPath: ancestor.path, isDirectory: &ancestorIsDir) || !ancestorIsDir.boolValue {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [
                    NSLocalizedDescriptionKey: "Vault parent path is not a directory: \(ancestor.path)"
                ])
            }
            if !fm.isWritableFile(atPath: ancestor.path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                    NSLocalizedDescriptionKey: "Vault parent directory is not writable: \(ancestor.path)"
                ])
            }
        }

        if requireSubdirectoriesWritable {
            for subDir in [snapshotsDirectory, stagingDirectory] {
                var subIsDir: ObjCBool = false
                if fm.fileExists(atPath: subDir.path, isDirectory: &subIsDir) {
                    if !subIsDir.boolValue {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [
                            NSLocalizedDescriptionKey: "Vault subdirectory path is not a directory: \(subDir.path)"
                        ])
                    }
                    if !fm.isWritableFile(atPath: subDir.path) {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                            NSLocalizedDescriptionKey: "Vault subdirectory is not writable: \(subDir.path)"
                        ])
                    }
                }
            }
        }

        // Explicitly guard against POSIX atomic-rename silently replacing a 0444 read-only ledger.json
        var ledgerIsDir: ObjCBool = false
        if fm.fileExists(atPath: ledgerFileURL.path, isDirectory: &ledgerIsDir) {
            if ledgerIsDir.boolValue {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR), userInfo: [
                    NSLocalizedDescriptionKey: "Ledger file path is a directory: \(ledgerFileURL.path)"
                ])
            }
            if !fm.isWritableFile(atPath: ledgerFileURL.path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                    NSLocalizedDescriptionKey: "Ledger file is read-only / not writable: \(ledgerFileURL.path)"
                ])
            }
        }
    }

    private func saveRecords(_ records: [FreezeSnapshotRecord], invokeHook: Bool = true) throws {
        writeLock.lock()
        writeCounter += 1
        let seq = writeCounter
        writeLock.unlock()

        if invokeHook, let ledgerWriteHook {
            try ledgerWriteHook(seq, records)
        }

        try verifyVaultWritablePreflight(requireSubdirectoriesWritable: false)
        let fm = FileManager.default
        if !fm.fileExists(atPath: vaultDirectory.path) {
            try fm.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: ledgerFileURL, options: .atomic)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalizedDirectoryPath(_ url: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        // Resolve existing ancestor (e.g. /var -> /private/var on macOS) even when leaf directory doesn't exist yet
        var tailComponents: [String] = []
        var cursor = url.standardizedFileURL
        while !fm.fileExists(atPath: cursor.path) && cursor.path != "/" {
            tailComponents.insert(cursor.lastPathComponent, at: 0)
            cursor.deleteLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for comp in tailComponents {
            resolved.appendPathComponent(comp)
        }
        return resolved.standardizedFileURL.path
    }

    private static func describePlistDiff(backupBytes: Data, existingBytes: Data, dstStat: stat) -> String {
        if (dstStat.st_mode & S_IFMT) == S_IFLNK {
            return "target path is currently a symbolic link whereas backup is a \(backupBytes.count)-byte plist"
        }
        if backupBytes == existingBytes {
            return "identical byte content (\(backupBytes.count) bytes)"
        }

        if let backupDict = (try? PropertyListSerialization.propertyList(from: backupBytes, options: [], format: nil)) as? [String: Any],
           let existingDict = (try? PropertyListSerialization.propertyList(from: existingBytes, options: [], format: nil)) as? [String: Any] {
            let allKeys = Set(backupDict.keys).union(existingDict.keys).sorted()
            var changedKeys: [String] = []
            for key in allKeys {
                let bVal = String(describing: backupDict[key] ?? "<absent>")
                let eVal = String(describing: existingDict[key] ?? "<absent>")
                if bVal != eVal {
                    changedKeys.append("\(key): backup=\(bVal) vs existing=\(eVal)")
                }
            }
            if !changedKeys.isEmpty {
                return changedKeys.prefix(4).joined(separator: "; ")
            }
        }

        if let bText = String(data: backupBytes, encoding: .utf8),
           let eText = String(data: existingBytes, encoding: .utf8) {
            let bLines = bText.components(separatedBy: .newlines)
            let eLines = eText.components(separatedBy: .newlines)
            for idx in 0..<max(bLines.count, eLines.count) {
                let bLine = idx < bLines.count ? bLines[idx].trimmingCharacters(in: .whitespaces) : "<EOF>"
                let eLine = idx < eLines.count ? eLines[idx].trimmingCharacters(in: .whitespaces) : "<EOF>"
                if bLine != eLine {
                    return "line \(idx + 1) differs (backup: '\(bLine)' vs existing: '\(eLine)')"
                }
            }
        }

        return "binary content differs (backup \(backupBytes.count) bytes vs existing \(existingBytes.count) bytes)"
    }
}
