import Foundation
import Testing
@testable import LaunchLensCore

private final class ProgrammableLaunchctlMock: LaunchctlExecuting, @unchecked Sendable {
    var calls: [[String]] = []
    var bootoutResult = LaunchctlResult(exitCode: 0)
    var bootstrapResult = LaunchctlResult(exitCode: 0)

    func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        calls.append(arguments)
        switch arguments.first {
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
}
