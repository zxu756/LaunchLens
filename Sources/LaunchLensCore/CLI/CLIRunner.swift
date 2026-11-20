import AppKit
import Darwin
import Foundation

public struct CLIExecutionOutput: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CLIListJSONPayload: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var totalBackgroundRSSBytes: Int64
    public var runningNonAppleCount: Int
    public var orphanRSSBytes: Int64
    public var totalListeningPortCount: Int
    public var services: [LaunchItem]
    public var orphans: [LaunchItem]
    public var items: [LaunchItem]
    public var frozenRecords: [FreezeSnapshotRecord]

    public init(snapshot: LaunchSnapshot) {
        self.capturedAt = snapshot.capturedAt
        self.totalBackgroundRSSBytes = snapshot.totalBackgroundRSSBytes
        self.runningNonAppleCount = snapshot.runningNonAppleCount
        self.orphanRSSBytes = snapshot.orphanRSSBytes
        self.totalListeningPortCount = snapshot.totalListeningPortCount
        self.services = snapshot.items.filter { $0.domain != .orphanDaemon }
        self.orphans = snapshot.orphanItems
        self.items = snapshot.items
        self.frozenRecords = snapshot.frozenRecords
    }
}

public struct CLIOrphansJSONPayload: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var orphanRSSBytes: Int64
    public var orphans: [LaunchItem]

    public init(snapshot: LaunchSnapshot) {
        self.capturedAt = snapshot.capturedAt
        self.orphanRSSBytes = snapshot.orphanRSSBytes
        self.orphans = snapshot.orphanItems
    }
}

public struct CLIFrozenJSONPayload: Codable, Equatable, Sendable {
    public var frozenRecords: [FreezeSnapshotRecord]

    public init(frozenRecords: [FreezeSnapshotRecord]) {
        self.frozenRecords = frozenRecords
    }
}

public typealias SessionSnapshotCaptureProvider = @Sendable () throws -> SessionSnapshot

public enum CLIRunner {

    private static let directSubcommands: Set<String> = ["snapshot", "diff"]

    public static func shouldRouteToCLI(arguments: [String]) -> Bool {
        let argsWithoutExe = Array(arguments.dropFirst())
        if argsWithoutExe.contains("--cli") || argsWithoutExe.contains("--help") || argsWithoutExe.contains("-h") {
            return true
        }

        var idx = 0
        while idx < argsWithoutExe.count {
            let arg = argsWithoutExe[idx]
            switch arg {
            case "--lang":
                if idx + 1 < argsWithoutExe.count {
                    let next = argsWithoutExe[idx + 1]
                    if directSubcommands.contains(next) {
                        return true
                    }
                    if !next.hasPrefix("-") {
                        idx += 2
                        continue
                    }
                }
            case "--ledger-dir", "--agents-dir":
                if idx + 1 < argsWithoutExe.count, !argsWithoutExe[idx + 1].hasPrefix("-") {
                    let next = argsWithoutExe[idx + 1]
                    if !directSubcommands.contains(next) {
                        idx += 2
                        continue
                    }
                }
            default:
                if !arg.hasPrefix("-") {
                    return directSubcommands.contains(arg)
                }
            }
            idx += 1
        }
        return false
    }

    @MainActor
    public static func run(arguments: [String], preferredLanguages: [String] = Locale.preferredLanguages) -> Int32 {
        let out = execute(arguments: arguments, preferredLanguages: preferredLanguages)
        if !out.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(out.stdout.utf8))
        }
        if !out.stderr.isEmpty {
            FileHandle.standardError.write(Data(out.stderr.utf8))
        }
        return out.exitCode
    }

    @MainActor
    public static func execute(
        arguments: [String],
        preferredLanguages: [String] = Locale.preferredLanguages,
        launchctlExecutor: (any LaunchctlExecuting)? = nil,
        hostCommandExecutor: (any HostCommandExecuting)? = nil,
        snapshotPlistDirectories: [(URL, ServiceDomain)]? = nil,
        snapshotUID: Int? = nil,
        snapshotCaptureProvider: SessionSnapshotCaptureProvider? = nil
    ) -> CLIExecutionOutput {
        // First pass: resolve language without touching UserDefaults
        var resolvedLang: AppLanguage = {
            if let first = preferredLanguages.first,
               first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zh") {
                return .zhHans
            }
            return .en
        }()

        // Pre-scan --lang so even usage/parse errors honor --lang zh|en when valid
        let argsWithoutExe = Array(arguments.dropFirst())
        var invalidLangValue: String?
        var missingValueFlag: String?

        var idx = 0
        var subcommands: [String] = []
        var ledgerDirPath: String?
        var agentsDirPath: String?
        var showHelp = false
        var sawCLIFlag = false
        var jsonOutput = false
        var failOnAdded = false
        var confirmed = false
        var unknownFlags: [String] = []

        while idx < argsWithoutExe.count {
            let arg = argsWithoutExe[idx]
            switch arg {
            case "--cli":
                sawCLIFlag = true
            case "--json":
                jsonOutput = true
            case "--fail-on-added":
                failOnAdded = true
            case "--confirm":
                confirmed = true
            case "--help", "-h":
                showHelp = true
            case "--lang":
                guard idx + 1 < argsWithoutExe.count, !argsWithoutExe[idx + 1].hasPrefix("-") else {
                    missingValueFlag = "--lang"
                    idx += 1
                    continue
                }
                let raw = argsWithoutExe[idx + 1]
                if let parsed = AppLanguage.parseCLI(raw) {
                    resolvedLang = parsed
                } else {
                    invalidLangValue = raw
                }
                idx += 2
                continue
            case _ where arg.hasPrefix("--lang="):
                let raw = String(arg.dropFirst("--lang=".count))
                if let parsed = AppLanguage.parseCLI(raw) {
                    resolvedLang = parsed
                } else {
                    invalidLangValue = raw
                }
            case "--ledger-dir":
                guard idx + 1 < argsWithoutExe.count, !argsWithoutExe[idx + 1].hasPrefix("-") else {
                    missingValueFlag = "--ledger-dir"
                    idx += 1
                    continue
                }
                ledgerDirPath = argsWithoutExe[idx + 1]
                idx += 2
                continue
            case _ where arg.hasPrefix("--ledger-dir="):
                ledgerDirPath = String(arg.dropFirst("--ledger-dir=".count))
            case "--agents-dir":
                guard idx + 1 < argsWithoutExe.count, !argsWithoutExe[idx + 1].hasPrefix("-") else {
                    missingValueFlag = "--agents-dir"
                    idx += 1
                    continue
                }
                agentsDirPath = argsWithoutExe[idx + 1]
                idx += 2
                continue
            case _ where arg.hasPrefix("--agents-dir="):
                agentsDirPath = String(arg.dropFirst("--agents-dir=".count))
            default:
                if arg.hasPrefix("-") {
                    unknownFlags.append(arg)
                } else {
                    subcommands.append(arg)
                }
            }
            idx += 1
        }

        let localizer = AppLocalizer(fixedLanguage: resolvedLang)

        if showHelp && missingValueFlag == nil && invalidLangValue == nil && unknownFlags.isEmpty {
            return CLIExecutionOutput(exitCode: 0, stdout: usageText(localizer) + "\n")
        }

        if let flag = missingValueFlag {
            let msg = localizer.L(
                "Error: Flag '\(flag)' requires a value.\n\(usageText(localizer))\n",
                "错误：参数「\(flag)」缺少取值。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        if let badLang = invalidLangValue {
            let msg = localizer.L(
                "Error: Unsupported language '\(badLang)'. Expected 'en' or 'zh'.\n",
                "错误：不支持的语言参数「\(badLang)」，仅支持 en 或 zh。\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        if let badFlag = unknownFlags.first {
            let msg = localizer.L(
                "Error: Unknown option '\(badFlag)'.\n\(usageText(localizer))\n",
                "错误：未知的命令行选项「\(badFlag)」。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        let allowsDirectWithoutCLI = subcommands.first.map { directSubcommands.contains($0) } ?? false
        if !sawCLIFlag && !allowsDirectWithoutCLI {
            let msg = localizer.L(
                "Error: Missing '--cli' flag.\n\(usageText(localizer))\n",
                "错误：缺少 --cli 参数。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        let subcmd = subcommands.first ?? "list"
        let supported = ["list", "orphans", "frozen", "audit", "freeze", "restore", "repair", "snapshot", "diff"]
        guard supported.contains(subcmd) else {
            let msg = localizer.L(
                "Error: Unknown CLI subcommand '\(subcmd)'. Supported subcommands: list, orphans, frozen, audit, freeze, restore, repair, snapshot, diff.\n",
                "错误：未知的命令行子命令「\(subcmd)」。支持的子命令：list、orphans、frozen、audit、freeze、restore、repair、snapshot、diff。\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        if failOnAdded && subcmd != "diff" {
            let msg = localizer.L(
                "Error: '--fail-on-added' is only valid with the 'diff' subcommand.\n\(usageText(localizer))\n",
                "错误：参数「--fail-on-added」仅适用于 diff 子命令。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        if subcmd == "snapshot" {
            if jsonOutput {
                let msg = localizer.L(
                    "Error: '--json' is not supported with 'snapshot' (snapshot always writes JSON to <file>).\n\(usageText(localizer))\n",
                    "错误：子命令「snapshot」不支持 --json 参数（快照本身即写入 <文件>）。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            if confirmed || ledgerDirPath != nil || agentsDirPath != nil {
                let msg = localizer.L(
                    "Error: Unsupported option for 'snapshot'.\n\(usageText(localizer))\n",
                    "错误：子命令「snapshot」包含不支持的选项。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            if subcommands.count < 2 || subcommands[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let msg = localizer.L(
                    "Error: Subcommand 'snapshot' requires an output <file> path.\n\(usageText(localizer))\n",
                    "错误：子命令「snapshot」需要指定输出 <文件> 路径。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            if subcommands.count > 2 {
                let extra = subcommands.dropFirst(2).joined(separator: " ")
                let msg = localizer.L(
                    "Error: Unexpected extra argument(s): '\(extra)'.\n\(usageText(localizer))\n",
                    "错误：存在多余的位置参数：「\(extra)」。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            return executeSnapshot(
                rawOutputPath: subcommands[1],
                localizer: localizer,
                hostCommandExecutor: hostCommandExecutor,
                snapshotPlistDirectories: snapshotPlistDirectories,
                snapshotUID: snapshotUID,
                snapshotCaptureProvider: snapshotCaptureProvider
            )
        }

        if subcmd == "diff" {
            if confirmed || ledgerDirPath != nil || agentsDirPath != nil {
                let msg = localizer.L(
                    "Error: Unsupported option for 'diff'.\n\(usageText(localizer))\n",
                    "错误：子命令「diff」包含不支持的选项。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            if subcommands.count < 3
                || subcommands[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || subcommands[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let msg = localizer.L(
                    "Error: Subcommand 'diff' requires <before> and <after> snapshot file paths.\n\(usageText(localizer))\n",
                    "错误：子命令「diff」需要指定 <前> 和 <后> 两个快照文件路径。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            if subcommands.count > 3 {
                let extra = subcommands.dropFirst(3).joined(separator: " ")
                let msg = localizer.L(
                    "Error: Unexpected extra argument(s): '\(extra)'.\n\(usageText(localizer))\n",
                    "错误：存在多余的位置参数：「\(extra)」。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            return executeDiff(
                rawBeforePath: subcommands[1],
                rawAfterPath: subcommands[2],
                jsonOutput: jsonOutput,
                failOnAdded: failOnAdded,
                localizer: localizer
            )
        }

        let requiresTargetArg = (subcmd == "freeze" || subcmd == "restore")
        if requiresTargetArg {
            if subcommands.count < 2 {
                let msg = localizer.L(
                    "Error: Subcommand '\(subcmd)' requires a target service label.\n\(usageText(localizer))\n",
                    "错误：子命令「\(subcmd)」需要指定目标服务标识。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
            if subcommands.count > 2 {
                let extra = subcommands.dropFirst(2).joined(separator: " ")
                let msg = localizer.L(
                    "Error: Unexpected extra argument(s): '\(extra)'.\n\(usageText(localizer))\n",
                    "错误：存在多余的位置参数：「\(extra)」。\n\(usageText(localizer))\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: msg)
            }
        } else if subcommands.count > 1 {
            let extra = subcommands.dropFirst().joined(separator: " ")
            let msg = localizer.L(
                "Error: Unexpected extra argument(s): '\(extra)'.\n\(usageText(localizer))\n",
                "错误：存在多余的位置参数：「\(extra)」。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        let isWriteSubcommand = (subcmd == "freeze" || subcmd == "restore" || subcmd == "repair")
        if confirmed && !isWriteSubcommand {
            let msg = localizer.L(
                "Error: '--confirm' is only valid with write subcommands (freeze, restore, repair).\n\(usageText(localizer))\n",
                "错误：参数「--confirm」仅适用于写操作子命令（freeze、restore、repair）。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        let fm = FileManager.default
        let vaultURL = ledgerDirPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let agentsURL = agentsDirPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        if let explicitAgents = agentsURL {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: explicitAgents.path, isDirectory: &isDir) || !isDir.boolValue {
                let msg = localizer.L(
                    "Error: Specified --agents-dir does not exist or is not a directory: \(explicitAgents.path)\n",
                    "错误：指定的 --agents-dir 不存在或不是目录：\(explicitAgents.path)\n"
                )
                return CLIExecutionOutput(exitCode: 1, stderr: msg)
            }
        }

        let store = FreezeLedgerStore(
            vaultDirectory: vaultURL,
            userLaunchAgentsDirectory: agentsURL,
            launchctlExecutor: launchctlExecutor
        )

        // Strict ledger verification so corrupted ledger.json returns exitCode 1 instead of silently showing empty
        if subcmd != "audit" {
            do {
                _ = try store.loadRecordsStrict()
            } catch let err as FreezeError {
                return CLIExecutionOutput(exitCode: 1, stderr: err.localizedMessage(localizer) + "\n")
            } catch {
                return CLIExecutionOutput(exitCode: 1, stderr: error.localizedDescription + "\n")
            }
        }

        switch subcmd {
        case "freeze":
            let targetLabel = subcommands[1]
            let item = resolveUserAgentItemForFreeze(targetLabel: targetLabel, agentsDirectory: store.userLaunchAgentsDirectory)
            if !confirmed {
                let plistPath = item.plistPath ?? "<missing plist>"
                let cmd = store.bootoutCommandPreview(plistPath: plistPath)
                let snapDir = store.snapshotsDirectory.path
                let prompt = localizer.L(
                    "Confirmation required to freeze LaunchAgent '\(targetLabel)'.\n  Command to run: \(cmd)\n  Active plist: \(plistPath)\n  Snapshot vault: \(snapDir)\nRe-run with '--confirm' to execute this change.\n",
                    "冻结 LaunchAgent「\(targetLabel)」需要显式确认。\n  将执行的命令：\(cmd)\n  当前配置文件：\(plistPath)\n  快照保险库目录：\(snapDir)\n请加上 --confirm 参数重新运行以确认执行。\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: prompt)
            }
            do {
                let rec = try store.freeze(item: item)
                if jsonOutput {
                    return encodeJSONOutput(rec, exitCode: 0)
                }
                let ok = localizer.L(
                    "Frozen '\(rec.label)' -> \(rec.snapshotFilePath) (sha256:\(rec.sha256Hex.prefix(12)))\n",
                    "已冻结「\(rec.label)」→ \(rec.snapshotFilePath)（sha256:\(rec.sha256Hex.prefix(12))）\n"
                )
                return CLIExecutionOutput(exitCode: 0, stdout: ok)
            } catch let err as FreezeError {
                return CLIExecutionOutput(exitCode: 1, stderr: err.localizedMessage(localizer) + "\n")
            } catch {
                return CLIExecutionOutput(exitCode: 1, stderr: error.localizedDescription + "\n")
            }

        case "restore":
            let targetID = subcommands[1]
            if !confirmed {
                let matching = store.loadFrozenRecords().first { $0.id == targetID || $0.label == targetID }
                let dstPath = matching?.originalPlistPath ?? store.userLaunchAgentsDirectory.appendingPathComponent("\(targetID).plist").path
                let srcDesc = matching.map { "\($0.snapshotFilePath) (sha256:\($0.sha256Hex.prefix(12)))" } ?? store.snapshotsDirectory.path
                let cmd = store.bootstrapCommandPreview(plistPath: dstPath)
                let prompt = localizer.L(
                    "Confirmation required to restore LaunchAgent '\(targetID)'.\n  Command to run: \(cmd)\n  Verified backup: \(srcDesc)\n  Restore destination: \(dstPath)\nRe-run with '--confirm' to execute this change.\n",
                    "恢复 LaunchAgent「\(targetID)」需要显式确认。\n  将执行的命令：\(cmd)\n  已校验备份文件：\(srcDesc)\n  恢复目标路径：\(dstPath)\n请加上 --confirm 参数重新运行以确认执行。\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: prompt)
            }
            do {
                try store.restore(recordID: targetID)
                if jsonOutput {
                    return encodeJSONOutput(["restored": targetID], exitCode: 0)
                }
                let ok = localizer.L(
                    "Restored '\(targetID)' and reloaded via launchctl bootstrap.\n",
                    "已恢复「\(targetID)」并通过 launchctl bootstrap 重新加载。\n"
                )
                return CLIExecutionOutput(exitCode: 0, stdout: ok)
            } catch let err as FreezeError {
                return CLIExecutionOutput(exitCode: 1, stderr: err.localizedMessage(localizer) + "\n")
            } catch {
                return CLIExecutionOutput(exitCode: 1, stderr: error.localizedDescription + "\n")
            }

        case "repair":
            if !confirmed {
                let report = store.auditInterruptedTransactionsAndOrphanBackups()
                let cmdNote: String
                if !report.inProgressRecords.isEmpty {
                    let labels = report.inProgressRecords.map(\.label).joined(separator: ", ")
                    cmdNote = "/bin/launchctl print gui/\(store.uid)/<label> && /bin/launchctl bootstrap gui/\(store.uid) \"<interrupted-plist>\" (\(labels))"
                } else {
                    cmdNote = localizer.L(
                        "Adopt \(report.orphanedBackupPaths.count) orphaned backup plist(s) into \(store.ledgerFileURL.path)",
                        "将 \(report.orphanedBackupPaths.count) 个孤儿备份 plist 纳入 \(store.ledgerFileURL.path)"
                    )
                }
                let prompt = localizer.L(
                    "Confirmation required to repair ledger integrity.\n  Action / command: \(cmdNote)\n  Snapshots directory: \(store.snapshotsDirectory.path)\n  Ledger file: \(store.ledgerFileURL.path)\nRe-run with '--confirm' to execute this change.\n",
                    "修复台账完整性与孤儿备份需要显式确认。\n  将执行的操作 / 命令：\(cmdNote)\n  快照备份目录：\(store.snapshotsDirectory.path)\n  台账文件：\(store.ledgerFileURL.path)\n请加上 --confirm 参数重新运行以确认执行。\n"
                )
                return CLIExecutionOutput(exitCode: 2, stderr: prompt)
            }
            do {
                let summary = try store.recoverInterruptedAndOrphanBackups()
                if jsonOutput {
                    return encodeJSONOutput(summary, exitCode: 0)
                }
                let ok = localizer.L(
                    "Ledger repair complete: recovered=\(summary.recoveredInProgressLabels.count), adopted=\(summary.adoptedOrphanLabels.count), cleanedDuplicates=\(summary.cleanedDuplicatePaths.count).\n",
                    "台账修复完成：恢复中断事务 \(summary.recoveredInProgressLabels.count) 项，收编孤儿备份 \(summary.adoptedOrphanLabels.count) 项，清理重复文件 \(summary.cleanedDuplicatePaths.count) 个。\n"
                )
                return CLIExecutionOutput(exitCode: 0, stdout: ok)
            } catch let err as FreezeError {
                return CLIExecutionOutput(exitCode: 1, stderr: err.localizedMessage(localizer) + "\n")
            } catch {
                return CLIExecutionOutput(exitCode: 1, stderr: error.localizedDescription + "\n")
            }

        case "audit":
            let report = store.auditInterruptedTransactionsAndOrphanBackups()
            if jsonOutput {
                return encodeJSONOutput(report, exitCode: report.hasIssues ? 1 : 0)
            }
            if !report.hasIssues {
                let ok = localizer.L(
                    "Ledger audit OK: 0 interrupted transactions, 0 orphaned backups.\n",
                    "台账完整性检查通过：0 条中断事务，0 个孤儿备份文件。\n"
                )
                return CLIExecutionOutput(exitCode: 0, stdout: ok)
            }
            var lines: [String] = []
            if let corrupt = report.corruptedLedgerError {
                lines.append(localizer.L("Corrupted ledger: \(corrupt)", "台账损坏：\(corrupt)"))
            }
            if !report.inProgressRecords.isEmpty {
                let labels = report.inProgressRecords.map(\.label).joined(separator: ", ")
                lines.append(localizer.L(
                    "Interrupted inProgress records (\(report.inProgressRecords.count)): \(labels)",
                    "未完成的「进行中」记录（\(report.inProgressRecords.count) 条）：\(labels)"
                ))
            }
            if !report.orphanedBackupPaths.isEmpty {
                lines.append(localizer.L(
                    "Orphaned backup files (\(report.orphanedBackupPaths.count)): \(report.orphanedBackupPaths.joined(separator: ", "))",
                    "无台账记录的孤儿备份文件（\(report.orphanedBackupPaths.count) 个）：\(report.orphanedBackupPaths.joined(separator: ", "))"
                ))
            }
            if !report.missingSnapshotRecords.isEmpty {
                let labels = report.missingSnapshotRecords.map(\.label).joined(separator: ", ")
                lines.append(localizer.L(
                    "Records missing snapshot file (\(report.missingSnapshotRecords.count)): \(labels)",
                    "备份文件缺失的台账记录（\(report.missingSnapshotRecords.count) 条）：\(labels)"
                ))
            }
            return CLIExecutionOutput(exitCode: 1, stderr: lines.joined(separator: "\n") + "\n")

        case "frozen":
            let records = store.loadFrozenRecords()
            if jsonOutput {
                return encodeJSONOutput(CLIFrozenJSONPayload(frozenRecords: records), exitCode: 0)
            }
            if records.isEmpty {
                let text = localizer.L(
                    "No frozen LaunchAgents in snapshot vault.\n",
                    "快照保险库中暂无已冻结的 LaunchAgents。\n"
                )
                return CLIExecutionOutput(exitCode: 0, stdout: text)
            }
            let lines = records.map { rec in
                "\(rec.label)  sha256:\(rec.sha256Hex.prefix(12))  \(LaunchLensMonitor.displayPath(rec.originalPlistPath))"
            }
            return CLIExecutionOutput(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n")

        case "orphans":
            let customDirs = agentsURL.map { [($0, ServiceDomain.userAgent)] }
            let snap = LaunchScanner.scanLiveHost(ledgerStore: store, plistDirectories: customDirs)
            if jsonOutput {
                return encodeJSONOutput(CLIOrphansJSONPayload(snapshot: snap), exitCode: 0)
            }
            let orphans = snap.orphanItems
            if orphans.isEmpty {
                let text = localizer.L(
                    "No orphaned developer/AI daemons detected.\n",
                    "未检测到脱离终端的开发/AI 孤儿守护进程。\n"
                )
                return CLIExecutionOutput(exitCode: 0, stdout: text)
            }
            let lines = orphans.map { item in
                let ports = item.listeningPorts.map { ":\($0)" }.joined(separator: ",")
                let mem = ByteFormatter.memory(item.rssBytes).padding(toLength: 10, withPad: " ", startingAt: 0)
                let pidCol = "PID \(item.pid ?? 0)".padding(toLength: 11, withPad: " ", startingAt: 0)
                return "\(mem)  \(pidCol)  \(item.label)  \(ports)"
            }
            return CLIExecutionOutput(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n")

        default: // "list"
            let customDirs = agentsURL.map { [($0, ServiceDomain.userAgent)] }
            let snap = LaunchScanner.scanLiveHost(ledgerStore: store, plistDirectories: customDirs)
            if jsonOutput {
                return encodeJSONOutput(CLIListJSONPayload(snapshot: snap), exitCode: 0)
            }
            let nonApple = snap.items.filter { !$0.isAppleSystem }
            var lines: [String] = [
                localizer.L(
                    "Total Non-Apple Background RSS (service trees + orphans): \(ByteFormatter.memory(snap.totalBackgroundRSSBytes)) (\(snap.runningNonAppleCount) running, \(snap.orphanItems.count) orphans)",
                    "非 Apple 后台常驻内存总计（服务进程树 + 孤儿进程）：\(ByteFormatter.memory(snap.totalBackgroundRSSBytes))（\(snap.runningNonAppleCount) 项运行中，\(snap.orphanItems.count) 个孤儿进程）"
                )
            ]
            for item in nonApple.prefix(20) {
                let state = item.isFrozen
                    ? localizer.L("FROZEN", "已冻结")
                    : (item.pid.map { "PID \($0)" } ?? localizer.L("IDLE", "空闲"))
                lines.append("\(ByteFormatter.memory(item.rssBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(state.padding(toLength: 10, withPad: " ", startingAt: 0))  [\(item.domain.localizedBadge(localizer))]  \(item.label)")
            }
            return CLIExecutionOutput(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n")
        }
    }

    @MainActor
    public static func runExportScreenshots(arguments: [String]) -> Int32 {
        guard let idx = arguments.firstIndex(of: "--export-screenshots"),
              idx + 1 < arguments.count,
              !arguments[idx + 1].hasPrefix("-") else {
            fputs("Error: --export-screenshots requires an output directory path.\n", stderr)
            return 2
        }
        let outURL = URL(fileURLWithPath: arguments[idx + 1])
        let exportLang: AppLanguage
        if arguments.contains("--lang") || arguments.contains(where: { $0.hasPrefix("--lang=") }) {
            guard let parsed = AppLocalizer.resolveCLILanguage(from: arguments) else {
                fputs("Error: Invalid --lang value for --export-screenshots (expected en or zh).\n", stderr)
                return 2
            }
            exportLang = parsed
        } else {
            exportLang = .en
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        do {
            try ScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
            print("Exported 2x Retina screenshots (\(exportLang.rawValue)) to \(outURL.path)")
            return 0
        } catch {
            fputs("Screenshot export failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func resolveUserAgentItemForFreeze(targetLabel: String, agentsDirectory: URL) -> LaunchItem {
        let fm = FileManager.default
        if let urls = try? fm.contentsOfDirectory(at: agentsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "plist" {
                var st = stat()
                if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                    if url.deletingPathExtension().lastPathComponent == targetLabel {
                        return LaunchItem(
                            id: "user::\(targetLabel)",
                            label: targetLabel,
                            domain: .userAgent,
                            plistPath: url.path,
                            programCommand: targetLabel,
                            isAppleSystem: targetLabel.lowercased().hasPrefix("com.apple.")
                        )
                    }
                    continue
                }
                if let meta = LaunchScanner.readPlistMetadata(at: url, domain: .userAgent), meta.label == targetLabel {
                    return LaunchItem(
                        id: "user::\(meta.label)",
                        label: meta.label,
                        domain: .userAgent,
                        plistPath: meta.plistPath,
                        programCommand: meta.programCommand,
                        runAtLoad: meta.runAtLoad,
                        keepAlive: meta.keepAlive,
                        isAppleSystem: meta.label.lowercased().hasPrefix("com.apple.")
                    )
                }
            }
        }
        let fallbackURL = agentsDirectory.appendingPathComponent("\(targetLabel).plist")
        return LaunchItem(
            id: "user::\(targetLabel)",
            label: targetLabel,
            domain: .userAgent,
            plistPath: fallbackURL.path,
            programCommand: targetLabel,
            isAppleSystem: targetLabel.lowercased().hasPrefix("com.apple.")
        )
    }

    // MARK: - M2 Session Snapshot & Diff Execution

    @MainActor
    private static func executeSnapshot(
        rawOutputPath: String,
        localizer: AppLocalizer,
        hostCommandExecutor: (any HostCommandExecuting)?,
        snapshotPlistDirectories: [(URL, ServiceDomain)]?,
        snapshotUID: Int?,
        snapshotCaptureProvider: SessionSnapshotCaptureProvider?
    ) -> CLIExecutionOutput {
        let targetURL = resolveFilePathURL(rawOutputPath)

        do {
            try preflightSnapshotTargetWritable(targetURL)

            let snapshot: SessionSnapshot
            if let snapshotCaptureProvider {
                snapshot = try snapshotCaptureProvider()
            } else {
                snapshot = try LaunchScanner.captureSessionSnapshot(
                    plistDirectories: snapshotPlistDirectories,
                    currentUID: snapshotUID ?? Int(getuid()),
                    executor: hostCommandExecutor ?? SystemHostCommandExecutor()
                )
            }

            var payload = try SessionSnapshot.encodePrettyJSON(snapshot)
            payload.append(Data("\n".utf8))
            try writeDataAtomicallyWithFsync(payload, to: targetURL)

            let v = localizer.snapshotVocabulary
            let summary = "\(v.snapshotSavedPrefix) \(targetURL.path) (\(v.servicesHeader): \(snapshot.services.count), \(v.listenersHeader): \(snapshot.listeners.count), \(v.orphansHeader): \(snapshot.orphans.count))\n"
            return CLIExecutionOutput(exitCode: 0, stdout: summary)
        } catch let err as SnapshotCaptureError {
            switch err {
            case let .commandFailed(executablePath, arguments, exitCode, stderr):
                let cmd = ([executablePath] + arguments).joined(separator: " ")
                let detail = stderr.isEmpty ? "" : " (\(singleLine(stderr)))"
                let msg = localizer.L(
                    "Error: Snapshot capture failed — command '\(cmd)' exited with code \(exitCode)\(detail).\n",
                    "错误：快照采集失败——命令「\(cmd)」退出码为 \(exitCode)\(detail)。\n"
                )
                return CLIExecutionOutput(exitCode: 1, stderr: msg)
            }
        } catch {
            let reason = singleLine(error.localizedDescription)
            let msg = localizer.L(
                "Error: Failed to write snapshot to '\(targetURL.path)': \(reason)\n",
                "错误：无法写入快照文件「\(targetURL.path)」：\(reason)\n"
            )
            return CLIExecutionOutput(exitCode: 1, stderr: msg)
        }
    }

    @MainActor
    private static func executeDiff(
        rawBeforePath: String,
        rawAfterPath: String,
        jsonOutput: Bool,
        failOnAdded: Bool,
        localizer: AppLocalizer
    ) -> CLIExecutionOutput {
        let beforeURL = resolveFilePathURL(rawBeforePath)
        let afterURL = resolveFilePathURL(rawAfterPath)

        let beforeSnap: SessionSnapshot
        switch loadAndValidateSnapshotFile(at: beforeURL, localizer: localizer) {
        case let .success(snap):
            beforeSnap = snap
        case let .failure(errOut):
            return errOut
        }

        let afterSnap: SessionSnapshot
        switch loadAndValidateSnapshotFile(at: afterURL, localizer: localizer) {
        case let .success(snap):
            afterSnap = snap
        case let .failure(errOut):
            return errOut
        }

        let rawDiff = SessionSnapshotDiffer.diff(before: beforeSnap, after: afterSnap)
        let safeDiff = redactDiffForOutput(rawDiff)
        let exitCode: Int32 = (failOnAdded && safeDiff.hasAdditions) ? 3 : 0

        if jsonOutput {
            do {
                let data = try SessionSnapshotDiffer.encodePrettyJSON(safeDiff)
                let text = String(decoding: data, as: UTF8.self) + "\n"
                return CLIExecutionOutput(exitCode: exitCode, stdout: text)
            } catch {
                let reason = singleLine(error.localizedDescription)
                let msg = localizer.L(
                    "Error: Failed to encode diff JSON: \(reason)\n",
                    "错误：无法编码差异 JSON：\(reason)\n"
                )
                return CLIExecutionOutput(exitCode: 1, stderr: msg)
            }
        }

        let text = formatSnapshotDiffText(safeDiff, vocabulary: localizer.snapshotVocabulary)
        return CLIExecutionOutput(exitCode: exitCode, stdout: text)
    }

    private enum SnapshotFileLoadOutcome {
        case success(SessionSnapshot)
        case failure(CLIExecutionOutput)
    }

    @MainActor
    private static func loadAndValidateSnapshotFile(
        at fileURL: URL,
        localizer: AppLocalizer
    ) -> SnapshotFileLoadOutcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            let msg = localizer.L(
                "Error: Snapshot file does not exist: '\(fileURL.path)'.\n",
                "错误：快照文件不存在：「\(fileURL.path)」。\n"
            )
            return .failure(CLIExecutionOutput(exitCode: 1, stderr: msg))
        }
        if isDir.boolValue {
            let msg = localizer.L(
                "Error: Snapshot path is a directory, expected a file: '\(fileURL.path)'.\n",
                "错误：快照路径是目录而非文件：「\(fileURL.path)」。\n"
            )
            return .failure(CLIExecutionOutput(exitCode: 1, stderr: msg))
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try SessionSnapshot.decodeAndValidate(from: data)
            return .success(snapshot)
        } catch let err as SnapshotValidationError {
            switch err {
            case let .unsupportedSchemaVersion(found, expected):
                let msg = localizer.L(
                    "Error: Unsupported snapshot schemaVersion \(found) in '\(fileURL.path)' (expected \(expected)).\n",
                    "错误：快照文件「\(fileURL.path)」的 schemaVersion 为 \(found)，不受支持（期望为 \(expected)）。\n"
                )
                return .failure(CLIExecutionOutput(exitCode: 1, stderr: msg))
            }
        } catch {
            let reason = singleLine(error.localizedDescription)
            let msg = localizer.L(
                "Error: Failed to read or parse snapshot file '\(fileURL.path)': \(reason)\n",
                "错误：无法读取或解析快照文件「\(fileURL.path)」：\(reason)\n"
            )
            return .failure(CLIExecutionOutput(exitCode: 1, stderr: msg))
        }
    }

    private static func resolveFilePathURL(_ rawPath: String) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func preflightSnapshotTargetWritable(_ targetURL: URL) throws {
        let fm = FileManager.default
        let parentURL = targetURL.deletingLastPathComponent()

        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: parentURL.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "Directory does not exist: \(parentURL.path)"]
            )
        }
        guard fm.isWritableFile(atPath: parentURL.path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "Directory is not writable: \(parentURL.path)"]
            )
        }

        var targetIsDir: ObjCBool = false
        if fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir) {
            if targetIsDir.boolValue {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EISDIR),
                    userInfo: [NSLocalizedDescriptionKey: "Target path is a directory: \(targetURL.path)"]
                )
            }
            if !fm.isWritableFile(atPath: targetURL.path) {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EACCES),
                    userInfo: [NSLocalizedDescriptionKey: "Target file is not writable: \(targetURL.path)"]
                )
            }
        }
    }

    private static func writeDataAtomicallyWithFsync(_ data: Data, to targetURL: URL) throws {
        try preflightSnapshotTargetWritable(targetURL)

        let parentURL = targetURL.deletingLastPathComponent()
        let tempName = ".\(targetURL.lastPathComponent).tmp.\(UUID().uuidString)"
        let tempURL = parentURL.appendingPathComponent(tempName, isDirectory: false)
        let tempPath = tempURL.path

        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        if fd < 0 {
            let err = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))]
            )
        }

        var fdClosed = false
        var renamed = false
        defer {
            if !fdClosed {
                _ = Darwin.close(fd)
            }
            if !renamed {
                _ = Darwin.unlink(tempPath)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let remaining = rawBuffer.count - totalWritten
                let written = Darwin.write(fd, baseAddress.advanced(by: totalWritten), remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    let err = errno
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(err),
                        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))]
                    )
                }
                totalWritten += written
            }
        }

        if Darwin.fsync(fd) != 0 {
            let err = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))]
            )
        }

        if Darwin.close(fd) != 0 {
            fdClosed = true
            let err = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))]
            )
        }
        fdClosed = true

        if Darwin.rename(tempPath, targetURL.path) != 0 {
            let err = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))]
            )
        }
        renamed = true
    }

    private static func redactDiffForOutput(_ diff: SessionSnapshotDiff) -> SessionSnapshotDiff {
        var out = diff
        out.services.added = out.services.added.map(redactServiceEntry)
        out.services.removed = out.services.removed.map(redactServiceEntry)
        out.services.modified = out.services.modified.map { mod in
            var copy = mod
            copy.before = redactServiceEntry(copy.before)
            copy.after = redactServiceEntry(copy.after)
            return copy
        }
        out.listeners.added = out.listeners.added.map(redactListenerEntry)
        out.listeners.removed = out.listeners.removed.map(redactListenerEntry)
        out.orphans.added = out.orphans.added.map(redactOrphanEntry)
        out.orphans.removed = out.orphans.removed.map(redactOrphanEntry)
        return out
    }

    private static func redactServiceEntry(_ entry: SnapshotServiceEntry) -> SnapshotServiceEntry {
        var copy = entry
        copy.programCommand = CommandArgumentRedactor.redactCommandLine(copy.programCommand)
        return copy
    }

    private static func redactListenerEntry(_ entry: SnapshotListenerEntry) -> SnapshotListenerEntry {
        var copy = entry
        copy.programCommand = CommandArgumentRedactor.redactCommandLine(copy.programCommand)
        copy.invocationIdentity = redactInvocationIdentity(copy.invocationIdentity)
        return copy
    }

    private static func redactOrphanEntry(_ entry: SnapshotOrphanEntry) -> SnapshotOrphanEntry {
        var copy = entry
        copy.programCommand = CommandArgumentRedactor.redactCommandLine(copy.programCommand)
        copy.invocationIdentity = redactInvocationIdentity(copy.invocationIdentity)
        return copy
    }

    private static func redactInvocationIdentity(_ raw: String) -> String {
        if let markerRange = raw.range(of: "::inline:") {
            let prefix = String(raw[..<markerRange.lowerBound])
            let inlineBody = String(raw[markerRange.upperBound...])
            return "\(prefix)::inline:\(CommandArgumentRedactor.redactCommandLine(inlineBody))"
        }
        return CommandArgumentRedactor.redactCommandLine(raw)
    }

    private static func formatSnapshotDiffText(
        _ diff: SessionSnapshotDiff,
        vocabulary v: SnapshotCLIVocabulary
    ) -> String {
        var lines: [String] = []

        // 1. Services section (count line + added + removed + modified)
        lines.append("\(v.servicesHeader): +\(diff.summary.servicesAdded) \(v.addedWord), -\(diff.summary.servicesRemoved) \(v.removedWord), ~\(diff.summary.servicesModified) \(v.modifiedWord)")
        for entry in diff.services.added {
            lines.append(formatServiceDiffLine(sign: "+", entry: entry, vocabulary: v))
        }
        for entry in diff.services.removed {
            lines.append(formatServiceDiffLine(sign: "-", entry: entry, vocabulary: v))
        }
        for mod in diff.services.modified {
            let beforeProg = singleLine(CommandArgumentRedactor.redactCommandLine(mod.before.programCommand))
            let afterProg = singleLine(CommandArgumentRedactor.redactCommandLine(mod.after.programCommand))
            let progDisplay = (beforeProg == afterProg) ? afterProg : "\(beforeProg) -> \(afterProg)"
            let reasonsDisplay = mod.reasons.map { v.reasonName($0) }.joined(separator: ",")
            let suffix = reasonsDisplay.isEmpty ? "" : " [\(reasonsDisplay)]"
            lines.append("  ~ [\(v.domainName(mod.after.domainScope))] \(singleLine(mod.after.label)) | \(v.plistField): \(singleLine(mod.after.plistPath)) | \(v.programField): \(progDisplay)\(suffix)")
        }

        // 2. Listening Ports section (count line + added + removed)
        lines.append("\(v.listenersHeader): +\(diff.summary.listenersAdded) \(v.addedWord), -\(diff.summary.listenersRemoved) \(v.removedWord)")
        for entry in diff.listeners.added {
            lines.append(formatListenerDiffLine(sign: "+", entry: entry, vocabulary: v))
        }
        for entry in diff.listeners.removed {
            lines.append(formatListenerDiffLine(sign: "-", entry: entry, vocabulary: v))
        }

        // 3. Orphan Processes section (count line + added + removed)
        lines.append("\(v.orphansHeader): +\(diff.summary.orphansAdded) \(v.addedWord), -\(diff.summary.orphansRemoved) \(v.removedWord)")
        for entry in diff.orphans.added {
            lines.append(formatOrphanDiffLine(sign: "+", entry: entry, vocabulary: v))
        }
        for entry in diff.orphans.removed {
            lines.append(formatOrphanDiffLine(sign: "-", entry: entry, vocabulary: v))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatServiceDiffLine(
        sign: String,
        entry: SnapshotServiceEntry,
        vocabulary v: SnapshotCLIVocabulary
    ) -> String {
        let program = singleLine(CommandArgumentRedactor.redactCommandLine(entry.programCommand))
        return "  \(sign) [\(v.domainName(entry.domainScope))] \(singleLine(entry.label)) | \(v.plistField): \(singleLine(entry.plistPath)) | \(v.programField): \(program)"
    }

    private static func formatListenerDiffLine(
        sign: String,
        entry: SnapshotListenerEntry,
        vocabulary v: SnapshotCLIVocabulary
    ) -> String {
        let binds = entry.bindAddresses.isEmpty ? "*" : singleLine(entry.bindAddresses.joined(separator: ","))
        let pidSegment = entry.isOrphan ? "PID \(entry.pid) [\(v.orphanTag)]" : "PID \(entry.pid)"
        let program = singleLine(CommandArgumentRedactor.redactCommandLine(entry.programCommand))
        return "  \(sign) :\(entry.port) | \(v.bindField): \(binds) | \(pidSegment) | \(v.programField): \(program)"
    }

    private static func formatOrphanDiffLine(
        sign: String,
        entry: SnapshotOrphanEntry,
        vocabulary v: SnapshotCLIVocabulary
    ) -> String {
        let program = singleLine(CommandArgumentRedactor.redactCommandLine(entry.programCommand))
        return "  \(sign) PID \(entry.pid) | \(v.startedField): \(singleLine(entry.lstart)) | \(v.programField): \(program)"
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func encodeJSONOutput<T: Encodable>(_ payload: T, exitCode: Int32) -> CLIExecutionOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            let text = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
            return CLIExecutionOutput(exitCode: exitCode, stdout: text)
        } catch {
            return CLIExecutionOutput(exitCode: 1, stderr: "JSON encoding error: \(error.localizedDescription)\n")
        }
    }

    @MainActor
    private static func usageText(_ localizer: AppLocalizer) -> String {
        localizer.L(
            "Usage: LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]\n       LaunchLens --cli [freeze <label>|restore <id-or-label>|repair] --confirm [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]\n       LaunchLens [--cli] snapshot <file> [--lang en|zh]\n       LaunchLens [--cli] diff <before> <after> [--json] [--fail-on-added] [--lang en|zh]",
            "用法：LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]\n      LaunchLens --cli [freeze <服务标识>|restore <记录ID或服务标识>|repair] --confirm [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]\n      LaunchLens [--cli] snapshot <文件> [--lang en|zh]\n      LaunchLens [--cli] diff <前> <后> [--json] [--fail-on-added] [--lang en|zh]"
        )
    }
}
