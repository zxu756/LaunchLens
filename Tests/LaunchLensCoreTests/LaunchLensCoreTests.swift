import Foundation
import Testing
@testable import LaunchLensCore

@Suite("LaunchLensCore Verification Suite")
struct LaunchLensCoreTests {

    @Test("Parses launchctl list output with active PIDs and idle dashes")
    func testParseLaunchctlList() {
        let sample = """
        PID\tStatus\tLabel
        31402\t0\tai.local.whisper-voice-agent
        -\t78\tcom.example.crashed-helper
        1409\t-\thomebrew.mxcl.postgresql@16
        """
        let parsed = LaunchScanner.parseLaunchctlList(sample)
        #expect(parsed.count == 3)
        #expect(parsed["ai.local.whisper-voice-agent"]?.pid == 31402)
        #expect(parsed["ai.local.whisper-voice-agent"]?.lastExitStatus == 0)
        #expect(parsed["com.example.crashed-helper"]?.pid == nil)
        #expect(parsed["com.example.crashed-helper"]?.lastExitStatus == 78)
        #expect(parsed["homebrew.mxcl.postgresql@16"]?.pid == 1409)
    }

    @Test("Parses ps RSS in KB, PPID, UID, CPU, and full command arguments")
    func testParsePSOutput() {
        let sample = """
          PID  PPID   UID    RSS  %CPU ARGS
        31402     1   501 5054136  6.4 /opt/homebrew/bin/whisper-server --port 8787
        48210     1   501  913408  3.1 node /opt/homebrew/lib/node_modules/@playwright/mcp/cli.js --port 9222
          612     1     0  663552  0.5 /Library/PrivilegedHelperTools/com.docker.vmnetd
        """
        let rows = LaunchScanner.parsePSOutput(sample)
        #expect(rows.count == 3)
        #expect(rows[31402]?.rssKB == 5_054_136)
        #expect(rows[48210]?.ppid == 1)
        #expect(rows[48210]?.uid == 501)
        #expect(rows[48210]?.command.contains("@playwright/mcp") == true)
    }

    @Test("Parses lsof machine-readable listening TCP port lines")
    func testParseLsofPorts() {
        let sample = """
        p31402
        n127.0.0.1:8787
        n[::1]:8787
        p48210
        n*:9222
        n127.0.0.1:9223
        """
        let ports = LaunchScanner.parseLsofPorts(sample)
        #expect(ports[31402] == [8787])
        #expect(ports[48210] == [9222, 9223])
    }

    @Test("Correlates LaunchAgents with live RSS and isolates PPID==1 developer orphan daemons")
    func testCorrelateAndOrphanDetection() {
        let plists = [
            PlistMetadata(
                label: "ai.local.whisper-voice-agent",
                plistPath: "~/Library/LaunchAgents/ai.local.whisper-voice-agent.plist",
                domain: .userAgent,
                programCommand: "/opt/homebrew/bin/whisper-server",
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.apple.Finder",
                plistPath: "/System/Library/LaunchAgents/com.apple.Finder.plist",
                domain: .systemDaemon,
                programCommand: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                runAtLoad: true,
                keepAlive: true
            )
        ]
        let lctl: [String: LaunchctlEntry] = [
            "ai.local.whisper-voice-agent": LaunchctlEntry(pid: 31402, lastExitStatus: 0, label: "ai.local.whisper-voice-agent"),
            "com.apple.Finder": LaunchctlEntry(pid: 410, lastExitStatus: 0, label: "com.apple.Finder")
        ]
        let procs: [Int: ProcessRow] = [
            31402: ProcessRow(pid: 31402, ppid: 1, uid: 501, rssKB: 1_048_576, cpuPercent: 4.0, command: "/opt/homebrew/bin/whisper-server"),
            48210: ProcessRow(pid: 48210, ppid: 1, uid: 501, rssKB: 512_000, cpuPercent: 2.0, command: "node /opt/mcp/server.js"),
            48999: ProcessRow(pid: 48999, ppid: 1, uid: 501, rssKB: 220_000, cpuPercent: 0.1, command: "/Applications/Slack.app/Contents/MacOS/Slack")
        ]
        let ports: [Int: [Int]] = [31402: [8787], 48210: [9222]]

        let items = LaunchScanner.correlate(
            plists: plists,
            launchctlMap: lctl,
            processes: procs,
            listeningPorts: ports,
            frozenRecords: [],
            currentUID: 501
        )

        let orphans = items.filter { $0.domain == .orphanDaemon }
        #expect(orphans.count == 1)
        #expect(orphans.first?.pid == 48210)
        #expect(orphans.first?.listeningPorts == [9222])
        #expect(items.first?.label == "ai.local.whisper-voice-agent")
        let expectedRSS: Int64 = 1_073_741_824
        #expect(items.first?.rssBytes == expectedRSS)
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
        let originalPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.demo.agent</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/true</string>
            </array>
        </dict>
        </plist>
        """
        let originalData = Data(originalPlist.utf8)
        try originalData.write(to: plistURL)

        let bootouts = PathRecorder()
        let bootstraps = PathRecorder()
        let store = FreezeLedgerStore(
            vaultDirectory: vaultDir,
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

        let rec = try store.freeze(item: item)
        #expect(!fm.fileExists(atPath: plistURL.path))
        #expect(fm.fileExists(atPath: rec.snapshotFilePath))
        #expect(bootouts.paths == [plistURL.path])
        #expect(store.loadRecords().count == 1)

        try store.restore(recordID: rec.id)
        #expect(fm.fileExists(atPath: plistURL.path))
        #expect(bootstraps.paths == [plistURL.path])
        #expect(store.loadRecords().isEmpty)

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
}
