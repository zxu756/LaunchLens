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
}

private final class BundleToken {}
