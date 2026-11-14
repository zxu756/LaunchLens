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
}

private final class BundleToken {}
