import AppKit
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
        preferredLanguages: [String] = Locale.preferredLanguages
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
        var unknownFlags: [String] = []

        while idx < argsWithoutExe.count {
            let arg = argsWithoutExe[idx]
            switch arg {
            case "--cli":
                sawCLIFlag = true
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

        if subcommands.count > 1 {
            let extra = subcommands.dropFirst().joined(separator: " ")
            let msg = localizer.L(
                "Error: Unexpected extra argument(s): '\(extra)'.\n\(usageText(localizer))\n",
                "错误：存在多余的位置参数：「\(extra)」。\n\(usageText(localizer))\n"
            )
            return CLIExecutionOutput(exitCode: 2, stderr: msg)
        }

        let subcmd = subcommands.first ?? "list"
        let supported = ["list", "orphans", "frozen", "audit"]
        guard supported.contains(subcmd) else {
            let msg = localizer.L(
                "Error: Unknown CLI subcommand '\(subcmd)'. Supported subcommands: list, orphans, frozen, audit.\n",
                "错误：未知的命令行子命令「\(subcmd)」。支持的子命令：list、orphans、frozen、audit。\n"
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
            userLaunchAgentsDirectory: agentsURL
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
        case "audit":
            let report = store.auditInterruptedTransactionsAndOrphanBackups()
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
            let nonApple = snap.items.filter { !$0.isAppleSystem }
            var lines: [String] = [
                localizer.L(
                    "Total Non-Apple Background RSS (user-domain launchctl + orphans): \(ByteFormatter.memory(snap.totalBackgroundRSSBytes)) (\(snap.runningNonAppleCount) running, \(snap.orphanItems.count) orphans)",
                    "非 Apple 后台常驻内存总计（用户域 launchctl + 孤儿进程）：\(ByteFormatter.memory(snap.totalBackgroundRSSBytes))（\(snap.runningNonAppleCount) 项运行中，\(snap.orphanItems.count) 个孤儿进程）"
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

    @MainActor
    private static func usageText(_ localizer: AppLocalizer) -> String {
        localizer.L(
            "Usage: LaunchLens --cli [list|orphans|frozen|audit] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]",
            "用法：LaunchLens --cli [list|orphans|frozen|audit] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]"
        )
    }
}
