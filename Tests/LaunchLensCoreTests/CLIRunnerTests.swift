import Foundation
import Testing
@testable import LaunchLensCore

@Suite("CLIRunnerTests", .timeLimit(.minutes(1)))
struct CLIRunnerTests {

    private func builtExecutableURL() throws -> URL {
        let testBundleURL = Bundle(for: BundleToken.self).bundleURL
        let binDir = testBundleURL.deletingLastPathComponent()
        let exe = binDir.appendingPathComponent("LaunchLens")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path), "Expected built LaunchLens executable at \(exe.path)")
        return exe
    }

    @Test("Row 7 (L9): Compiled LaunchLens --cli nosuchcmd exits with code 2 on en and zh")
    func testCompiledBinaryUnknownSubcommandExitsCode2() throws {
        let exe = try builtExecutableURL()
        for (lang, expectedSnippet) in [("en", "Unknown CLI subcommand 'nosuchcmd'"), ("zh", "未知的命令行子命令「nosuchcmd」")] {
            let proc = Process()
            proc.executableURL = exe
            proc.arguments = ["--cli", "nosuchcmd", "--lang", lang]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            #expect(proc.terminationStatus == 2)
            #expect(stdout.isEmpty)
            #expect(stderr.contains(expectedSnippet))
        }
    }

    @Test("L9: Rejects unknown flags, invalid --lang, and extra positional arguments with exit code 2")
    @MainActor
    func testRejectsUnknownFlagsAndInvalidLang() {
        let badFlagEN = CLIRunner.execute(arguments: ["LaunchLens", "--cli", "list", "--bogus", "--lang", "en"])
        #expect(badFlagEN.exitCode == 2)
        #expect(badFlagEN.stdout.isEmpty)
        #expect(badFlagEN.stderr.contains("Unknown option '--bogus'"))

        let badFlagZH = CLIRunner.execute(arguments: ["LaunchLens", "--lang", "zh", "--cli", "--bogus"])
        #expect(badFlagZH.exitCode == 2)
        #expect(badFlagZH.stderr.contains("未知的命令行选项「--bogus」"))

        let badLangEN = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "list", "--lang", "fr"],
            preferredLanguages: ["en-US"]
        )
        #expect(badLangEN.exitCode == 2)
        #expect(badLangEN.stderr.contains("Unsupported language 'fr'"))

        let badLangZH = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "list", "--lang", "fr"],
            preferredLanguages: ["zh-Hans-CN"]
        )
        #expect(badLangZH.exitCode == 2)
        #expect(badLangZH.stderr.contains("不支持的语言参数「fr」"))

        let extraPositional = CLIRunner.execute(arguments: ["LaunchLens", "--cli", "list", "unexpected"])
        #expect(extraPositional.exitCode == 2)
    }

    @Test("L9: Corrupted ledger or missing --agents-dir returns exit code 1; audit reports issues with exit code 1")
    @MainActor
    func testRuntimeErrorsAndAuditExitCode1() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensCLI-\(UUID().uuidString)")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let agentsDir = tempRoot.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. Clean isolated CLI runs return 0 in both EN and ZH without creating directories if absent
        let emptyVault = tempRoot.appendingPathComponent("NonExistentVault")
        let cleanFrozenEN = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "--lang", "en", "frozen", "--ledger-dir", emptyVault.path
        ])
        #expect(cleanFrozenEN.exitCode == 0)
        #expect(cleanFrozenEN.stdout.contains("No frozen LaunchAgents"))
        #expect(!fm.fileExists(atPath: emptyVault.path))

        let cleanAuditZH = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "audit", "--lang", "zh", "--ledger-dir", emptyVault.path
        ])
        #expect(cleanAuditZH.exitCode == 0)
        #expect(cleanAuditZH.stdout.contains("台账完整性检查通过"))

        // 2. Missing explicit --agents-dir returns exit code 1
        let missingAgents = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "list", "--lang", "en", "--agents-dir", tempRoot.appendingPathComponent("Missing").path
        ])
        #expect(missingAgents.exitCode == 1)
        #expect(missingAgents.stderr.contains("--agents-dir"))

        // 3. Corrupted ledger.json returns exit code 1 on frozen/list/audit
        try Data("{corrupted-json".utf8).write(to: vaultDir.appendingPathComponent("ledger.json"))
        let corruptEN = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "frozen", "--lang", "en", "--ledger-dir", vaultDir.path
        ])
        #expect(corruptEN.exitCode == 1)
        #expect(corruptEN.stderr.contains("Ledger Read"))

        let corruptAuditZH = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "audit", "--lang", "zh", "--ledger-dir", vaultDir.path
        ])
        #expect(corruptAuditZH.exitCode == 1)
        #expect(corruptAuditZH.stderr.contains("台账损坏"))
    }

    @Test("Hermetic --help/-h, --cli list, and --cli audit with --agents-dir & --ledger-dir work in EN & ZH")
    @MainActor
    func testHelpAndIsolatedListAndAuditSubcommands() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensCLIHermetic-\(UUID().uuidString)")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let snapsDir = vaultDir.appendingPathComponent("Snapshots")
        let agentsDir = tempRoot.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: snapsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. --help and -h return exit code 0 in EN and ZH without --cli
        let helpEN = CLIRunner.execute(arguments: ["LaunchLens", "--help", "--lang", "en"])
        #expect(helpEN.exitCode == 0)
        #expect(helpEN.stderr.isEmpty)
        #expect(helpEN.stdout.contains("Usage: LaunchLens --cli [list|orphans|frozen|audit]"))

        let shortHelpZH = CLIRunner.execute(arguments: ["LaunchLens", "-h", "--lang", "zh"])
        #expect(shortHelpZH.exitCode == 0)
        #expect(shortHelpZH.stderr.isEmpty)
        #expect(shortHelpZH.stdout.contains("用法：LaunchLens --cli [list|orphans|frozen|audit]"))

        // 2. Isolated --cli list with --agents-dir & --ledger-dir lists only fixture plist
        let fixturePlist = agentsDir.appendingPathComponent("io.fixture.cli-test.plist")
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.fixture.cli-test</string>
            <key>ProgramArguments</key>
            <array><string>/usr/bin/true</string></array>
        </dict>
        </plist>
        """
        try Data(plistXML.utf8).write(to: fixturePlist)

        let listEN = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "list", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "en"
        ])
        #expect(listEN.exitCode == 0)
        #expect(listEN.stdout.contains("Total Non-Apple Background RSS"))
        #expect(listEN.stdout.contains("io.fixture.cli-test"))

        let listZH = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "list", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "zh"
        ])
        #expect(listZH.exitCode == 0)
        #expect(listZH.stdout.contains("非 Apple 后台常驻内存总计"))
        #expect(listZH.stdout.contains("io.fixture.cli-test"))

        // 3. --cli audit detects orphaned backup plist and exits with code 1 in EN and ZH
        let orphanBackup = snapsDir.appendingPathComponent("io.fixture.orphan-1.plist")
        try Data(plistXML.utf8).write(to: orphanBackup)

        let auditIssueEN = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "audit", "--ledger-dir", vaultDir.path, "--lang", "en"
        ])
        #expect(auditIssueEN.exitCode == 1)
        #expect(auditIssueEN.stderr.contains("Orphaned backup files (1)"))

        let auditIssueZH = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "audit", "--ledger-dir", vaultDir.path, "--lang", "zh"
        ])
        #expect(auditIssueZH.exitCode == 1)
        #expect(auditIssueZH.stderr.contains("无台账记录的孤儿备份文件（1 个）"))
    }

    @Test("L18: Both README.md and README.zh-CN.md include v0.1.0/v0.2.0 upgrade --cli audit safety notice")
    func testL18ReadmesIncludeUpgradeAuditSafetyNotice() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readmeEN = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeZH = try String(contentsOf: repoRoot.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)

        #expect(readmeEN.contains("Upgrade Check for `v0.1.0` / `v0.2.0` Users"))
        #expect(readmeEN.contains("deleted the active `.plist` before persisting `ledger.json`"))
        #expect(readmeEN.contains("ignored non-zero `launchctl` exit codes"))
        #expect(readmeEN.contains("LaunchLens --cli audit"))

        #expect(readmeZH.contains("`v0.1.0` / `v0.2.0` 用户升级自检提示"))
        #expect(readmeZH.contains("先删除原 `.plist` 最后才写 `ledger.json`"))
        #expect(readmeZH.contains("未检查 `launchctl` 退出码"))
        #expect(readmeZH.contains("LaunchLens --cli audit --lang zh"))
    }

    @Test("M1 Item 3: Supports --json output flag across list, orphans, frozen, and audit subcommands")
    @MainActor
    func testM1CLIJsonOutputForListOrphansFrozenAndAudit() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensCLIJSON-\(UUID().uuidString)")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let agentsDir = tempRoot.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fixturePlist = agentsDir.appendingPathComponent("io.fixture.json-agent.plist")
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.fixture.json-agent</string>
            <key>ProgramArguments</key>
            <array><string>/usr/bin/true</string></array>
        </dict>
        </plist>
        """
        try Data(plistXML.utf8).write(to: fixturePlist)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let listOut = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "list", "--json", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path
        ])
        #expect(listOut.exitCode == 0)
        #expect(listOut.stderr.isEmpty)
        let listPayload = try decoder.decode(CLIListJSONPayload.self, from: Data(listOut.stdout.utf8))
        #expect(listPayload.services.map(\.label) == ["io.fixture.json-agent"])
        #expect(listPayload.items.contains(where: { $0.label == "io.fixture.json-agent" }))
        #expect(listPayload.frozenRecords.isEmpty)

        let orphansOut = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "orphans", "--json", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path
        ])
        #expect(orphansOut.exitCode == 0)
        let orphansPayload = try decoder.decode(CLIOrphansJSONPayload.self, from: Data(orphansOut.stdout.utf8))
        #expect(orphansPayload.orphanRSSBytes >= 0)

        let frozenOut = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "frozen", "--json", "--ledger-dir", vaultDir.path
        ])
        #expect(frozenOut.exitCode == 0)
        let frozenPayload = try decoder.decode(CLIFrozenJSONPayload.self, from: Data(frozenOut.stdout.utf8))
        #expect(frozenPayload.frozenRecords.isEmpty)

        let auditOut = CLIRunner.execute(arguments: [
            "LaunchLens", "--cli", "audit", "--json", "--ledger-dir", vaultDir.path
        ])
        #expect(auditOut.exitCode == 0)
        let auditReport = try decoder.decode(LedgerIntegrityReport.self, from: Data(auditOut.stdout.utf8))
        #expect(!auditReport.hasIssues)
    }

    @Test("M1 CLI freeze, restore, and repair subcommands execute hermetically via injected LaunchctlExecuting")
    @MainActor
    func testM1CLIFreezeRestoreAndRepairHermetic() throws {
        final class FakeCLILaunchctl: LaunchctlExecuting, @unchecked Sendable {
            var loaded: Set<String> = ["io.cli.agent"]
            var calls: [[String]] = []
            func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
                calls.append(arguments)
                switch arguments.first {
                case "print":
                    let target = arguments.count > 1 ? arguments[1] : ""
                    let label = target.split(separator: "/").last.map(String.init) ?? ""
                    return loaded.contains(label)
                        ? LaunchctlResult(exitCode: 0, stdout: "running")
                        : LaunchctlResult(exitCode: 113, stderr: "not found")
                case "bootout":
                    loaded.remove("io.cli.agent")
                    return LaunchctlResult(exitCode: 0)
                case "bootstrap":
                    loaded.insert("io.cli.agent")
                    return LaunchctlResult(exitCode: 0)
                default:
                    return LaunchctlResult(exitCode: 2)
                }
            }
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensCLIFreeze-\(UUID().uuidString)")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let agentsDir = tempRoot.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.cli.agent.plist")
        let plistBytes = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.cli.agent</string>
            <key>ProgramArguments</key>
            <array><string>/bin/sleep</string><string>60</string></array>
        </dict>
        </plist>
        """.utf8)
        try plistBytes.write(to: plistURL, options: .atomic)

        let fake = FakeCLILaunchctl()

        let missingTarget = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "freeze", "--lang", "en"],
            launchctlExecutor: fake
        )
        #expect(missingTarget.exitCode == 2)
        #expect(missingTarget.stderr.contains("requires a target service label"))

        let extraTarget = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "freeze", "io.cli.agent", "extra", "--lang", "zh"],
            launchctlExecutor: fake
        )
        #expect(extraTarget.exitCode == 2)
        #expect(extraTarget.stderr.contains("多余的位置参数"))

        let freezeRes = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "freeze", "io.cli.agent", "--confirm", "--json", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "en"],
            launchctlExecutor: fake
        )
        #expect(freezeRes.exitCode == 0)
        #expect(!fm.fileExists(atPath: plistURL.path))
        #expect(!fake.loaded.contains("io.cli.agent"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let frozenRec = try decoder.decode(FreezeSnapshotRecord.self, from: Data(freezeRes.stdout.utf8))
        #expect(frozenRec.label == "io.cli.agent")
        #expect(frozenRec.status == .frozen)

        let restoreRes = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "restore", "io.cli.agent", "--confirm", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "zh"],
            launchctlExecutor: fake
        )
        #expect(restoreRes.exitCode == 0)
        #expect(restoreRes.stdout.contains("已恢复「io.cli.agent」"))
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(try Data(contentsOf: plistURL) == plistBytes)
        #expect(fake.loaded.contains("io.cli.agent"))

        let repairRes = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "repair", "--confirm", "--json", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "en"],
            launchctlExecutor: fake
        )
        #expect(repairRes.exitCode == 0)
        let summary = try decoder.decode(LedgerRecoverySummary.self, from: Data(repairRes.stdout.utf8))
        #expect(summary.recoveredInProgressLabels.isEmpty)
        #expect(summary.adoptedOrphanLabels.isEmpty)
        #expect(summary.cleanedDuplicatePaths.isEmpty)
    }

    @Test("LR4: CLI write subcommands (freeze, restore, repair) require --confirm and preview exact launchctl commands without mutating state")
    @MainActor
    func testLR4WriteSubcommandsRequireConfirmGateAndShowCommandPreview() throws {
        final class FakeCLILaunchctl: LaunchctlExecuting, @unchecked Sendable {
            var loaded: Set<String> = ["io.cli.lr4"]
            var calls: [[String]] = []
            func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
                calls.append(arguments)
                switch arguments.first {
                case "print":
                    let target = arguments.count > 1 ? arguments[1] : ""
                    let label = target.split(separator: "/").last.map(String.init) ?? ""
                    return loaded.contains(label)
                        ? LaunchctlResult(exitCode: 0, stdout: "running")
                        : LaunchctlResult(exitCode: 113, stderr: "not found")
                case "bootout":
                    loaded.remove("io.cli.lr4")
                    return LaunchctlResult(exitCode: 0)
                case "bootstrap":
                    loaded.insert("io.cli.lr4")
                    return LaunchctlResult(exitCode: 0)
                default:
                    return LaunchctlResult(exitCode: 2)
                }
            }
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensCLILR4-\(UUID().uuidString)")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let agentsDir = tempRoot.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.cli.lr4.plist")
        let plistBytes = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.cli.lr4</string>
            <key>ProgramArguments</key>
            <array><string>/bin/sleep</string><string>60</string></array>
        </dict>
        </plist>
        """.utf8)
        try plistBytes.write(to: plistURL, options: .atomic)

        let fake = FakeCLILaunchctl()

        // 1. freeze without --confirm -> exitCode 2, previews exact bootout command, zero mutations
        for (lang, expectedHint) in [("en", "Confirmation required"), ("zh", "需要显式确认")] {
            let unconfirmedFreeze = CLIRunner.execute(
                arguments: ["LaunchLens", "--cli", "freeze", "io.cli.lr4", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", lang],
                launchctlExecutor: fake
            )
            #expect(unconfirmedFreeze.exitCode == 2)
            #expect(unconfirmedFreeze.stdout.isEmpty)
            #expect(unconfirmedFreeze.stderr.contains(expectedHint))
            #expect(unconfirmedFreeze.stderr.contains("/bin/launchctl bootout gui/"))
            #expect(unconfirmedFreeze.stderr.contains(plistURL.path))
            #expect(unconfirmedFreeze.stderr.contains("--confirm"))
            #expect(fake.calls.isEmpty)
            #expect(fm.fileExists(atPath: plistURL.path))
            #expect(!fm.fileExists(atPath: vaultDir.path))
        }

        // freeze with --confirm -> executes
        let confirmedFreeze = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "freeze", "io.cli.lr4", "--confirm", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "en"],
            launchctlExecutor: fake
        )
        #expect(confirmedFreeze.exitCode == 0)
        #expect(!fm.fileExists(atPath: plistURL.path))
        #expect(fake.calls.count == 1)

        // 2. restore without --confirm -> exitCode 2, previews exact bootstrap command, zero mutations
        for (lang, expectedHint) in [("en", "Confirmation required"), ("zh", "需要显式确认")] {
            let unconfirmedRestore = CLIRunner.execute(
                arguments: ["LaunchLens", "--cli", "restore", "io.cli.lr4", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", lang],
                launchctlExecutor: fake
            )
            #expect(unconfirmedRestore.exitCode == 2)
            #expect(unconfirmedRestore.stdout.isEmpty)
            #expect(unconfirmedRestore.stderr.contains(expectedHint))
            #expect(unconfirmedRestore.stderr.contains("/bin/launchctl bootstrap gui/"))
            #expect(unconfirmedRestore.stderr.contains("--confirm"))
            #expect(fake.calls.count == 1)
            #expect(!fm.fileExists(atPath: plistURL.path))
        }

        // restore with --confirm -> executes
        let confirmedRestore = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "restore", "io.cli.lr4", "--confirm", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "zh"],
            launchctlExecutor: fake
        )
        #expect(confirmedRestore.exitCode == 0)
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(try Data(contentsOf: plistURL) == plistBytes)
        #expect(fake.calls.count == 2)

        // 3. repair without --confirm -> exitCode 2, previews repair target paths, zero mutations
        let orphanSnapURL = vaultDir.appendingPathComponent("Snapshots/io.cli.orphan-lr4.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>io.cli.orphan-lr4</string></dict></plist>
        """.utf8).write(to: orphanSnapURL, options: .atomic)

        for (lang, expectedHint) in [("en", "Confirmation required"), ("zh", "需要显式确认")] {
            let unconfirmedRepair = CLIRunner.execute(
                arguments: ["LaunchLens", "--cli", "repair", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", lang],
                launchctlExecutor: fake
            )
            #expect(unconfirmedRepair.exitCode == 2)
            #expect(unconfirmedRepair.stdout.isEmpty)
            #expect(unconfirmedRepair.stderr.contains(expectedHint))
            #expect(unconfirmedRepair.stderr.contains("--confirm"))
            #expect(fake.calls.count == 2)
        }
        let preRepairStore = FreezeLedgerStore(vaultDirectory: vaultDir, userLaunchAgentsDirectory: agentsDir, launchctlExecutor: fake)
        #expect(preRepairStore.loadFrozenRecords().isEmpty)

        // repair with --confirm -> executes and adopts orphan backup
        let confirmedRepair = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "repair", "--confirm", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "en"],
            launchctlExecutor: fake
        )
        #expect(confirmedRepair.exitCode == 0)
        #expect(preRepairStore.loadFrozenRecords().map(\.label) == ["io.cli.orphan-lr4"])

        // 4. --confirm on read-only subcommands is rejected with exitCode 2
        let readOnlyConfirm = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "list", "--confirm", "--agents-dir", agentsDir.path, "--ledger-dir", vaultDir.path, "--lang", "en"]
        )
        #expect(readOnlyConfirm.exitCode == 2)
    }

    // MARK: - M2 Stage 2: CLI snapshot & diff Tests

    private struct FakeCLIHostExecutor: HostCommandExecuting {
        let handler: @Sendable (String, [String]) -> HostCommandResult
        func runCommand(executablePath: String, arguments: [String]) -> HostCommandResult {
            handler(executablePath, arguments)
        }
    }

    private static let fixedT0 = Date(timeIntervalSince1970: 1_795_200_000)
    private static let fixedT1 = Date(timeIntervalSince1970: 1_795_200_060)
    private static let sampleHost = SnapshotHostInfo(
        hostname: "test-host.local",
        osVersion: "macOS 15.1",
        architecture: "arm64",
        uid: 501
    )

    @Test("M2 Item 1 & 2 (D3): Direct and --cli routing, --help usage, and snapshot atomic summary in EN & ZH")
    @MainActor
    func testM2DirectAndCLISubcommandRoutingAndHelpBilingual() throws {
        // 1. D3 routing checks (in-process)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens"]) == false)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--demo"]) == false)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--lang", "zh"]) == false)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "-NSDocumentRevisionsDebugMode", "YES"]) == false)

        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "snapshot", "/tmp/snap.json"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "snapshot"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "diff", "/tmp/a.json", "/tmp/b.json"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "diff"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--lang", "zh", "snapshot", "/tmp/snap.json"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--lang=en", "diff", "/tmp/a.json", "/tmp/b.json", "--fail-on-added"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--lang", "snapshot"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--cli", "snapshot", "/tmp/snap.json"]) == true)
        #expect(CLIRunner.shouldRouteToCLI(arguments: ["LaunchLens", "--cli", "diff", "/tmp/a.json", "/tmp/b.json"]) == true)

        // 2. --help lists both snapshot and diff in EN and ZH while keeping existing usage
        let helpEN = CLIRunner.execute(arguments: ["LaunchLens", "--help", "--lang", "en"])
        #expect(helpEN.exitCode == 0)
        #expect(helpEN.stdout.contains("Usage: LaunchLens --cli [list|orphans|frozen|audit]"))
        #expect(helpEN.stdout.contains("snapshot <file>"))
        #expect(helpEN.stdout.contains("diff <before> <after> [--json] [--fail-on-added]"))

        let helpZH = CLIRunner.execute(arguments: ["LaunchLens", "-h", "--lang", "zh"])
        #expect(helpZH.exitCode == 0)
        #expect(helpZH.stdout.contains("用法：LaunchLens --cli [list|orphans|frozen|audit]"))
        #expect(helpZH.stdout.contains("snapshot <文件>"))
        #expect(helpZH.stdout.contains("diff <前> <后> [--json] [--fail-on-added]"))

        // 3. Direct and --cli snapshot writes valid SessionSnapshot JSON and prints single-line summary
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensM2Snap-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Agents")
        let outDir = tempRoot.appendingPathComponent("Out")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.example.snap-svc</string>
            <key>ProgramArguments</key>
            <array><string>/opt/example/bin/snap-svc</string></array>
        </dict>
        </plist>
        """
        try Data(plistXML.utf8).write(to: agentsDir.appendingPathComponent("io.example.snap-svc.plist"))

        let psOut = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        51001     1   501  32768       01:00 Sat Nov 21 09:10:00 2026 /usr/bin/python3 /opt/example/orphan.py
        51002   800   501  24576       00:30 Sat Nov 21 09:10:30 2026 /opt/homebrew/bin/node /opt/example/server.js
        """
        let lsofOut = """
        p51002
        cnode
        tIPv4
        PTCP
        n127.0.0.1:19090
        """
        let fakeExec = FakeCLIHostExecutor { exe, _ in
            switch exe {
            case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
            case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psOut)
            case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofOut)
            default: return HostCommandResult(exitCode: 1)
            }
        }

        let snapENURL = outDir.appendingPathComponent("direct-en.json")
        let snapEN = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", snapENURL.path, "--lang", "en"],
            hostCommandExecutor: fakeExec,
            snapshotPlistDirectories: [(agentsDir, .userAgent)],
            snapshotUID: 501
        )
        #expect(snapEN.exitCode == 0)
        #expect(snapEN.stderr.isEmpty)
        let enLines = snapEN.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(enLines.count == 2 && enLines.last == "")
        #expect(snapEN.stdout.contains(snapENURL.path))
        #expect(snapEN.stdout.contains("1"))

        let decodedEN = try SessionSnapshot.decodeAndValidate(from: Data(contentsOf: snapENURL))
        #expect(decodedEN.services.count == 1)
        #expect(decodedEN.listeners.count == 1)
        #expect(decodedEN.orphans.count == 1)

        // Ensure no leftover temp files in outDir
        let outEntriesAfterEN = try fm.contentsOfDirectory(atPath: outDir.path)
        #expect(outEntriesAfterEN == ["direct-en.json"])

        let snapZHURL = outDir.appendingPathComponent("cli-zh.json")
        let snapZH = CLIRunner.execute(
            arguments: ["LaunchLens", "--cli", "snapshot", snapZHURL.path, "--lang", "zh"],
            hostCommandExecutor: fakeExec,
            snapshotPlistDirectories: [(agentsDir, .userAgent)],
            snapshotUID: 501
        )
        #expect(snapZH.exitCode == 0)
        #expect(snapZH.stderr.isEmpty)
        let zhLines = snapZH.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(zhLines.count == 2 && zhLines.last == "")
        #expect(snapZH.stdout.contains(snapZHURL.path))
        #expect(snapZH.stdout.contains("后台服务"))
        #expect(snapZH.stdout.contains("监听端口"))
        #expect(snapZH.stdout.contains("孤儿进程"))
    }

    @Test("M2 Row 5 & Item 6: Collector failure, unwritable dir, corrupted/bad-schema JSON exit 1 without residue; bad args exit 2")
    @MainActor
    func testM2SnapshotAndDiffExitCodesAndAtomicWriteCleanup() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensM2Row5-\(UUID().uuidString)")
        let writableDir = tempRoot.appendingPathComponent("Writable")
        let readOnlyDir = tempRoot.appendingPathComponent("ReadOnly")
        try fm.createDirectory(at: writableDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        defer {
            _ = chmod(readOnlyDir.path, S_IRWXU)
            try? fm.removeItem(at: tempRoot)
        }

        // 1. Fake lsof non-zero exit -> snapshot exits 1, stdout empty, target & temp files absent
        let failingLsofExec = FakeCLIHostExecutor { exe, _ in
            switch exe {
            case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
            case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: "  PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS\n")
            case "/usr/sbin/lsof": return HostCommandResult(exitCode: 1, stderr: "lsof simulated failure")
            default: return HostCommandResult(exitCode: 1)
            }
        }
        let failedSnapTarget = writableDir.appendingPathComponent("should-not-exist.json")
        let lsofFailOut = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", failedSnapTarget.path, "--lang", "en"],
            hostCommandExecutor: failingLsofExec,
            snapshotPlistDirectories: [],
            snapshotUID: 501
        )
        #expect(lsofFailOut.exitCode == 1)
        #expect(lsofFailOut.stdout.isEmpty)
        #expect(!lsofFailOut.stderr.isEmpty)
        #expect(!fm.fileExists(atPath: failedSnapTarget.path))
        #expect((try fm.contentsOfDirectory(atPath: writableDir.path)).isEmpty)

        // 2. Nonexistent parent directory -> snapshot exits 1, directory not created
        let missingDirTarget = tempRoot.appendingPathComponent("MissingParent/out.json")
        let okExec = FakeCLIHostExecutor { exe, _ in
            switch exe {
            case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
            case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: "  PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS\n")
            case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: "")
            default: return HostCommandResult(exitCode: 1)
            }
        }
        let missingParentOut = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", missingDirTarget.path, "--lang", "zh"],
            hostCommandExecutor: okExec,
            snapshotPlistDirectories: [],
            snapshotUID: 501
        )
        #expect(missingParentOut.exitCode == 1)
        #expect(missingParentOut.stdout.isEmpty)
        #expect(!missingParentOut.stderr.isEmpty)
        #expect(!fm.fileExists(atPath: tempRoot.appendingPathComponent("MissingParent").path))

        // 3. Unwritable target directory (chmod 0500) -> snapshot exits 1, zero residue
        #expect(chmod(readOnlyDir.path, S_IRUSR | S_IXUSR) == 0)
        let readOnlyTarget = readOnlyDir.appendingPathComponent("unwritable.json")
        let unwritableOut = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", readOnlyTarget.path, "--lang", "en"],
            hostCommandExecutor: okExec,
            snapshotPlistDirectories: [],
            snapshotUID: 501
        )
        #expect(unwritableOut.exitCode == 1)
        #expect(unwritableOut.stdout.isEmpty)
        #expect(!unwritableOut.stderr.isEmpty)
        #expect(!fm.fileExists(atPath: readOnlyTarget.path))
        #expect((try fm.contentsOfDirectory(atPath: readOnlyDir.path)).isEmpty)

        // 4. Simulated encoding / provider error -> snapshot exits 1, zero residue
        let encodeFailTarget = writableDir.appendingPathComponent("encode-fail.json")
        let encodeFailOut = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", encodeFailTarget.path, "--lang", "en"],
            snapshotCaptureProvider: {
                throw EncodingError.invalidValue(
                    Double.nan,
                    EncodingError.Context(codingPath: [], debugDescription: "Simulated encoding failure")
                )
            }
        )
        #expect(encodeFailOut.exitCode == 1)
        #expect(encodeFailOut.stdout.isEmpty)
        #expect(!encodeFailOut.stderr.isEmpty)
        #expect(!fm.fileExists(atPath: encodeFailTarget.path))
        #expect((try fm.contentsOfDirectory(atPath: writableDir.path)).isEmpty)

        // 5. Diff file missing, truncated JSON, and schemaVersion == 2 -> exit 1 with empty stdout
        let validSnap = SessionSnapshot(capturedAt: Self.fixedT0, host: Self.sampleHost, services: [], listeners: [], orphans: [])
        let validURL = writableDir.appendingPathComponent("valid.json")
        let truncatedURL = writableDir.appendingPathComponent("truncated.json")
        let schema2URL = writableDir.appendingPathComponent("schema2.json")
        try SessionSnapshot.encodePrettyJSON(validSnap).write(to: validURL)
        try Data("{\"schemaVersion\": 1, \"capturedAt\":".utf8).write(to: truncatedURL)
        let schema2Snap = SessionSnapshot(schemaVersion: 2, capturedAt: Self.fixedT1, host: Self.sampleHost, services: [], listeners: [], orphans: [])
        try SessionSnapshot.encodePrettyJSON(schema2Snap).write(to: schema2URL)

        let diffMissing = CLIRunner.execute(
            arguments: ["LaunchLens", "diff", writableDir.appendingPathComponent("nope.json").path, validURL.path, "--lang", "en"]
        )
        #expect(diffMissing.exitCode == 1)
        #expect(diffMissing.stdout.isEmpty)
        #expect(!diffMissing.stderr.isEmpty)

        let diffTruncated = CLIRunner.execute(
            arguments: ["LaunchLens", "diff", validURL.path, truncatedURL.path, "--lang", "zh"]
        )
        #expect(diffTruncated.exitCode == 1)
        #expect(diffTruncated.stdout.isEmpty)
        #expect(!diffTruncated.stderr.isEmpty)

        // Target path is an existing directory -> snapshot exits 1; diff on directory -> exits 1
        let snapToDir = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", writableDir.path, "--lang", "en"],
            hostCommandExecutor: okExec,
            snapshotPlistDirectories: [],
            snapshotUID: 501
        )
        #expect(snapToDir.exitCode == 1)
        #expect(snapToDir.stdout.isEmpty)

        let unreadableURL = writableDir.appendingPathComponent("unreadable.json")
        try SessionSnapshot.encodePrettyJSON(validSnap).write(to: unreadableURL)
        #expect(chmod(unreadableURL.path, 0) == 0)
        defer { _ = chmod(unreadableURL.path, S_IRUSR | S_IWUSR) }
        let diffUnreadable = CLIRunner.execute(
            arguments: ["LaunchLens", "diff", unreadableURL.path, validURL.path, "--lang", "en"]
        )
        #expect(diffUnreadable.exitCode == 1)
        #expect(diffUnreadable.stdout.isEmpty)

        for lang in ["en", "zh"] {
            let diffSchema2 = CLIRunner.execute(
                arguments: ["LaunchLens", "diff", validURL.path, schema2URL.path, "--lang", lang]
            )
            #expect(diffSchema2.exitCode == 1)
            #expect(diffSchema2.stdout.isEmpty)
            #expect(diffSchema2.stderr.contains("2"))
        }

        // 6. Parameter / option errors -> exit 2 with empty stdout
        let badInvocations: [[String]] = [
            ["LaunchLens", "snapshot"],
            ["LaunchLens", "--cli", "snapshot"],
            ["LaunchLens", "snapshot", validURL.path, validURL.path],
            ["LaunchLens", "snapshot", validURL.path, "--fail-on-added"],
            ["LaunchLens", "snapshot", validURL.path, "--json"],
            ["LaunchLens", "snapshot", validURL.path, "--unknown-opt"],
            ["LaunchLens", "diff"],
            ["LaunchLens", "--cli", "diff"],
            ["LaunchLens", "diff", validURL.path],
            ["LaunchLens", "diff", validURL.path, validURL.path, validURL.path],
            ["LaunchLens", "diff", validURL.path, validURL.path, "--unknown-opt"],
            ["LaunchLens", "diff", validURL.path, validURL.path, "--confirm"],
            ["LaunchLens", "--cli", "list", "--fail-on-added"]
        ]
        for args in badInvocations {
            let res = CLIRunner.execute(arguments: args)
            #expect(res.exitCode == 2, "Expected exitCode 2 for \(args), got \(res.exitCode)")
            #expect(res.stdout.isEmpty, "Expected empty stdout for \(args), got \(res.stdout)")
            #expect(!res.stderr.isEmpty, "Expected error message on stderr for \(args)")
        }
    }

    @Test("M2 Item 0 & Item 3 (D2): --fail-on-added exits 3 on any addition (including relocated service plist) and 0 otherwise")
    @MainActor
    func testM2DiffFailOnAddedExitCode3IncludingRelocatedServicePlist() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LaunchLensM2D2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let baseSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.svc",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.svc.plist",
            plistSHA256: "aaaa1111",
            programCommand: "/opt/example/bin/svc --v1"
        )
        let modSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.svc",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.svc.plist",
            plistSHA256: "bbbb2222",
            programCommand: "/opt/example/bin/svc --v2"
        )
        let relocatedSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.svc",
            plistPath: "/private/tmp/session-agent/io.example.svc.plist",
            isExternalPlist: true,
            plistSHA256: "aaaa1111",
            programCommand: "/opt/example/bin/svc --v1"
        )
        let listener = SnapshotListenerEntry(
            port: 18123,
            protocols: ["TCP4"],
            bindAddresses: ["127.0.0.1"],
            pid: 7001,
            ppid: 1,
            uid: 501,
            lstart: "Sat Nov 21 09:00:00 2026",
            executable: "/opt/homebrew/bin/node",
            invocationIdentity: "/opt/homebrew/bin/node::script:/opt/example/srv.js",
            programCommand: "/opt/homebrew/bin/node /opt/example/srv.js",
            isOrphan: true
        )
        let orphan = SnapshotOrphanEntry(
            pid: 7002,
            uid: 501,
            lstart: "Sat Nov 21 09:01:00 2026",
            executable: "/usr/bin/python3",
            invocationIdentity: "/usr/bin/python3::script:/opt/example/bg.py",
            programCommand: "/usr/bin/python3 /opt/example/bg.py"
        )

        func writeSnap(_ name: String, services: [SnapshotServiceEntry] = [], listeners: [SnapshotListenerEntry] = [], orphans: [SnapshotOrphanEntry] = []) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let snap = SessionSnapshot(capturedAt: Self.fixedT0, host: Self.sampleHost, services: services, listeners: listeners, orphans: orphans)
            try SessionSnapshot.encodePrettyJSON(snap).write(to: url)
            return url
        }

        let emptyURL = try writeSnap("empty.json")
        let baseSvcURL = try writeSnap("base_svc.json", services: [baseSvc])
        let modSvcURL = try writeSnap("mod_svc.json", services: [modSvc])
        let relocatedSvcURL = try writeSnap("relocated_svc.json", services: [relocatedSvc])
        let listenerURL = try writeSnap("listener.json", listeners: [listener])
        let orphanURL = try writeSnap("orphan.json", orphans: [orphan])

        // 1. Identical -> 0 even with --fail-on-added
        #expect(CLIRunner.execute(arguments: ["LaunchLens", "diff", baseSvcURL.path, baseSvcURL.path, "--fail-on-added"]).exitCode == 0)

        // 2. Removal only -> 0 even with --fail-on-added
        #expect(CLIRunner.execute(arguments: ["LaunchLens", "diff", baseSvcURL.path, emptyURL.path, "--fail-on-added"]).exitCode == 0)

        // 3. Same-key content modification only (~1, +0) -> 0 with --fail-on-added
        let sameKeyMod = CLIRunner.execute(arguments: ["LaunchLens", "diff", baseSvcURL.path, modSvcURL.path, "--fail-on-added"])
        #expect(sameKeyMod.exitCode == 0)

        // 4. Relocated plist path (-1 old, +1 new, 0 modified) -> 0 without flag, 3 with --fail-on-added!
        let relocatedDefault = CLIRunner.execute(arguments: ["LaunchLens", "diff", baseSvcURL.path, relocatedSvcURL.path, "--json"])
        #expect(relocatedDefault.exitCode == 0)
        let relocatedStrictText = CLIRunner.execute(arguments: ["LaunchLens", "diff", baseSvcURL.path, relocatedSvcURL.path, "--fail-on-added", "--lang", "en"])
        #expect(relocatedStrictText.exitCode == 3)
        #expect(!relocatedStrictText.stdout.isEmpty)
        let relocatedStrictJSON = CLIRunner.execute(arguments: ["LaunchLens", "--cli", "diff", baseSvcURL.path, relocatedSvcURL.path, "--json", "--fail-on-added"])
        #expect(relocatedStrictJSON.exitCode == 3)

        // 5. Added listener or added orphan -> 3 with --fail-on-added
        #expect(CLIRunner.execute(arguments: ["LaunchLens", "diff", emptyURL.path, listenerURL.path, "--fail-on-added"]).exitCode == 3)
        #expect(CLIRunner.execute(arguments: ["LaunchLens", "diff", emptyURL.path, orphanURL.path, "--fail-on-added"]).exitCode == 3)
    }

    @Test("M2 Row 4 & Item 4: Repeated diff runs are byte-identical in text and --json; EN and ZH text share structure")
    @MainActor
    func testM2DiffByteIdenticalRepeatedRunsAndBilingualStructureParity() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LaunchLensM2Row4-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let removedSvc = SnapshotServiceEntry(
            domainScope: .global,
            label: "com.vendor.old",
            plistPath: "/Library/LaunchAgents/com.vendor.old.plist",
            plistSHA256: "1111",
            programCommand: "/opt/vendor/old-daemon"
        )
        let modBeforeSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.worker",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.worker.plist",
            plistSHA256: "aaaa",
            programCommand: "/opt/example/worker --threads 2"
        )
        let modAfterSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.worker",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.worker.plist",
            plistSHA256: "bbbb",
            programCommand: "/opt/example/worker --threads 4"
        )
        let addedSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.added",
            plistPath: "/private/tmp/agent/io.example.added.plist",
            isExternalPlist: true,
            plistSHA256: "cccc",
            programCommand: "/usr/bin/python3 /opt/example/added.py"
        )

        let removedListener = SnapshotListenerEntry(
            port: 8080,
            protocols: ["TCP4", "TCP6"],
            bindAddresses: ["127.0.0.1", "[::1]"],
            pid: 4100,
            ppid: 500,
            uid: 501,
            lstart: "Sat Nov 21 08:50:00 2026",
            executable: "/usr/bin/python3",
            invocationIdentity: "/usr/bin/python3::module:http.server",
            programCommand: "/usr/bin/python3 -m http.server 8080",
            isOrphan: false
        )
        let addedOrphanListener = SnapshotListenerEntry(
            port: 18765,
            protocols: ["TCP4"],
            bindAddresses: ["127.0.0.1"],
            pid: 6200,
            ppid: 1,
            uid: 501,
            lstart: "Sat Nov 21 09:05:00 2026",
            executable: "/opt/homebrew/bin/node",
            invocationIdentity: "/opt/homebrew/bin/node::script:/opt/example/mcp.js",
            programCommand: "/opt/homebrew/bin/node /opt/example/mcp.js",
            isOrphan: true
        )

        let removedOrphan = SnapshotOrphanEntry(
            pid: 3300,
            uid: 501,
            lstart: "Sat Nov 21 08:40:00 2026",
            executable: "/usr/bin/ruby",
            invocationIdentity: "/usr/bin/ruby::script:/opt/example/old.rb",
            programCommand: "/usr/bin/ruby /opt/example/old.rb"
        )
        let addedOrphan = SnapshotOrphanEntry(
            pid: 6300,
            uid: 501,
            lstart: "Sat Nov 21 09:06:00 2026",
            executable: "/usr/bin/python3",
            invocationIdentity: "/usr/bin/python3::script:/opt/example/orphan_task.py",
            programCommand: "/usr/bin/python3 /opt/example/orphan_task.py"
        )

        let beforeSnap = SessionSnapshot(
            capturedAt: Self.fixedT0,
            host: Self.sampleHost,
            services: [removedSvc, modBeforeSvc],
            listeners: [removedListener],
            orphans: [removedOrphan]
        )
        let afterSnap = SessionSnapshot(
            capturedAt: Self.fixedT1,
            host: Self.sampleHost,
            services: [modAfterSvc, addedSvc],
            listeners: [addedOrphanListener],
            orphans: [addedOrphan]
        )

        let beforeURL = dir.appendingPathComponent("before.json")
        let afterURL = dir.appendingPathComponent("after.json")
        try SessionSnapshot.encodePrettyJSON(beforeSnap).write(to: beforeURL)
        try SessionSnapshot.encodePrettyJSON(afterSnap).write(to: afterURL)

        // 1. Byte-identical across repeated runs in EN text, ZH text, and --json
        let en1 = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--lang", "en"])
        let en2 = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--lang", "en"])
        #expect(en1.exitCode == 0 && en2.exitCode == 0)
        #expect(!en1.stdout.isEmpty)
        #expect(Data(en1.stdout.utf8) == Data(en2.stdout.utf8))

        let zh1 = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--lang", "zh"])
        let zh2 = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--lang", "zh"])
        #expect(zh1.exitCode == 0 && zh2.exitCode == 0)
        #expect(!zh1.stdout.isEmpty)
        #expect(Data(zh1.stdout.utf8) == Data(zh2.stdout.utf8))

        let jsonEN1 = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--json", "--lang", "en"])
        let jsonEN2 = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--json", "--lang", "en"])
        let jsonZH = CLIRunner.execute(arguments: ["LaunchLens", "diff", beforeURL.path, afterURL.path, "--json", "--lang", "zh"])
        #expect(jsonEN1.exitCode == 0 && jsonEN2.exitCode == 0 && jsonZH.exitCode == 0)
        #expect(!jsonEN1.stdout.isEmpty)
        #expect(Data(jsonEN1.stdout.utf8) == Data(jsonEN2.stdout.utf8))
        #expect(Data(jsonEN1.stdout.utf8) == Data(jsonZH.stdout.utf8))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedDiff = try decoder.decode(SessionSnapshotDiff.self, from: Data(jsonEN1.stdout.utf8))
        #expect(decodedDiff.summary == SessionSnapshotDiffSummary(
            servicesAdded: 1,
            servicesRemoved: 1,
            servicesModified: 1,
            listenersAdded: 1,
            listenersRemoved: 1,
            orphansAdded: 1,
            orphansRemoved: 1
        ))

        // 2. Bilingual structural parity & required fields
        let enLines = en1.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let zhLines = zh1.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(enLines.count == zhLines.count)
        #expect(enLines.count == 11) // 3 section headers + 3 services + 2 listeners + 2 orphans + trailing ""

        for (eLine, zLine) in zip(enLines, zhLines) {
            let ePrefix = eLine.prefix(4)
            let zPrefix = zLine.prefix(4)
            if ePrefix == "  + " || ePrefix == "  - " || ePrefix == "  ~ " {
                #expect(ePrefix == zPrefix)
            }
            let eCols = eLine.components(separatedBy: " | ").count
            let zCols = zLine.components(separatedBy: " | ").count
            #expect(eCols == zCols)
        }

        // Verify required fields in EN & ZH text
        #expect(en1.stdout.contains("[user] io.example.added"))
        #expect(en1.stdout.contains("/private/tmp/agent/io.example.added.plist"))
        #expect(en1.stdout.contains(":18765"))
        #expect(en1.stdout.contains("127.0.0.1"))
        #expect(en1.stdout.contains("PID 6200 [orphan]"))
        #expect(en1.stdout.contains("PID 4100"))
        #expect(!en1.stdout.contains("PID 4100 [orphan]"))
        #expect(en1.stdout.contains("PID 6300"))
        #expect(en1.stdout.contains("Sat Nov 21 09:06:00 2026"))

        #expect(zh1.stdout.contains("[用户] io.example.added"))
        #expect(zh1.stdout.contains("PID 6200 [孤儿]"))
        #expect(!zh1.stdout.contains("PID 4100 [孤儿]"))
        #expect(zh1.stdout.contains("Sat Nov 21 09:06:00 2026"))
    }

    @Test("M2 Row 6 & Item 5: Redacts --token=abc123 and API_KEY=xyz in snapshot JSON and diff text/--json (including handwritten files)")
    @MainActor
    func testM2EndToEndAndDefensiveArgumentRedactionInSnapshotAndDiff() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LaunchLensM2Row6-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let emptyBeforeURL = dir.appendingPathComponent("before.json")
        let emptySnap = SessionSnapshot(capturedAt: Self.fixedT0, host: Self.sampleHost, services: [], listeners: [], orphans: [])
        try SessionSnapshot.encodePrettyJSON(emptySnap).write(to: emptyBeforeURL)

        // Part A: Capture via CLI snapshot with fake ps/lsof containing --token=abc123 and API_KEY=xyz
        let psSecretOut = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        68001     1   501  32768       00:20 Sat Nov 21 09:40:00 2026 env API_KEY=xyz /usr/bin/python3 /opt/example/agent_worker.py --token=abc123 --port 9000
        """
        let secretExec = FakeCLIHostExecutor { exe, _ in
            switch exe {
            case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
            case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psSecretOut)
            case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: "")
            default: return HostCommandResult(exitCode: 1)
            }
        }

        let capturedAfterURL = dir.appendingPathComponent("captured_after.json")
        let snapRes = CLIRunner.execute(
            arguments: ["LaunchLens", "snapshot", capturedAfterURL.path, "--lang", "en"],
            hostCommandExecutor: secretExec,
            snapshotPlistDirectories: [],
            snapshotUID: 501
        )
        #expect(snapRes.exitCode == 0)
        let capturedFileText = try String(contentsOf: capturedAfterURL, encoding: .utf8)
        #expect(!capturedFileText.contains("abc123"))
        #expect(!capturedFileText.contains("xyz"))
        #expect(capturedFileText.contains("***"))

        for extraArgs in [["--lang", "en"], ["--lang", "zh"], ["--json"]] {
            let diffOut = CLIRunner.execute(arguments: ["LaunchLens", "diff", emptyBeforeURL.path, capturedAfterURL.path] + extraArgs)
            #expect(diffOut.exitCode == 0)
            #expect(!diffOut.stdout.isEmpty)
            #expect(!diffOut.stdout.contains("abc123"))
            #expect(!diffOut.stdout.contains("xyz"))
            #expect(diffOut.stdout.contains("***"))
            #expect(!diffOut.stdout.contains("******"))
        }

        // Part B: Handwritten / legacy snapshot file containing raw unredacted secrets in services, listeners, and orphans
        let unredactedSnap = SessionSnapshot(
            capturedAt: Self.fixedT1,
            host: Self.sampleHost,
            services: [
                SnapshotServiceEntry(
                    domainScope: .user,
                    label: "io.example.legacy-svc",
                    plistPath: "/Users/devuser/Library/LaunchAgents/io.example.legacy-svc.plist",
                    programCommand: "/opt/example/svc --token=abc123 API_KEY=xyz"
                )
            ],
            listeners: [
                SnapshotListenerEntry(
                    port: 19999,
                    protocols: ["TCP4"],
                    bindAddresses: ["127.0.0.1"],
                    pid: 69001,
                    ppid: 1,
                    uid: 501,
                    lstart: "Sat Nov 21 09:45:00 2026",
                    executable: "/opt/homebrew/bin/node",
                    invocationIdentity: "/opt/homebrew/bin/node::inline:const k='x'; --token=abc123",
                    programCommand: "/opt/homebrew/bin/node -e \"--token=abc123\" API_KEY=xyz",
                    isOrphan: true
                )
            ],
            orphans: [
                SnapshotOrphanEntry(
                    pid: 69002,
                    uid: 501,
                    lstart: "Sat Nov 21 09:46:00 2026",
                    executable: "/usr/bin/python3",
                    invocationIdentity: "/usr/bin/python3::inline:import os --token=abc123",
                    programCommand: "env API_KEY=xyz /usr/bin/python3 /opt/example/raw_orphan.py --token=abc123"
                )
            ]
        )
        let handwrittenURL = dir.appendingPathComponent("handwritten_unredacted.json")
        try SessionSnapshot.encodePrettyJSON(unredactedSnap).write(to: handwrittenURL)
        // Sanity check: the raw file on disk really has abc123 and xyz
        let rawOnDisk = try String(contentsOf: handwrittenURL, encoding: .utf8)
        #expect(rawOnDisk.contains("abc123") && rawOnDisk.contains("xyz"))

        for extraArgs in [["--lang", "en"], ["--lang", "zh"], ["--json"]] {
            let diffOut = CLIRunner.execute(arguments: ["LaunchLens", "diff", emptyBeforeURL.path, handwrittenURL.path] + extraArgs)
            #expect(diffOut.exitCode == 0)
            #expect(!diffOut.stdout.isEmpty)
            #expect(!diffOut.stdout.contains("abc123"), "Leaked abc123 for \(extraArgs)")
            #expect(!diffOut.stdout.contains("xyz"), "Leaked xyz for \(extraArgs)")
            #expect(diffOut.stdout.contains("***"))
        }
    }

    @Test("M2 D3: Compiled LaunchLens binary executes direct snapshot/diff subcommands without --cli flag")
    func testM2CompiledBinaryDirectDiffSubcommandWithoutCLIFlag() throws {
        let exe = try builtExecutableURL()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LaunchLensM2BinD3-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let beforeSnap = SessionSnapshot(capturedAt: Self.fixedT0, host: Self.sampleHost, services: [], listeners: [], orphans: [])
        let afterSnap = SessionSnapshot(
            capturedAt: Self.fixedT1,
            host: Self.sampleHost,
            services: [],
            listeners: [],
            orphans: [
                SnapshotOrphanEntry(
                    pid: 88001,
                    uid: 501,
                    lstart: "Sat Nov 21 09:50:00 2026",
                    executable: "/usr/bin/python3",
                    invocationIdentity: "/usr/bin/python3::script:/opt/example/d3_orphan.py",
                    programCommand: "/usr/bin/python3 /opt/example/d3_orphan.py"
                )
            ]
        )
        let beforeURL = dir.appendingPathComponent("before.json")
        let afterURL = dir.appendingPathComponent("after.json")
        try SessionSnapshot.encodePrettyJSON(beforeSnap).write(to: beforeURL)
        try SessionSnapshot.encodePrettyJSON(afterSnap).write(to: afterURL)

        func runBinaryWithAlarm(_ cliArgs: [String]) throws -> (code: Int32, stdout: String, stderr: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            proc.arguments = ["-e", "alarm 60; exec @ARGV", exe.path] + cliArgs
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (
                proc.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self)
            )
        }

        // Direct diff -> exit 0
        let okRun = try runBinaryWithAlarm(["diff", beforeURL.path, afterURL.path, "--lang", "en"])
        #expect(okRun.code == 0)
        #expect(okRun.stdout.contains("Orphan Processes: +1 added, -0 removed"))
        #expect(okRun.stderr.isEmpty)

        // Direct diff with --fail-on-added -> exit 3
        let strictRun = try runBinaryWithAlarm(["diff", beforeURL.path, afterURL.path, "--fail-on-added", "--lang", "zh"])
        #expect(strictRun.code == 3)
        #expect(strictRun.stdout.contains("孤儿进程: +1 新增, -0 删除"))

        // Direct diff missing file -> exit 1, stdout empty
        let missingRun = try runBinaryWithAlarm(["diff", dir.appendingPathComponent("missing.json").path, afterURL.path])
        #expect(missingRun.code == 1)
        #expect(missingRun.stdout.isEmpty)

        // Direct snapshot missing <file> -> exit 2, stdout empty (never opens GUI)
        let badSnapRun = try runBinaryWithAlarm(["snapshot", "--lang", "en"])
        #expect(badSnapRun.code == 2)
        #expect(badSnapRun.stdout.isEmpty)
    }
}

private final class BundleToken {}
