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

public enum CLIRunner {

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
        launchctlExecutor: (any LaunchctlExecuting)? = nil
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
        var unknownFlags: [String] = []

        while idx < argsWithoutExe.count {
            let arg = argsWithoutExe[idx]
            switch arg {
            case "--cli":
                sawCLIFlag = true
            case "--json":
                jsonOutput = true
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

        if !sawCLIFlag {
            let msg = localizer.L(
                "Error: Missing '--cli' flag.\n\(usageText(localizer))\n",
                "错误：缺少 --cli 参数。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        let subcmd = subcommands.first ?? "list"
        let supported = ["list", "orphans", "frozen", "audit", "freeze", "restore", "repair"]
        guard supported.contains(subcmd) else {
            let msg = localizer.L(
                "Error: Unknown CLI subcommand '\(subcmd)'. Supported subcommands: list, orphans, frozen, audit, freeze, restore, repair.\n",
                "错误：未知的命令行子命令「\(subcmd)」。支持的子命令：list、orphans、frozen、audit、freeze、restore、repair。\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
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
            "Usage: LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]\n       LaunchLens --cli [freeze <label>|restore <id-or-label>|repair] [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]",
            "用法：LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]\n      LaunchLens --cli [freeze <服务标识>|restore <记录ID或服务标识>|repair] [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]"
        )
    }
}
