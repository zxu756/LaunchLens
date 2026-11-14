import Foundation
import Testing
@testable import LaunchLensCore

@Suite("ScannerCorrelationTests", .timeLimit(.minutes(1)))
struct ScannerCorrelationTests {

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
            48211: ProcessRow(pid: 48211, ppid: 8420, uid: 501, rssKB: 256_000, cpuPercent: 1.2, command: "node /opt/mcp/live-terminal-session.js"),
            48212: ProcessRow(pid: 48212, ppid: 1, uid: 502, rssKB: 300_000, cpuPercent: 0.8, command: "node /opt/mcp/other-uid-daemon.js"),
            48213: ProcessRow(pid: 48213, ppid: 1, uid: 0, rssKB: 400_000, cpuPercent: 0.5, command: "node /opt/mcp/root-daemon.js"),
            48999: ProcessRow(pid: 48999, ppid: 1, uid: 501, rssKB: 220_000, cpuPercent: 0.1, command: "/Applications/Slack.app/Contents/MacOS/Slack")
        ]
        let ports: [Int: [Int]] = [31402: [8787], 48210: [9222], 48211: [9223], 48212: [9224]]

        let items = LaunchScanner.correlate(
            plists: plists,
            launchctlMap: lctl,
            processes: procs,
            listeningPorts: ports,
            frozenRecords: [],
            currentUID: 501
        )

        let orphans = items.filter { $0.domain == .orphanDaemon }
        #expect(orphans.map(\.pid) == [48210])
        #expect(orphans.first?.listeningPorts == [9222])
        #expect(items.first?.label == "ai.local.whisper-voice-agent")
        let expectedRSS: Int64 = 1_073_741_824
        #expect(items.first?.rssBytes == expectedRSS)
    }

    @Test("L10 & M0 Item 1: Does not mark inProgress records as frozen; enforces PPID==1, UID==currentUID, and launchctl claim")
    func testInProgressNotMarkedFrozenAndOwnershipGuards() {
        let inProgressRec = FreezeSnapshotRecord(
            id: "tx-inprogress",
            label: "io.test.midfreeze",
            originalPlistPath: "/tmp/LaunchAgents/io.test.midfreeze.plist",
            snapshotFilePath: "/tmp/Vault/Snapshots/io.test.midfreeze.plist",
            sha256Hex: "abc123",
            status: .inProgress
        )
        let frozenRec = FreezeSnapshotRecord(
            id: "tx-frozen",
            label: "io.test.committed",
            originalPlistPath: "/tmp/LaunchAgents/io.test.committed.plist",
            snapshotFilePath: "/tmp/Vault/Snapshots/io.test.committed.plist",
            sha256Hex: "def456",
            status: .frozen
        )

        let lctl: [String: LaunchctlEntry] = [
            "application.com.claimed.helper": LaunchctlEntry(pid: 7001, lastExitStatus: 0, label: "application.com.claimed.helper")
        ]
        let procs: [Int: ProcessRow] = [
            7001: ProcessRow(pid: 7001, ppid: 1, uid: 501, rssKB: 64_000, cpuPercent: 0.2, command: "node /usr/local/bin/claimed-mcp.js"),
            7002: ProcessRow(pid: 7002, ppid: 550, uid: 501, rssKB: 64_000, cpuPercent: 0.2, command: "node /usr/local/bin/non-orphan-ppid.js"),
            7003: ProcessRow(pid: 7003, ppid: 1, uid: 502, rssKB: 64_000, cpuPercent: 0.2, command: "node /usr/local/bin/other-user.js"),
            7004: ProcessRow(pid: 7004, ppid: 1, uid: 501, rssKB: 96_000, cpuPercent: 1.5, command: "node /usr/local/bin/true-orphan.js")
        ]

        let items = LaunchScanner.correlate(
            plists: [],
            launchctlMap: lctl,
            processes: procs,
            listeningPorts: [7004: [18768]],
            frozenRecords: [inProgressRec, frozenRec],
            currentUID: 501
        )

        let frozenItems = items.filter(\.isFrozen)
        #expect(frozenItems.map(\.label) == ["io.test.committed"])
        #expect(!items.contains(where: { $0.label == "io.test.midfreeze" }))

        let orphanPIDs = items.filter { $0.domain == .orphanDaemon }.compactMap(\.pid)
        #expect(orphanPIDs == [7004])
    }
}
