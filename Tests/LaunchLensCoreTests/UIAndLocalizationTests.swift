import Foundation
import Testing
@testable import LaunchLensCore

@Suite("UIAndLocalizationTests", .timeLimit(.minutes(1)))
struct UIAndLocalizationTests {

    @Test("Exports non-empty 2x Retina marketing screenshots")
    @MainActor
    func testExportScreenshots() throws {
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory.appendingPathComponent("LaunchLensShots-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: outDir) }

        try ScreenshotExporter.exportMarketingScreenshots(to: outDir)
        let mainData = try Data(contentsOf: outDir.appendingPathComponent("screenshot-main.png"))
        let menuData = try Data(contentsOf: outDir.appendingPathComponent("screenshot-menubar.png"))
        #expect(mainData.count > 25_000)
        #expect(menuData.count > 10_000)
    }

    @Test("Toggles live between zh-Hans and en and localizes freeze banners")
    @MainActor
    func testLanguageToggleAndBannerLocalization() throws {
        let suiteName = "launchlens.i18n.toggle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "local.xu.LaunchLens.language"
        let localizer = AppLocalizer(
            arguments: ["LaunchLens"],
            userDefaults: defaults,
            preferenceKey: key,
            preferredLanguages: ["en-US"]
        )
        #expect(localizer.language == .en)
        #expect(localizer.language.badge == "EN")

        let monitor = LaunchLensMonitor.preview()
        let enBanner = try #require(monitor.localizedStatusText(localizer))
        #expect(enBanner.contains("Frozen"))

        localizer.toggle()
        #expect(localizer.language == .zhHans)
        #expect(localizer.language.badge == "中文")
        #expect(defaults.string(forKey: key) == "zh-Hans")

        let zhBanner = try #require(monitor.localizedStatusText(localizer))
        #expect(zhBanner.contains("已冻结"))
        #expect(LaunchFilterTab.frozenVault.localizedTitle(localizer) == "冻结保险库")
    }

    @Test("Auto-detects Chinese system locale and respects UserDefaults & --lang flag")
    @MainActor
    func testChineseLocaleAutoDetectAndCLIFlag() throws {
        let suiteName = "launchlens.i18n.cli.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "local.xu.LaunchLens.language"
        let autoZH = AppLocalizer(
            arguments: ["LaunchLens"],
            userDefaults: defaults,
            preferenceKey: key,
            preferredLanguages: ["zh-Hans-CN", "en-US"]
        )
        #expect(autoZH.language == .zhHans)

        defaults.set("en", forKey: key)
        let savedEN = AppLocalizer(
            arguments: ["LaunchLens"],
            userDefaults: defaults,
            preferenceKey: key,
            preferredLanguages: ["zh-Hans-CN"]
        )
        #expect(savedEN.language == .en)

        let cliZH = AppLocalizer(
            arguments: ["LaunchLens", "--lang", "zh"],
            userDefaults: defaults,
            preferenceKey: key,
            preferredLanguages: ["en-US"]
        )
        #expect(cliZH.language == .zhHans)

        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchLensShotsZH-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outDir) }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sentinel = Data("keep-en-main".utf8)
        let enMain = outDir.appendingPathComponent("screenshot-main.png")
        try sentinel.write(to: enMain)

        try ScreenshotExporter.exportMarketingScreenshots(to: outDir, language: .zhHans)
        #expect(try Data(contentsOf: enMain) == sentinel)
        let zhMain = try Data(contentsOf: outDir.appendingPathComponent("screenshot-main-zh.png"))
        let zhMenu = try Data(contentsOf: outDir.appendingPathComponent("screenshot-menubar-zh.png"))
        #expect(zhMain.count > 25_000)
        #expect(zhMenu.count > 10_000)
    }

    @Test("M0 Item 7 (L5): Orphan rows are strictly read-only in UI with zero terminate/kill buttons")
    func testOrphanTerminateButtonsRemovedFromViews() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainViewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/LaunchLensCore/Views/MainDashboardView.swift"),
            encoding: .utf8
        )
        let menuPopoverSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/LaunchLensCore/Views/MenuBarPopoverView.swift"),
            encoding: .utf8
        )
        #expect(!mainViewSource.contains("terminateOrphan"))
        #expect(!mainViewSource.contains("Stop PID"))
        #expect(!mainViewSource.contains("终止进程"))
        #expect(!menuPopoverSource.contains("terminateOrphan"))
        #expect(!menuPopoverSource.contains("\"Stop\""))
    }

    @Test("M0 Item 5 (L6) & Item 2 (L3): Confirmation dialogs show exact launchctl commands & paths and handle conflict resolution in EN & ZH")
    @MainActor
    func testConfirmationFlowAndConflictResolutionBilingual() throws {
        final class RecordedCalls: LaunchctlExecuting, @unchecked Sendable {
            var calls: [[String]] = []
            func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
                calls.append(arguments)
                return LaunchctlResult(exitCode: 0)
            }
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensUIConfirm-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistURL = agentsDir.appendingPathComponent("io.ui.agent.plist")
        let v1Data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>io.ui.agent</string><key>Program</key><string>/opt/v1</string></dict></plist>
        """.utf8)
        try v1Data.write(to: plistURL)

        let recorder = RecordedCalls()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: recorder
        )
        let item = LaunchItem(
            id: "user::io.ui.agent",
            label: "io.ui.agent",
            domain: .userAgent,
            plistPath: plistURL.path,
            programCommand: "/opt/v1",
            pid: 4200,
            rssBytes: 64 * 1024 * 1024
        )
        let initialSnap = LaunchSnapshot(capturedAt: Date(), items: [item], frozenRecords: [])
        let monitor = LaunchLensMonitor(
            snapshot: initialSnap,
            ledgerStore: store,
            isStaticPreview: false,
            autoRefreshSeconds: nil
        )

        let enLoc = AppLocalizer(fixedLanguage: .en)
        let zhLoc = AppLocalizer(fixedLanguage: .zhHans)

        // 1. Requesting freeze does NOT execute bootout until confirmed
        monitor.requestFreeze(item)
        #expect(recorder.calls.isEmpty)
        #expect(fm.fileExists(atPath: plistURL.path))

        let pendingFreeze = try #require(monitor.pendingConfirmation)
        let enFreezeDetails = monitor.confirmationDetails(for: pendingFreeze, localizer: enLoc)
        let zhFreezeDetails = monitor.confirmationDetails(for: pendingFreeze, localizer: zhLoc)
        #expect(enFreezeDetails.exactCommand.contains("/bin/launchctl bootout gui/501"))
        #expect(enFreezeDetails.exactCommand.contains(plistURL.path))
        #expect(zhFreezeDetails.title == "确认冻结 LaunchAgent")
        #expect(zhFreezeDetails.sourcePath == plistURL.path)

        monitor.cancelPendingConfirmation()
        #expect(monitor.pendingConfirmation == nil)
        #expect(recorder.calls.isEmpty)

        // Re-request and confirm freeze
        monitor.requestFreeze(item)
        monitor.confirmPendingAction()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].first == "bootout")
        let frozenRec = try #require(store.loadFrozenRecords().first)

        // 2. Request restore and verify exact bootstrap command in EN & ZH
        monitor.requestRestore(frozenRec)
        let pendingRestore = try #require(monitor.pendingConfirmation)
        let enRestoreDetails = monitor.confirmationDetails(for: pendingRestore, localizer: enLoc)
        let zhRestoreDetails = monitor.confirmationDetails(for: pendingRestore, localizer: zhLoc)
        #expect(enRestoreDetails.exactCommand.contains("/bin/launchctl bootstrap gui/501"))
        #expect(zhRestoreDetails.title == "确认恢复 LaunchAgent")

        // Plant conflicting v2 plist before confirming restore
        let v2Data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>io.ui.agent</string><key>Program</key><string>/opt/v2</string></dict></plist>
        """.utf8)
        try v2Data.write(to: URL(fileURLWithPath: frozenRec.originalPlistPath))

        monitor.confirmPendingAction()
        // Must NOT overwrite v2Data; must surface conflict modal!
        #expect(try Data(contentsOf: URL(fileURLWithPath: frozenRec.originalPlistPath)) == v2Data)
        let conflictAction = try #require(monitor.pendingConfirmation)
        let zhConflictDetails = monitor.confirmationDetails(for: conflictAction, localizer: zhLoc)
        #expect(zhConflictDetails.title == "检测到目标配置文件冲突")
        #expect(zhConflictDetails.diffSummary?.contains("/opt/v1") == true)
        #expect(zhConflictDetails.diffSummary?.contains("/opt/v2") == true)

        // User chooses "Keep Existing & Clear Record"
        monitor.resolveConflictKeepExisting()
        #expect(try Data(contentsOf: URL(fileURLWithPath: frozenRec.originalPlistPath)) == v2Data)
        #expect(store.loadRecords().isEmpty)
    }

    @Test("M0 Item 3: Startup integrity banner surfaces interrupted records & orphan backups in EN & ZH and repairs cleanly")
    @MainActor
    func testStartupIntegrityBannerAndRepairFlow() throws {
        final class NoopLaunchctl: LaunchctlExecuting {
            func runLaunchctl(_ arguments: [String]) -> LaunchctlResult { LaunchctlResult(exitCode: 0) }
        }
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensUIIntegrity-\(UUID().uuidString)")
        let agentsDir = tempRoot.appendingPathComponent("Library/LaunchAgents")
        let vaultDir = tempRoot.appendingPathComponent("Vault")
        let snapsDir = vaultDir.appendingPathComponent("Snapshots")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let orphanPlist = snapsDir.appendingPathComponent("io.ui.orphan-1.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>io.ui.orphan</string></dict></plist>
        """.utf8).write(to: orphanPlist)

        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
            userLaunchAgentsDirectory: agentsDir,
            uid: 501,
            launchctlExecutor: NoopLaunchctl()
        )
        let monitor = LaunchLensMonitor(
            snapshot: LaunchSnapshot(capturedAt: Date(), items: [], frozenRecords: []),
            ledgerStore: store,
            isStaticPreview: false,
            autoRefreshSeconds: nil
        )

        #expect(monitor.integrityReport.hasIssues)
        let enText = try #require(monitor.localizedIntegrityBannerText(AppLocalizer(fixedLanguage: .en)))
        let zhText = try #require(monitor.localizedIntegrityBannerText(AppLocalizer(fixedLanguage: .zhHans)))
        #expect(enText.contains("1 orphaned backup"))
        #expect(zhText.contains("1 个无记录孤儿备份"))

        monitor.requestRepairIntegrity()
        #expect(monitor.pendingConfirmation != nil)
        monitor.confirmPendingAction()
        #expect(!monitor.integrityReport.hasIssues)
        #expect(store.loadFrozenRecords().map(\.label) == ["io.ui.orphan"])
    }
}
