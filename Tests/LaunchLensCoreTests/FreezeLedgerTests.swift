import Darwin
import Foundation
import Testing
@testable import LaunchLensCore

private final class ProgrammableLaunchctlMock: LaunchctlExecuting, @unchecked Sendable {
    var calls: [[String]] = []
    var printResult = LaunchctlResult(exitCode: 113, stderr: "Could not find service")
    var bootoutResult = LaunchctlResult(exitCode: 0)
    var bootstrapResult = LaunchctlResult(exitCode: 0)

    func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        calls.append(arguments)
        switch arguments.first {
        case "print":
            return printResult
        case "bootout":
            return bootoutResult
        case "bootstrap":
            return bootstrapResult
        default:
            return LaunchctlResult(exitCode: 2, stderr: "unknown launchctl subcommand")
        }
    }
}

@Suite("FreezeLedgerTests", .timeLimit(.minutes(1)))
struct FreezeLedgerTests {

    private func samplePlistData(label: String, program: String = "/usr/bin/true") -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(program)</string>
            </array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    @Test("Hermetic FreezeLedgerStore byte-exact freeze, SHA-256 verification, and restore round-trip")
    func testFreezeAndRestoreRoundTrip() throws {
        final class PathRecorder: @unchecked Sendable {
            var paths: [String] = []
        }
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensTests-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.demo.agent.plist")
        let originalData = samplePlistData(label: "io.demo.agent")
        try originalData.write(to: plistURL)

        let bootouts = PathRecorder()
        let bootstraps = PathRecorder()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            bootoutHandler: { bootouts.paths.append($0) },
            bootstrapHandler: { bootstraps.paths.append($0) }
        )

        let item = LaunchItem(
            id: "user::io.demo.agent",
            label: "io.demo.agent",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true",
            pid: 9999,
            rssBytes: 128 * 1024 * 1024
        )

        let canonicalPlistPath = plistURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rec = try store.freeze(item: item)
        #expect(rec.status == .frozen)
        #expect(!fm.fileExists(atPath: plistURL.path))
        #expect(fm.fileExists(atPath: rec.snapshotFilePath))
        #expect(bootouts.paths == [canonicalPlistPath])
        #expect(store.loadRecords().count == 1)
        #expect(!store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)

        try store.restore(recordID: rec.id)
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(bootstraps.paths == [canonicalPlistPath])
        #expect(store.loadRecords().isEmpty)
        #expect(!fm.fileExists(atPath: rec.snapshotFilePath))

        let restoredData = try Data(contentsOf: plistURL)
        #expect(restoredData == originalData)
    }

    @Test("Rejects freezing system daemons or com.apple.* services")
    func testProtectionInvariants() {
        let fm = FileManager.default
        let vaultDir = fm.temporaryDirectory.appendingPathComponent("LaunchLensGuard-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: vaultDir) }
        let store = FreezeLedgerStore(vaultDirectory: vaultDir, bootoutHandler: { _ in }, bootstrapHandler: { _ in })

        let sysItem = LaunchItem(
            id: "sys::com.docker.vmnetd",
            label: "com.docker.vmnetd",
            domain: .systemDaemon,
            plistPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist",
            programCommand: "/Library/PrivilegedHelperTools/com.docker.vmnetd"
        )
        #expect(throws: FreezeError.unsupportedDomain(ServiceDomain.systemDaemon.rawValue)) {
            try store.freeze(item: sysItem)
        }

        let appleItem = LaunchItem(
            id: "user::com.apple.SafariBookmarksSyncAgent",
            label: "com.apple.SafariBookmarksSyncAgent",
            domain: .userAgent,
            plistPath: "~/Library/LaunchAgents/com.apple.SafariBookmarksSyncAgent.plist",
            programCommand: "/usr/libexec/SafariBookmarksSyncAgent",
            isAppleSystem: true
        )
        #expect(throws: FreezeError.appleSystemProtected("com.apple.SafariBookmarksSyncAgent")) {
            try store.freeze(item: appleItem)
        }
    }

    @Test("Row 1 (L1, L2): Non-zero bootout throws, leaves original plist intact, cleans ledger and backup")
    @MainActor
    func testNonZeroBootoutRollsBackCleanly() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensRow1-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.test.bootoutfail.plist")
        let originalBytes = samplePlistData(label: "io.test.bootoutfail")
        try originalBytes.write(to: plistURL)

        let mock = ProgrammableLaunchctlMock()
        mock.bootoutResult = LaunchctlResult(exitCode: 36, stderr: "Boot-out failed: 36: Operation now in progress")

        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.bootoutfail",
            label: "io.test.bootoutfail",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )

        var caughtError: FreezeError?
        do {
            try store.freeze(item: item)
        } catch let err as FreezeError {
            caughtError = err
        }
        let err = try #require(caughtError)
        let enText = err.localizedMessage(AppLocalizer(fixedLanguage: .en))
        let zhText = err.localizedMessage(AppLocalizer(fixedLanguage: .zhHans))
        #expect(enText.contains("exit code 36"))
        #expect(enText.contains("left intact"))
        #expect(zhText.contains("退出码 36"))
        #expect(zhText.contains("原 plist 仍完好保留"))

        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(try Data(contentsOf: plistURL) == originalBytes)
        #expect(store.loadRecords().isEmpty)
        let snapFiles = (try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? []
        #expect(snapFiles.isEmpty)
        #expect(!store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
    }

    @Test("Row 2 (L1): Unwritable ledger aborts before bootout and leaves original plist untouched")
    @MainActor
    func testUnwritableLedgerAbortsBeforeBootout() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensRow2-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultDir.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: vaultDir.appendingPathComponent("ledger.json").path)
            try? fm.removeItem(at: tempRoot)
        }

        let plistURL = agentsDir.appendingPathComponent("io.test.ledgerfail.plist")
        let originalBytes = samplePlistData(label: "io.test.ledgerfail")
        try originalBytes.write(to: plistURL)

        let ledgerURL = vaultDir.appendingPathComponent("ledger.json")
        try Data("[]".utf8).write(to: ledgerURL)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ledgerURL.path)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.ledgerfail",
            label: "io.test.ledgerfail",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )

        var caughtError: FreezeError?
        do {
            try store.freeze(item: item)
        } catch let err as FreezeError {
            caughtError = err
        }
        let err = try #require(caughtError)
        #expect(err.localizedMessage(AppLocalizer(fixedLanguage: .en)).contains("bootout was NOT called"))
        #expect(err.localizedMessage(AppLocalizer(fixedLanguage: .zhHans)).contains("未调用 launchctl bootout"))
        #expect(mock.calls.isEmpty)
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(try Data(contentsOf: plistURL) == originalBytes)
        let snapFiles = (try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? []
        #expect(snapFiles.isEmpty)
    }

    @Test("L13 & Row 2: Read-only 0555 ledger directory aborts freeze before bootout with 0 launchctl calls and leaves plist untouched")
    func testReadOnlyLedgerDirectoryAbortsBeforeBootout() throws {
        func mtimePair(_ url: URL) throws -> [Int] {
            var st = stat()
            try #require(lstat(url.path, &st) == 0, "Expected lstat to succeed for \(url.path)")
            return [st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL13-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        // Subcase 1: Uninitialized vault directory set to 0555 while LaunchAgents stays writable (0755)
        let vaultDir1 = tempRoot.appendingPathComponent("VaultFresh0555")
        try fm.createDirectory(at: vaultDir1, withIntermediateDirectories: true)

        // Subcase 2: Initialized vault directory (Snapshots/ & Staged/ writable 0755) with ledger parent dir set to 0555
        let vaultDir2 = tempRoot.appendingPathComponent("VaultInit0555")
        let snapsDir2 = vaultDir2.appendingPathComponent("Snapshots")
        let stagedDir2 = vaultDir2.appendingPathComponent("Staged")
        try fm.createDirectory(at: snapsDir2, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagedDir2, withIntermediateDirectories: true)

        // Subcase 3: Frozen service in vault whose ledger directory becomes 0555 before restore (thaw)
        let vaultDir3 = tempRoot.appendingPathComponent("VaultRestore0555")

        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultDir1.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultDir2.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultDir3.path)
            try? fm.removeItem(at: tempRoot)
        }

        let plistURL1 = agentsDir.appendingPathComponent("io.test.l13fresh.plist")
        let orig1 = samplePlistData(label: "io.test.l13fresh")
        try orig1.write(to: plistURL1)

        let plistURL2 = agentsDir.appendingPathComponent("io.test.l13init.plist")
        let orig2 = samplePlistData(label: "io.test.l13init")
        try orig2.write(to: plistURL2)

        let sentinelDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: vaultDir1.path)
        try fm.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: snapsDir2.path)
        try fm.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: stagedDir2.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vaultDir1.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vaultDir2.path)

        let vault1MtimeBefore = try mtimePair(vaultDir1)
        let snaps2MtimeBefore = try mtimePair(snapsDir2)
        let staged2MtimeBefore = try mtimePair(stagedDir2)

        // Verify Subcase 1 (fresh 0555 vaultDir -> hits preflight check before any directory/file creation)
        let mock1 = ProgrammableLaunchctlMock()
        let store1 = FreezeLedgerStore(
            vaultDirectory: vaultDir1,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock1
        )
        let item1 = LaunchItem(
            id: "user::io.test.l13fresh",
            label: "io.test.l13fresh",
            domain: .userAgent,
            plistPath: plistURL1.path,
            programCommand: "/usr/bin/true"
        )
        var caught1: FreezeError?
        do {
            try store1.freeze(item: item1)
        } catch let err as FreezeError {
            caught1 = err
        }
        let err1 = try #require(caught1)
        if case .ledgerWriteFailed = err1 {
            // Expected structural error enum case from preflight ledger-writability check (no error text check)
        } else {
            Issue.record("Expected FreezeError.ledgerWriteFailed from preflight check in Subcase 1, got \(err1)")
        }
        #expect(((try? fm.contentsOfDirectory(atPath: vaultDir1.path)) ?? []).isEmpty)
        #expect(try mtimePair(vaultDir1) == vault1MtimeBefore)
        #expect(mock1.calls.isEmpty)
        #expect(fm.fileExists(atPath: plistURL1.path))
        #expect(try Data(contentsOf: plistURL1) == orig1)

        // Verify Subcase 2 (writable 0755 Snapshots/ & Staged/, read-only 0555 ledger dir -> structural zero-side-effect invariants)
        let mock2 = ProgrammableLaunchctlMock()
        let store2 = FreezeLedgerStore(
            vaultDirectory: vaultDir2,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock2
        )
        let item2 = LaunchItem(
            id: "user::io.test.l13init",
            label: "io.test.l13init",
            domain: .userAgent,
            plistPath: plistURL2.path,
            programCommand: "/usr/bin/true"
        )
        #expect(throws: FreezeError.self) {
            try store2.freeze(item: item2)
        }
        let leftoverSnaps = (try? fm.contentsOfDirectory(atPath: store2.snapshotsDirectory.path)) ?? []
        let leftoverStaged = (try? fm.contentsOfDirectory(atPath: store2.stagingDirectory.path)) ?? []
        #expect(leftoverSnaps.isEmpty)
        #expect(leftoverStaged.isEmpty)
        // Prove zero files/bytes were written into Snapshots/ or Staged/ even transiently before failure
        #expect(try mtimePair(snapsDir2) == snaps2MtimeBefore)
        #expect(try mtimePair(stagedDir2) == staged2MtimeBefore)
        #expect(mock2.calls.isEmpty)
        #expect(fm.fileExists(atPath: plistURL2.path))
        #expect(try Data(contentsOf: plistURL2) == orig2)

        // Verify Subcase 3 (restore / thaw on 0555 read-only vaultDir aborts before writing target plist or calling bootstrap)
        let plistURL3 = agentsDir.appendingPathComponent("io.test.l13restore.plist")
        let orig3 = samplePlistData(label: "io.test.l13restore")
        try orig3.write(to: plistURL3)
        let mock3 = ProgrammableLaunchctlMock()
        let store3 = FreezeLedgerStore(
            vaultDirectory: vaultDir3,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock3
        )
        let item3 = LaunchItem(
            id: "user::io.test.l13restore",
            label: "io.test.l13restore",
            domain: .userAgent,
            plistPath: plistURL3.path,
            programCommand: "/usr/bin/true"
        )
        let frozen3 = try store3.freeze(item: item3)
        mock3.calls.removeAll()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vaultDir3.path)

        #expect(throws: FreezeError.self) {
            try store3.restore(recordID: frozen3.id)
        }
        #expect(!fm.fileExists(atPath: plistURL3.path))
        #expect(mock3.calls.isEmpty)
        #expect(fm.fileExists(atPath: frozen3.snapshotFilePath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: frozen3.snapshotFilePath)) == orig3)
    }

    @Test("L1 Step 6 Finalize Failure: Rolls back staged plist to LaunchAgents and re-bootstraps")
    func testFinalLedgerWriteFailureRollsBackStagedPlistAndBootstraps() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensStep6-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.test.step6fail.plist")
        let originalBytes = samplePlistData(label: "io.test.step6fail")
        try originalBytes.write(to: plistURL)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock,
            ledgerWriteHook: { seq, records in
                // Allow write #1 (inProgress), fail write #2 (frozen)
                if seq == 2 {
                    #expect(records.first?.status == .frozen)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
                        NSLocalizedDescriptionKey: "Simulated disk I/O failure on final ledger commit"
                    ])
                }
            }
        )

        let item = LaunchItem(
            id: "user::io.test.step6fail",
            label: "io.test.step6fail",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )

        #expect(throws: FreezeError.self) {
            try store.freeze(item: item)
        }

        // User's plist MUST be back in LaunchAgents byte-identical, and bootstrap rollback MUST have run!
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(try Data(contentsOf: plistURL) == originalBytes)
        #expect(mock.calls.count == 2)
        #expect(mock.calls[0].first == "bootout")
        #expect(mock.calls[1].first == "bootstrap")
        #expect(store.loadRecords().isEmpty)
    }

    @Test("Row 3 (L2): Non-zero bootstrap throws and preserves both backup file and frozen ledger record")
    @MainActor
    func testNonZeroBootstrapPreservesBackupAndLedgerRecord() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensRow3-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.test.bootstrapfail.plist")
        let originalBytes = samplePlistData(label: "io.test.bootstrapfail")
        try originalBytes.write(to: plistURL)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.bootstrapfail",
            label: "io.test.bootstrapfail",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )
        let rec = try store.freeze(item: item)

        mock.bootstrapResult = LaunchctlResult(exitCode: 5, stderr: "Bootstrap failed: 5: Input/output error")
        var caughtError: FreezeError?
        do {
            try store.restore(recordID: rec.id)
        } catch let err as FreezeError {
            caughtError = err
        }
        let err = try #require(caughtError)
        #expect(err.localizedMessage(AppLocalizer(fixedLanguage: .en)).contains("exit code 5"))
        #expect(err.localizedMessage(AppLocalizer(fixedLanguage: .zhHans)).contains("退出码 5"))

        // Backup and frozen ledger record MUST still exist, and newly placed copy is rolled back
        #expect(!fm.fileExists(atPath: plistURL.path))
        #expect(fm.fileExists(atPath: rec.snapshotFilePath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: rec.snapshotFilePath)) == originalBytes)
        #expect(store.loadRecords().count == 1)
        #expect(store.loadRecords().first?.id == rec.id)

        // Subsequent retry when bootstrap succeeds restores cleanly
        mock.bootstrapResult = LaunchctlResult(exitCode: 0)
        try store.restore(recordID: rec.id)
        #expect(try Data(contentsOf: plistURL) == originalBytes)
        #expect(store.loadRecords().isEmpty)
    }

    @Test("Row 4 (L3): Restore refuses to overwrite an existing modified file and reports diff; supports explicit resolution")
    @MainActor
    func testRestoreRefusesSilentOverwriteOfModifiedTarget() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensRow4-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.test.conflict.plist")
        let oldData = samplePlistData(label: "io.test.conflict", program: "/opt/vendor/v1")
        try oldData.write(to: plistURL)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.conflict",
            label: "io.test.conflict",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/opt/vendor/v1"
        )
        let rec = try store.freeze(item: item)
        mock.calls.removeAll()

        // Simulate vendor update writing a new plist at originalPlistPath while frozen
        let upgradedData = samplePlistData(label: "io.test.conflict", program: "/opt/vendor/v2-upgraded")
        try upgradedData.write(to: plistURL)

        var caughtConflict: RestoreConflictSummary?
        var caughtErr: FreezeError?
        do {
            try store.restore(recordID: rec.id)
        } catch let err as FreezeError {
            caughtErr = err
            if case .restoreTargetConflict(let summary) = err {
                caughtConflict = summary
            }
        }
        let conflict = try #require(caughtConflict)
        let freezeErr = try #require(caughtErr)
        #expect(conflict.existingPath == rec.originalPlistPath)
        #expect(conflict.backupPath == rec.snapshotFilePath)
        #expect(conflict.diffSummary.contains("/opt/vendor/v1"))
        #expect(conflict.diffSummary.contains("/opt/vendor/v2-upgraded"))
        #expect(freezeErr.localizedMessage(AppLocalizer(fixedLanguage: .en)).contains(conflict.existingPath))
        #expect(freezeErr.localizedMessage(AppLocalizer(fixedLanguage: .zhHans)).contains("拒绝静默覆盖"))

        // Existing vendor file untouched, bootstrap NOT called, backup & ledger preserved
        #expect(mock.calls.isEmpty)
        #expect(try Data(contentsOf: plistURL) == upgradedData)
        #expect(fm.fileExists(atPath: rec.snapshotFilePath))
        #expect(store.loadRecords().count == 1)

        // Explicit user choice: overwriteExistingWithBackup restores original bytes and bootstraps
        try store.restore(recordID: rec.id, conflictResolution: .overwriteExistingWithBackup)
        #expect(try Data(contentsOf: plistURL) == oldData)
        #expect(mock.calls.count == 1)
        #expect(store.loadRecords().isEmpty)
    }

    @Test("Row 5 & Row 8 (L10): 1-byte corrupted backup is rejected on restore without writing plist or calling bootstrap")
    @MainActor
    func testCorruptedSnapshotRejectedOnRestore() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensRow5-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.test.tampered.plist")
        let originalBytes = samplePlistData(label: "io.test.tampered")
        try originalBytes.write(to: plistURL)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.tampered",
            label: "io.test.tampered",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )
        let rec = try store.freeze(item: item)
        mock.calls.removeAll()

        // Flip exactly 1 byte in the backup snapshot file
        let snapURL = URL(fileURLWithPath: rec.snapshotFilePath)
        var tampered = try Data(contentsOf: snapURL)
        tampered[tampered.count - 2] ^= 0x01
        try tampered.write(to: snapURL)

        #expect(throws: FreezeError.snapshotCorrupted("io.test.tampered")) {
            try store.restore(recordID: rec.id)
        }
        #expect(!fm.fileExists(atPath: plistURL.path))
        #expect(mock.calls.isEmpty)
        #expect(store.loadRecords().count == 1)
    }

    @Test("Row 6 & L8: Freeze rejects paths outside LaunchAgents, symlinks, symlinked subdirs, and duplicate labels")
    func testFreezeRejectsOutsidePathSymlinkAndDuplicateLabel() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensRow6-\(UUID().uuidString)")
        let outsideDir = tempRoot.appendingPathComponent("OutsideFolder")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let outsidePlist = outsideDir.appendingPathComponent("io.outside.agent.plist")
        try samplePlistData(label: "io.outside.agent").write(to: outsidePlist)

        let symlinkPlist = agentsDir.appendingPathComponent("io.symlink.agent.plist")
        try fm.createSymbolicLink(at: symlinkPlist, withDestinationURL: outsidePlist)

        let symlinkSubdir = agentsDir.appendingPathComponent("EscapeLink")
        try fm.createSymbolicLink(at: symlinkSubdir, withDestinationURL: outsideDir)
        let escapedPlist = symlinkSubdir.appendingPathComponent("io.outside.agent.plist")

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )

        // 1. Outside LaunchAgents rejected
        let outsideItem = LaunchItem(
            id: "user::io.outside.agent",
            label: "io.outside.agent",
            domain: .userAgent,
            plistPath: outsidePlist.path,
            programCommand: "/usr/bin/true"
        )
        #expect(throws: FreezeError.outsideLaunchAgentsDirectory(path: outsidePlist.path, requiredDirectory: agentsDir.path)) {
            try store.freeze(item: outsideItem)
        }
        #expect(fm.fileExists(atPath: outsidePlist.path))

        // 2. Symlink leaf rejected
        let symlinkItem = LaunchItem(
            id: "user::io.symlink.agent",
            label: "io.symlink.agent",
            domain: .userAgent,
            plistPath: symlinkPlist.path,
            programCommand: "/usr/bin/true"
        )
        #expect(throws: FreezeError.symlinkRejected(symlinkPlist.path)) {
            try store.freeze(item: symlinkItem)
        }

        // 3. Escaping symlinked subdirectory rejected
        let escapeItem = LaunchItem(
            id: "user::io.escape.agent",
            label: "io.outside.agent",
            domain: .userAgent,
            plistPath: escapedPlist.path,
            programCommand: "/usr/bin/true"
        )
        #expect(throws: FreezeError.outsideLaunchAgentsDirectory(path: escapedPlist.path, requiredDirectory: agentsDir.path)) {
            try store.freeze(item: escapeItem)
        }
        #expect(mock.calls.isEmpty)

        // 4. Duplicate label freeze rejected without leaking first snapshot
        let validPlist1 = agentsDir.appendingPathComponent("io.dup.agent.plist")
        try samplePlistData(label: "io.dup.agent", program: "/usr/bin/true").write(to: validPlist1)
        let dupItem = LaunchItem(
            id: "user::io.dup.agent",
            label: "io.dup.agent",
            domain: .userAgent,
            plistPath: validPlist1.path,
            programCommand: "/usr/bin/true"
        )
        let firstRec = try store.freeze(item: dupItem)

        // Write another file with the same label and attempt second freeze
        try samplePlistData(label: "io.dup.agent", program: "/usr/bin/false").write(to: validPlist1)
        #expect(throws: FreezeError.alreadyFrozen(label: "io.dup.agent", status: .frozen)) {
            try store.freeze(item: dupItem)
        }
        #expect(fm.fileExists(atPath: firstRec.snapshotFilePath))
        let snapCount = ((try? fm.contentsOfDirectory(atPath: store.snapshotsDirectory.path)) ?? []).count
        #expect(snapCount == 1)
    }

    @Test("M0 Item 3: Startup integrity check detects inProgress records & orphaned backups and recovers both losslessly")
    func testStartupIntegrityAuditAndLosslessRecovery() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensItem3-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let snapsDir = vaultDir.appendingPathComponent("Snapshots")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )

        // Case A: Interrupted "inProgress" record whose original plist was moved out before crash
        let interruptedBytes = samplePlistData(label: "io.crash.interrupted", program: "/opt/interrupted")
        let interruptedSnap = snapsDir.appendingPathComponent("io.crash.interrupted-crash1.plist")
        try interruptedBytes.write(to: interruptedSnap)
        let interruptedTarget = agentsDir.appendingPathComponent("io.crash.interrupted.plist")

        let inProgressRec = FreezeSnapshotRecord(
            id: "crash1",
            label: "io.crash.interrupted",
            originalPlistPath: interruptedTarget.path,
            snapshotFilePath: interruptedSnap.path,
            stagedPlistPath: nil,
            sha256Hex: FreezeLedgerStore.sha256Hex(interruptedBytes),
            frozenAt: Date(),
            rssBytesAtFreeze: 0,
            status: .inProgress
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([inProgressRec]).write(to: store.ledgerFileURL)

        // Case B: Orphaned .plist backup in Snapshots with NO ledger entry (legacy L1 failure)
        let orphanBytes = samplePlistData(label: "io.legacy.orphanbackup", program: "/opt/orphan")
        let orphanSnap = snapsDir.appendingPathComponent("io.legacy.orphanbackup-orphan99.plist")
        try orphanBytes.write(to: orphanSnap)

        let reportBefore = store.auditInterruptedTransactionsAndOrphanBackups()
        #expect(reportBefore.hasIssues)
        #expect(reportBefore.inProgressRecords.map(\.label) == ["io.crash.interrupted"])
        let expectedOrphanCanonical = orphanSnap.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(reportBefore.orphanedBackupPaths == [expectedOrphanCanonical])

        let summary = try store.recoverInterruptedAndOrphanBackups()
        #expect(summary.recoveredInProgressLabels == ["io.crash.interrupted"])
        #expect(summary.adoptedOrphanLabels == ["io.legacy.orphanbackup"])

        // Interrupted service restored byte-exact to LaunchAgents and bootstrapped!
        #expect(try Data(contentsOf: interruptedTarget) == interruptedBytes)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].first == "bootstrap")

        // Orphaned backup adopted into ledger as .frozen so user can restore it cleanly!
        let recordsAfter = store.loadRecords()
        #expect(recordsAfter.count == 1)
        #expect(recordsAfter.first?.label == "io.legacy.orphanbackup")
        #expect(recordsAfter.first?.status == .frozen)
        #expect(!store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
    }

    @Test("SystemLaunchctlExecutor captures exitCode, stdout, and stderr from programmable fake script")
    func testSystemLaunchctlExecutorWithFakeScript() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("LaunchLensExec-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("fake-launchctl.sh")
        let script = """
        #!/bin/sh
        if [ "$1" = "bootout" ]; then
            echo "simulated bootout error" >&2
            exit 19
        fi
        echo "ok:$*"
        exit 0
        """
        try Data(script.utf8).write(to: scriptURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let exec = SystemLaunchctlExecutor(executableURL: scriptURL)
        let failRes = exec.runLaunchctl(["bootout", "gui/501", "/tmp/a.plist"])
        #expect(failRes.exitCode == 19)
        #expect(failRes.stderr == "simulated bootout error")

        let okRes = exec.runLaunchctl(["bootstrap", "gui/501", "/tmp/a.plist"])
        #expect(okRes.exitCode == 0)
        #expect(okRes.stdout == "ok:bootstrap gui/501 /tmp/a.plist")
    }

    @Test("Step 5 Stage Move Failure: Re-bootstraps service, cleans ledger & backup, leaves original plist intact")
    func testStageMoveFailureRollsBackBootstrapAndLedger() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensStep5-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentsDir.path)
            try? fm.removeItem(at: tempRoot)
        }

        let plistURL = agentsDir.appendingPathComponent("io.test.movefail.plist")
        let originalBytes = samplePlistData(label: "io.test.movefail")
        try originalBytes.write(to: plistURL)

        // Make LaunchAgents directory read+execute (0555) so moving plist out fails in Step 5
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: agentsDir.path)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.movefail",
            label: "io.test.movefail",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )

        #expect(throws: FreezeError.self) {
            try store.freeze(item: item)
        }
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(try Data(contentsOf: plistURL) == originalBytes)
        #expect(mock.calls.count == 2)
        #expect(mock.calls[0].first == "bootout")
        #expect(mock.calls[1].first == "bootstrap")
        #expect(store.loadRecords().isEmpty)
        #expect(!store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
    }

    @Test("L14: Crash after bootout before stage-move re-bootstraps service on recovery and checks bootstrap exit code")
    @MainActor
    func testCrashAfterBootoutBeforeMoveRebootstrapsAndChecksExitCode() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL14-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempRoot) }

        func stagePostBootoutCrashState(caseName: String) throws -> (agentsDir: URL, vaultDir: URL, canonicalPlistPath: String, snapURL: URL, originalBytes: Data) {
            let caseRoot = tempRoot.appendingPathComponent(caseName)
            let agentsDir = caseRoot.appendingPathComponent("Library/LaunchAgents")
            let vaultDir = caseRoot.appendingPathComponent("Vault")
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

            let plistURL = agentsDir.appendingPathComponent("io.test.l14crash.plist")
            let originalBytes = samplePlistData(label: "io.test.l14crash", program: "/opt/l14/daemon")
            try originalBytes.write(to: plistURL)
            let canonicalPlistPath = plistURL.resolvingSymlinksInPath().standardizedFileURL.path

            let preCrashMock = ProgrammableLaunchctlMock()
            let preCrashStore = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: preCrashMock
            )

            // Exact post-Step-4 / pre-Step-5 disk state:
            // Step 2 wrote verified snapshot; Step 3 wrote .inProgress ledger record;
            // Step 4 ran launchctl bootout (exit 0 -> service unloaded!);
            // Crash occurred BEFORE Step 5 moved plistURL out of LaunchAgents.
            try fm.createDirectory(at: preCrashStore.snapshotsDirectory, withIntermediateDirectories: true)
            let snapURL = preCrashStore.snapshotsDirectory.appendingPathComponent("io.test.l14crash-tx14.plist")
            try originalBytes.write(to: snapURL, options: .atomic)
            let bootoutRes = preCrashMock.runLaunchctl(["bootout", "gui/501", canonicalPlistPath])
            #expect(bootoutRes.exitCode == 0)

            let inProgressRec = FreezeSnapshotRecord(
                id: "tx14",
                label: "io.test.l14crash",
                originalPlistPath: canonicalPlistPath,
                snapshotFilePath: snapURL.path,
                stagedPlistPath: preCrashStore.stagingDirectory.appendingPathComponent("io.test.l14crash-tx14.staged.plist").path,
                sha256Hex: FreezeLedgerStore.sha256Hex(originalBytes),
                frozenAt: Date(),
                rssBytesAtFreeze: 0,
                status: .inProgress
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([inProgressRec]).write(to: preCrashStore.ledgerFileURL, options: .atomic)

            return (agentsDir, vaultDir, canonicalPlistPath, snapURL, originalBytes)
        }

        // Case A (bootstrap exits 0): must call launchctl bootstrap gui/501 <plistPath>, check exit 0,
        // and only then remove orphan backup and clear inProgress record!
        do {
            let stateA = try stagePostBootoutCrashState(caseName: "caseA")
            let okRecoveryMock = ProgrammableLaunchctlMock()
            okRecoveryMock.bootstrapResult = LaunchctlResult(exitCode: 0)
            let okRecoveryStore = FreezeLedgerStore(
                vaultDirectory: stateA.vaultDir,
                userLaunchAgentsDirectory: stateA.agentsDir,
                uid: 501,
                launchctlExecutor: okRecoveryMock
            )

            let summary = try okRecoveryStore.recoverInterruptedAndOrphanBackups()
            #expect(okRecoveryMock.calls == [
                ["print", "gui/501/io.test.l14crash"],
                ["bootstrap", "gui/501", stateA.canonicalPlistPath]
            ])
            #expect(summary.recoveredInProgressLabels == ["io.test.l14crash"])
            #expect(fm.fileExists(atPath: stateA.canonicalPlistPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: stateA.canonicalPlistPath)) == stateA.originalBytes)
            #expect(!fm.fileExists(atPath: stateA.snapURL.path))
            #expect(okRecoveryStore.loadRecords().isEmpty)
            #expect(!okRecoveryStore.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
        }

        // Case B (bootstrap exits non-zero, e.g. 5): must NOT silently wipe recovery record or backup!
        do {
            let stateB = try stagePostBootoutCrashState(caseName: "caseB")
            let failRecoveryMock = ProgrammableLaunchctlMock()
            failRecoveryMock.bootstrapResult = LaunchctlResult(exitCode: 5, stderr: "Bootstrap failed: 5: Input/output error")
            let failRecoveryStore = FreezeLedgerStore(
                vaultDirectory: stateB.vaultDir,
                userLaunchAgentsDirectory: stateB.agentsDir,
                uid: 501,
                launchctlExecutor: failRecoveryMock
            )

            var caughtRecoveryError: FreezeError?
            do {
                _ = try failRecoveryStore.recoverInterruptedAndOrphanBackups()
            } catch let err as FreezeError {
                caughtRecoveryError = err
            }
            #expect(failRecoveryMock.calls == [
                ["print", "gui/501/io.test.l14crash"],
                ["bootstrap", "gui/501", stateB.canonicalPlistPath]
            ])
            #expect(fm.fileExists(atPath: stateB.canonicalPlistPath))
            #expect(fm.fileExists(atPath: stateB.snapURL.path))
            #expect(failRecoveryStore.loadRecords().count == 1)
            #expect(failRecoveryStore.loadRecords().first?.status == .inProgress)
            #expect(failRecoveryStore.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
            let recoveryErr = try #require(caughtRecoveryError)
            #expect(recoveryErr.localizedMessage(AppLocalizer(fixedLanguage: .en)).contains("exit code 5"))
            #expect(recoveryErr.localizedMessage(AppLocalizer(fixedLanguage: .zhHans)).contains("退出码 5"))
        }
    }

    @Test("L16 (XP2): Branch-1 recovery runs read-only launchctl print via fake executable before deciding whether to bootstrap")
    @MainActor
    func testL16Branch1RecoveryUsesFakeLaunchctlPrintPrecheck() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL16-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        func makeFakeLaunchctlScript(in caseDir: URL, printExit: Int32, bootstrapExit: Int32) throws -> (scriptURL: URL, callsLogURL: URL) {
            let binDir = caseDir.appendingPathComponent("fakebin")
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            let callsLogURL = binDir.appendingPathComponent("calls.log")
            let scriptURL = binDir.appendingPathComponent("fake-launchctl.sh")
            let script = """
            #!/bin/sh
            echo "$*" >> "\(callsLogURL.path)"
            if [ "$1" = "print" ]; then
                if [ "\(printExit)" != "0" ]; then
                    echo "Could not find service in domain" >&2
                fi
                exit \(printExit)
            fi
            if [ "$1" = "bootstrap" ]; then
                if [ "\(bootstrapExit)" != "0" ]; then
                    echo "Bootstrap failed: \(bootstrapExit): Input/output error" >&2
                fi
                exit \(bootstrapExit)
            fi
            exit 0
            """
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return (scriptURL, callsLogURL)
        }

        func stageBranch1InProgress(
            caseName: String,
            label: String,
            printExit: Int32,
            bootstrapExit: Int32
        ) throws -> (store: FreezeLedgerStore, callsLogURL: URL, canonicalPlistPath: String, snapURL: URL, stagedURL: URL, originalBytes: Data) {
            let caseDir = tempRoot.appendingPathComponent(caseName)
            let agentsDir = caseDir.appendingPathComponent("Library/LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

            let plistURL = agentsDir.appendingPathComponent("\(label).plist")
            let originalBytes = samplePlistData(label: label, program: "/opt/l16/\(caseName)")
            try originalBytes.write(to: plistURL, options: .atomic)
            let canonicalPlistPath = plistURL.resolvingSymlinksInPath().standardizedFileURL.path

            let fake = try makeFakeLaunchctlScript(in: caseDir, printExit: printExit, bootstrapExit: bootstrapExit)
            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: SystemLaunchctlExecutor(executableURL: fake.scriptURL)
            )
            try fm.createDirectory(at: store.snapshotsDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: store.stagingDirectory, withIntermediateDirectories: true)
            let snapURL = store.snapshotsDirectory.appendingPathComponent("\(label)-tx.plist")
            let stagedURL = store.stagingDirectory.appendingPathComponent("\(label)-tx.staged.plist")
            try originalBytes.write(to: snapURL, options: .atomic)
            try originalBytes.write(to: stagedURL, options: .atomic)

            let rec = FreezeSnapshotRecord(
                id: "tx-\(caseName)",
                label: label,
                originalPlistPath: canonicalPlistPath,
                snapshotFilePath: snapURL.path,
                stagedPlistPath: stagedURL.path,
                sha256Hex: FreezeLedgerStore.sha256Hex(originalBytes),
                frozenAt: Date(),
                rssBytesAtFreeze: 0,
                status: .inProgress
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([rec]).write(to: store.ledgerFileURL, options: .atomic)
            return (store, fake.callsLogURL, canonicalPlistPath, snapURL, stagedURL, originalBytes)
        }

        func readCalls(_ logURL: URL) -> [String] {
            guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        // Case A (crash before bootout: print exits 0 -> already loaded; bootstrap would exit 5):
        // Must NOT call bootstrap, must clean up backup/staged copies and clear .inProgress on the first call.
        do {
            let stateA = try stageBranch1InProgress(caseName: "caseA", label: "io.test.l16a", printExit: 0, bootstrapExit: 5)
            let summary = try stateA.store.recoverInterruptedAndOrphanBackups()
            #expect(readCalls(stateA.callsLogURL) == ["print gui/501/io.test.l16a"])
            #expect(summary.recoveredInProgressLabels == ["io.test.l16a"])
            #expect(fm.fileExists(atPath: stateA.canonicalPlistPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: stateA.canonicalPlistPath)) == stateA.originalBytes)
            #expect(!fm.fileExists(atPath: stateA.snapURL.path))
            #expect(!fm.fileExists(atPath: stateA.stagedURL.path))
            #expect(stateA.store.loadRecords().isEmpty)
            #expect(!stateA.store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
        }

        // Case B (crash after bootout before moveItem: print exits 113, bootstrap exits 0):
        // Sees print != 0, invokes launchctl bootstrap gui/501 <plistPath>, cleans backup/staged, clears .inProgress.
        do {
            let stateB = try stageBranch1InProgress(caseName: "caseB", label: "io.test.l16b", printExit: 113, bootstrapExit: 0)
            let summary = try stateB.store.recoverInterruptedAndOrphanBackups()
            #expect(readCalls(stateB.callsLogURL) == [
                "print gui/501/io.test.l16b",
                "bootstrap gui/501 \(stateB.canonicalPlistPath)"
            ])
            #expect(summary.recoveredInProgressLabels == ["io.test.l16b"])
            #expect(fm.fileExists(atPath: stateB.canonicalPlistPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: stateB.canonicalPlistPath)) == stateB.originalBytes)
            #expect(!fm.fileExists(atPath: stateB.snapURL.path))
            #expect(!fm.fileExists(atPath: stateB.stagedURL.path))
            #expect(stateB.store.loadRecords().isEmpty)
            #expect(!stateB.store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
        }

        // Case C (print exits 113 AND bootstrap exits 5):
        // Preserves .inProgress record, original plist, and snapshot backup, and surfaces explicit error.
        do {
            let stateC = try stageBranch1InProgress(caseName: "caseC", label: "io.test.l16c", printExit: 113, bootstrapExit: 5)
            var caught: FreezeError?
            do {
                _ = try stateC.store.recoverInterruptedAndOrphanBackups()
            } catch let err as FreezeError {
                caught = err
            }
            #expect(readCalls(stateC.callsLogURL) == [
                "print gui/501/io.test.l16c",
                "bootstrap gui/501 \(stateC.canonicalPlistPath)"
            ])
            #expect(fm.fileExists(atPath: stateC.canonicalPlistPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: stateC.canonicalPlistPath)) == stateC.originalBytes)
            #expect(fm.fileExists(atPath: stateC.snapURL.path))
            #expect(try Data(contentsOf: stateC.snapURL) == stateC.originalBytes)
            #expect(stateC.store.loadRecords().count == 1)
            #expect(stateC.store.loadRecords().first?.status == .inProgress)
            #expect(stateC.store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
            let err = try #require(caught)
            #expect(err.localizedMessage(AppLocalizer(fixedLanguage: .en)).contains("exit code 5"))
            #expect(err.localizedMessage(AppLocalizer(fixedLanguage: .zhHans)).contains("退出码 5"))
        }
    }

    @Test("L17 (XP1): Branch-2 recovery downgrades record to .frozen when bootstrap fails, removes partial copy, and allows manual restore")
    func testL17Branch2BootstrapFailureDowngradesToFrozenCleanly() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL17-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let binDir = tempRoot.appendingPathComponent("fakebin")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let exitCodeFile = binDir.appendingPathComponent("bootstrap_exit")
        let callsLogURL = binDir.appendingPathComponent("calls.log")
        let fakeScriptURL = binDir.appendingPathComponent("fake-launchctl.sh")
        let script = """
        #!/bin/sh
        echo "$*" >> "\(callsLogURL.path)"
        if [ "$1" = "bootstrap" ] && [ -f "\(exitCodeFile.path)" ]; then
            CODE="$(cat "\(exitCodeFile.path)")"
            if [ "$CODE" != "0" ]; then
                echo "Bootstrap failed: $CODE: Input/output error" >&2
                exit "$CODE"
            fi
        fi
        exit 0
        """
        try Data(script.utf8).write(to: fakeScriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeScriptURL.path)
        try Data("5".utf8).write(to: exitCodeFile, options: .atomic)

        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: SystemLaunchctlExecutor(executableURL: fakeScriptURL)
        )
        try fm.createDirectory(at: store.snapshotsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: store.stagingDirectory, withIntermediateDirectories: true)

        // Branch 2 state: crash occurred AFTER Step 5 moved .plist out of LaunchAgents and BEFORE Step 6 committed .frozen
        let label = "io.test.l17xp1"
        let originalBytes = samplePlistData(label: label, program: "/opt/l17/service")
        let dstURL = agentsDir.appendingPathComponent("\(label).plist")
        let snapURL = store.snapshotsDirectory.appendingPathComponent("\(label)-tx17.plist")
        let stagedURL = store.stagingDirectory.appendingPathComponent("\(label)-tx17.staged.plist")
        try originalBytes.write(to: snapURL, options: .atomic)
        try originalBytes.write(to: stagedURL, options: .atomic)

        let inProgressRec = FreezeSnapshotRecord(
            id: "tx17",
            label: label,
            originalPlistPath: dstURL.path,
            snapshotFilePath: snapURL.path,
            stagedPlistPath: stagedURL.path,
            sha256Hex: FreezeLedgerStore.sha256Hex(originalBytes),
            frozenAt: Date(),
            rssBytesAtFreeze: 0,
            status: .inProgress
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([inProgressRec]).write(to: store.ledgerFileURL, options: .atomic)

        // 1. Recovery attempts bootstrap (exit 5), removes partial copy in LaunchAgents, preserves vault backup,
        // and downgrades record from .inProgress to .frozen cleanly (80e49f1 contract).
        let summary = try store.recoverInterruptedAndOrphanBackups()
        #expect(summary.recoveredInProgressLabels == [label])
        #expect(!fm.fileExists(atPath: dstURL.path))
        #expect(!fm.fileExists(atPath: stagedURL.path))
        #expect(fm.fileExists(atPath: snapURL.path))
        #expect(try Data(contentsOf: snapURL) == originalBytes)

        let recordsAfterRecovery = store.loadRecords()
        #expect(recordsAfterRecovery.count == 1)
        let downgraded = try #require(recordsAfterRecovery.first)
        #expect(downgraded.id == "tx17")
        #expect(downgraded.status == .frozen)
        #expect(downgraded.stagedPlistPath == nil)
        #expect(!store.auditInterruptedTransactionsAndOrphanBackups().hasIssues)

        // 2. Subsequent manual restore succeeds cleanly once bootstrap exits 0
        try Data("0".utf8).write(to: exitCodeFile, options: .atomic)
        try store.restore(recordID: downgraded.id)
        #expect(fm.fileExists(atPath: dstURL.path))
        #expect(try Data(contentsOf: dstURL) == originalBytes)
        #expect(!fm.fileExists(atPath: snapURL.path))
        #expect(store.loadRecords().isEmpty)
    }

    @Test("L20: Mid-freeze step injection crash at every FreezeStep recovers service, plist bytes, ledger, and vault cleanly")
    func testL20MidFreezeStepInjectionCrashAndRecoveryAtEveryStep() throws {
        struct SimulatedCrashError: Error, Equatable {
            let step: FreezeStep
        }

        final class StatefulLaunchctlFake: LaunchctlExecuting, @unchecked Sendable {
            var loadedLabels: Set<String>
            var calls: [[String]] = []

            init(initiallyLoaded: Set<String>) {
                self.loadedLabels = initiallyLoaded
            }

            private func extractLabel(fromPlistPath path: String) -> String {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                   let dict = raw as? [String: Any],
                   let label = dict["Label"] as? String {
                    return label
                }
                return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            }

            func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
                calls.append(arguments)
                guard let sub = arguments.first else {
                    return LaunchctlResult(exitCode: 2, stderr: "missing subcommand")
                }
                switch sub {
                case "print":
                    guard arguments.count >= 2,
                          let slashIdx = arguments[1].lastIndex(of: "/") else {
                        return LaunchctlResult(exitCode: 2, stderr: "bad target")
                    }
                    let label = String(arguments[1][arguments[1].index(after: slashIdx)...])
                    if loadedLabels.contains(label) {
                        return LaunchctlResult(exitCode: 0, stdout: "gui/501/\(label) = { state = running }")
                    }
                    return LaunchctlResult(exitCode: 113, stderr: "Could not find service \"\(label)\" in domain for user gui: 501")
                case "bootout":
                    guard arguments.count >= 3 else {
                        return LaunchctlResult(exitCode: 2, stderr: "missing bootout path")
                    }
                    let label = extractLabel(fromPlistPath: arguments[2])
                    guard loadedLabels.contains(label) else {
                        return LaunchctlResult(exitCode: 3, stderr: "Boot-out failed: 3: No such process")
                    }
                    loadedLabels.remove(label)
                    return LaunchctlResult(exitCode: 0)
                case "bootstrap":
                    guard arguments.count >= 3 else {
                        return LaunchctlResult(exitCode: 2, stderr: "missing bootstrap path")
                    }
                    let label = extractLabel(fromPlistPath: arguments[2])
                    guard !loadedLabels.contains(label) else {
                        return LaunchctlResult(exitCode: 37, stderr: "Bootstrap failed: 37: Operation already in progress")
                    }
                    loadedLabels.insert(label)
                    return LaunchctlResult(exitCode: 0)
                default:
                    return LaunchctlResult(exitCode: 2, stderr: "unsupported subcommand \(sub)")
                }
            }
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL20Steps-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        #expect(FreezeStep.allCases == [
            .afterWriteBackup,
            .afterWriteInProgress,
            .afterBootout,
            .afterRemoveOriginalPlist,
            .afterWriteFrozen
        ])

        for (index, targetStep) in FreezeStep.allCases.enumerated() {
            let caseDir = tempRoot.appendingPathComponent("step-\(targetStep.rawValue)")
            let agentsDir = caseDir.appendingPathComponent("Library/LaunchAgents")
            let vaultDir = caseDir.appendingPathComponent("Vault")
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

            let label = "io.test.l20.\(targetStep.rawValue)"
            let plistURL = agentsDir.appendingPathComponent("\(label).plist")
            let originalBytes = samplePlistData(label: label, program: "/opt/l20/\(targetStep.rawValue)")
            try originalBytes.write(to: plistURL, options: .atomic)

            let fakeLaunchctl = StatefulLaunchctlFake(initiallyLoaded: [label])
            let useInitializerHook = (index % 2 == 0)
            var initHook: (@Sendable (FreezeStep) throws -> Void)? = nil
            var callHook: ((FreezeStep) throws -> Void)? = nil
            if useInitializerHook {
                initHook = { step in
                    if step == targetStep {
                        throw SimulatedCrashError(step: step)
                    }
                }
            } else {
                callHook = { step in
                    if step == targetStep {
                        throw SimulatedCrashError(step: step)
                    }
                }
            }
            let store = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: fakeLaunchctl,
                stepHook: initHook
            )

            let item = LaunchItem(
                id: "user::\(label)",
                label: label,
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/opt/l20/\(targetStep.rawValue)",
                pid: 4200 + index,
                rssBytes: 16 * 1024 * 1024
            )

            var caughtCrash: SimulatedCrashError?
            do {
                try store.freeze(item: item, afterStep: callHook)
            } catch let crash as SimulatedCrashError {
                caughtCrash = crash
            }
            #expect(caughtCrash == SimulatedCrashError(step: targetStep), "Expected simulated crash at \(targetStep)")

            // Audit must detect the interrupted artifact at every single step before recovery
            let preRecoveryAudit = store.auditInterruptedTransactionsAndOrphanBackups()
            #expect(preRecoveryAudit.hasIssues, "Expected audit issues right after crash at \(targetStep)")

            // Now run startup recovery against the same stateful launchctl domain
            let recoveryStore = FreezeLedgerStore(
                vaultDirectory: vaultDir,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: fakeLaunchctl
            )
            let summary = try recoveryStore.recoverInterruptedAndOrphanBackups()

            switch targetStep {
            case .afterWriteBackup, .afterWriteInProgress, .afterBootout, .afterRemoveOriginalPlist:
                // Service must be running/loaded, original plist intact & byte-equal, ledger & vault clean
                #expect(fakeLaunchctl.loadedLabels.contains(label), "Service must be loaded after recovering \(targetStep)")
                #expect(fm.fileExists(atPath: plistURL.path), "Original plist must exist after recovering \(targetStep)")
                #expect(try Data(contentsOf: plistURL) == originalBytes)
                #expect(recoveryStore.loadRecords().isEmpty, "Ledger must be empty after recovering \(targetStep)")
                let snapLeftovers = ((try? fm.contentsOfDirectory(atPath: recoveryStore.snapshotsDirectory.path)) ?? []).filter { $0.hasSuffix(".plist") }
                let stagedLeftovers = ((try? fm.contentsOfDirectory(atPath: recoveryStore.stagingDirectory.path)) ?? []).filter { $0.hasSuffix(".plist") }
                #expect(snapLeftovers.isEmpty, "Snapshots/ must have zero leftover plists for \(targetStep)")
                #expect(stagedLeftovers.isEmpty, "Staged/ must have zero leftover plists for \(targetStep)")
                #expect(!recoveryStore.auditInterruptedTransactionsAndOrphanBackups().hasIssues)
                if targetStep == .afterWriteBackup {
                    #expect(summary.cleanedDuplicatePaths.count == 1)
                    #expect(summary.adoptedOrphanLabels.isEmpty)
                } else {
                    #expect(summary.recoveredInProgressLabels == [label])
                }

            case .afterWriteFrozen:
                // Commit already succeeded before crash; recovery cleans leftover staged duplicate and keeps service frozen
                #expect(!fakeLaunchctl.loadedLabels.contains(label), "Committed freeze must remain unloaded after \(targetStep)")
                #expect(!fm.fileExists(atPath: plistURL.path))
                #expect(summary.cleanedDuplicatePaths.count == 1)
                let records = recoveryStore.loadRecords()
                #expect(records.count == 1)
                let frozenRec = try #require(records.first)
                #expect(frozenRec.status == .frozen)
                #expect(try Data(contentsOf: URL(fileURLWithPath: frozenRec.snapshotFilePath)) == originalBytes)
                let stagedLeftovers = ((try? fm.contentsOfDirectory(atPath: recoveryStore.stagingDirectory.path)) ?? []).filter { $0.hasSuffix(".plist") }
                #expect(stagedLeftovers.isEmpty)
                #expect(!recoveryStore.auditInterruptedTransactionsAndOrphanBackups().hasIssues)

                // Subsequent restore brings service & plist back byte-identically
                try recoveryStore.restore(recordID: frozenRec.id)
                #expect(fakeLaunchctl.loadedLabels.contains(label))
                #expect(try Data(contentsOf: plistURL) == originalBytes)
                #expect(recoveryStore.loadRecords().isEmpty)
            }
        }
    }

    @Test("L20 Preflight A: Non-existent vault under read-only 0555 ancestor fails in Step 1 preflight with ledgerWriteFailed")
    func testL20PreflightAncestorDirectoryWritability() throws {
        func mtimePair(_ url: URL) throws -> [Int] {
            var st = stat()
            try #require(lstat(url.path, &st) == 0)
            return [st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL20Anc-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let readOnlyAncestor = tempRoot.appendingPathComponent("ReadOnlyParent")
        // Vault is nested 2 levels deeper and does NOT exist on disk yet
        let nonExistentVaultDir = readOnlyAncestor
            .appendingPathComponent("ApplicationSupport")
            .appendingPathComponent("LaunchLens")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: readOnlyAncestor, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyAncestor.path)
            try? fm.removeItem(at: tempRoot)
        }

        let plistURL = agentsDir.appendingPathComponent("io.test.l20ancestor.plist")
        let originalBytes = samplePlistData(label: "io.test.l20ancestor")
        try originalBytes.write(to: plistURL, options: .atomic)

        let sentinelDate = Date(timeIntervalSince1970: 1_700_100_000)
        try fm.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: readOnlyAncestor.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyAncestor.path)
        let ancestorMtimeBefore = try mtimePair(readOnlyAncestor)

        let mock = ProgrammableLaunchctlMock()
        let store = FreezeLedgerStore(
            vaultDirectory: nonExistentVaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        let item = LaunchItem(
            id: "user::io.test.l20ancestor",
            label: "io.test.l20ancestor",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/usr/bin/true"
        )

        var caught: FreezeError?
        do {
            try store.freeze(item: item)
        } catch let err as FreezeError {
            caught = err
        }
        let err = try #require(caught)
        if case let .ledgerWriteFailed(step, _, _, _) = err {
            #expect(step.contains("Step 1/6"))
        } else {
            Issue.record("Expected Step 1/6 FreezeError.ledgerWriteFailed from ancestor writability check, got \(err)")
        }
        #expect(!fm.fileExists(atPath: nonExistentVaultDir.path))
        #expect(try mtimePair(readOnlyAncestor) == ancestorMtimeBefore)
        #expect(mock.calls.isEmpty)
        #expect(try Data(contentsOf: plistURL) == originalBytes)
    }

    @Test("L20 Preflight B: Writable 0755 vault with read-only 0555 Snapshots or Staged subdirectory fails in Step 1 before any write or bootout")
    func testL20PreflightSubdirectoryWritability() throws {
        func mtimePair(_ url: URL) throws -> [Int] {
            var st = stat()
            try #require(lstat(url.path, &st) == 0)
            return [st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL20Sub-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        // Case 1: vaultDir (0755) & Snapshots (0755) writable, Staged (0555) read-only.
        // Without subdirectory preflight, freeze would write backup + ledger and run launchctl bootout before failing in Step 5!
        let vaultStagedRO = tempRoot.appendingPathComponent("VaultStagedRO")
        let snaps1 = vaultStagedRO.appendingPathComponent("Snapshots")
        let staged1 = vaultStagedRO.appendingPathComponent("Staged")
        try fm.createDirectory(at: snaps1, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged1, withIntermediateDirectories: true)

        // Case 2: vaultDir (0755) & Staged (0755) writable, Snapshots (0555) read-only.
        let vaultSnapsRO = tempRoot.appendingPathComponent("VaultSnapsRO")
        let snaps2 = vaultSnapsRO.appendingPathComponent("Snapshots")
        let staged2 = vaultSnapsRO.appendingPathComponent("Staged")
        try fm.createDirectory(at: snaps2, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged2, withIntermediateDirectories: true)

        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged1.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snaps2.path)
            try? fm.removeItem(at: tempRoot)
        }

        let sentinelDate = Date(timeIntervalSince1970: 1_700_200_000)
        for dir in [vaultStagedRO, snaps1, staged1, vaultSnapsRO, snaps2, staged2] {
            try fm.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: dir.path)
        }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staged1.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snaps2.path)

        // Verify Case 1 (Staged = 0555)
        do {
            let plistURL = agentsDir.appendingPathComponent("io.test.l20stagedro.plist")
            let originalBytes = samplePlistData(label: "io.test.l20stagedro")
            try originalBytes.write(to: plistURL, options: .atomic)
            let snaps1Mtime = try mtimePair(snaps1)
            let vault1Mtime = try mtimePair(vaultStagedRO)

            let mock = ProgrammableLaunchctlMock()
            let store = FreezeLedgerStore(
                vaultDirectory: vaultStagedRO,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: mock
            )
            let item = LaunchItem(
                id: "user::io.test.l20stagedro",
                label: "io.test.l20stagedro",
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/usr/bin/true"
            )
            var caught: FreezeError?
            do {
                try store.freeze(item: item)
            } catch let err as FreezeError {
                caught = err
            }
            let err = try #require(caught)
            if case let .ledgerWriteFailed(step, _, _, _) = err {
                #expect(step.contains("Step 1/6"))
            } else {
                Issue.record("Expected Step 1/6 FreezeError.ledgerWriteFailed when Staged/ is 0555, got \(err)")
            }
            #expect(mock.calls.isEmpty, "Must NOT invoke launchctl bootout when Staged/ is read-only")
            #expect(((try? fm.contentsOfDirectory(atPath: snaps1.path)) ?? []).isEmpty)
            #expect(!fm.fileExists(atPath: store.ledgerFileURL.path))
            #expect(try mtimePair(snaps1) == snaps1Mtime)
            #expect(try mtimePair(vaultStagedRO) == vault1Mtime)
            #expect(try Data(contentsOf: plistURL) == originalBytes)
        }

        // Verify Case 2 (Snapshots = 0555)
        do {
            let plistURL = agentsDir.appendingPathComponent("io.test.l20snapsro.plist")
            let originalBytes = samplePlistData(label: "io.test.l20snapsro")
            try originalBytes.write(to: plistURL, options: .atomic)
            let staged2Mtime = try mtimePair(staged2)
            let vault2Mtime = try mtimePair(vaultSnapsRO)

            let mock = ProgrammableLaunchctlMock()
            let store = FreezeLedgerStore(
                vaultDirectory: vaultSnapsRO,
                userLaunchAgentsDirectory: agentsDir,
                uid: 501,
                launchctlExecutor: mock
            )
            let item = LaunchItem(
                id: "user::io.test.l20snapsro",
                label: "io.test.l20snapsro",
                domain: .userAgent,
                plistPath: plistURL.path,
                programCommand: "/usr/bin/true"
            )
            var caught: FreezeError?
            do {
                try store.freeze(item: item)
            } catch let err as FreezeError {
                caught = err
            }
            let err = try #require(caught)
            if case let .ledgerWriteFailed(step, _, _, _) = err {
                #expect(step.contains("Step 1/6"))
            } else {
                Issue.record("Expected Step 1/6 FreezeError.ledgerWriteFailed when Snapshots/ is 0555, got \(err)")
            }
            #expect(mock.calls.isEmpty)
            #expect(!fm.fileExists(atPath: store.ledgerFileURL.path))
            #expect(try mtimePair(staged2) == staged2Mtime)
            #expect(try mtimePair(vaultSnapsRO) == vault2Mtime)
            #expect(try Data(contentsOf: plistURL) == originalBytes)
        }
    }

    @Test("L20 Print Error: Unexpected launchctl print failure (exit != 0 and != 113) surfaces diagnostic without bootstrapping or corrupting state")
    @MainActor
    func testL20UnexpectedLaunchctlPrintFailurePreservesStateWithoutBootstrapping() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensL20PrintErr-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let label = "io.test.l20printerr"
        let plistURL = agentsDir.appendingPathComponent("\(label).plist")
        let originalBytes = samplePlistData(label: label, program: "/opt/l20/printerr")
        try originalBytes.write(to: plistURL, options: .atomic)
        let canonicalPlistPath = plistURL.resolvingSymlinksInPath().standardizedFileURL.path

        let mock = ProgrammableLaunchctlMock()
        mock.printResult = LaunchctlResult(exitCode: 1, stderr: "Domain does not support specified action")
        mock.bootstrapResult = LaunchctlResult(exitCode: 0)

        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: mock
        )
        try fm.createDirectory(at: store.snapshotsDirectory, withIntermediateDirectories: true)
        let snapURL = store.snapshotsDirectory.appendingPathComponent("\(label)-txprint.plist")
        try originalBytes.write(to: snapURL, options: .atomic)

        let inProgressRec = FreezeSnapshotRecord(
            id: "txprint",
            label: label,
            originalPlistPath: canonicalPlistPath,
            snapshotFilePath: snapURL.path,
            stagedPlistPath: nil,
            sha256Hex: FreezeLedgerStore.sha256Hex(originalBytes),
            frozenAt: Date(),
            rssBytesAtFreeze: 0,
            status: .inProgress
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([inProgressRec]).write(to: store.ledgerFileURL, options: .atomic)

        for unexpectedCode in [Int32(1), Int32(127)] {
            mock.calls.removeAll()
            mock.printResult = LaunchctlResult(
                exitCode: unexpectedCode,
                stderr: unexpectedCode == 127 ? "exec /bin/launchctl failed" : "Domain error"
            )

            var caught: FreezeError?
            do {
                _ = try store.recoverInterruptedAndOrphanBackups()
            } catch let err as FreezeError {
                caught = err
            }
            let err = try #require(caught, "Expected recoveryPrintFailed for exit code \(unexpectedCode)")
            if case let .recoveryPrintFailed(errLabel, exitCode, _, _, _) = err {
                #expect(errLabel == label)
                #expect(exitCode == unexpectedCode)
            } else {
                Issue.record("Expected FreezeError.recoveryPrintFailed, got \(err)")
            }

            let enMsg = err.localizedMessage(AppLocalizer(fixedLanguage: .en))
            let zhMsg = err.localizedMessage(AppLocalizer(fixedLanguage: .zhHans))
            #expect(enMsg.contains("exit code \(unexpectedCode)"))
            #expect(zhMsg.contains("退出码 \(unexpectedCode)"))

            // Must ONLY have called print — NEVER bootstrap! And on-disk state must remain intact.
            #expect(mock.calls == [["print", "gui/501/\(label)"]])
            #expect(fm.fileExists(atPath: canonicalPlistPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: canonicalPlistPath)) == originalBytes)
            #expect(fm.fileExists(atPath: snapURL.path))
            #expect(store.loadRecords().count == 1)
            #expect(store.loadRecords().first?.status == .inProgress)
        }
    }
}
