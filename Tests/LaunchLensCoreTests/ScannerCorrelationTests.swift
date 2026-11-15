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

    @Test("M1 Parsers: Supports both 5-col and 6-col ps outputs and both tabular and -F pn lsof outputs")
    func testM1DualFormatPSAndLsofParsers() {
        // Synthetic 5-column `ps -axo pid,ppid,uid,rss,args` sample
        let syntheticPS5Col = """
          PID  PPID   UID    RSS ARGS
         1200     1   501  40960 /opt/homebrew/bin/node /opt/srv/api.js --port 4100
         1201  1200   501  20480 /opt/homebrew/bin/node /opt/srv/worker.js
          510     1     0  81920 /Library/PrivilegedHelperTools/com.example.helperd
        """
        let parsed5 = LaunchScanner.parsePSOutput(syntheticPS5Col)
        #expect(parsed5.count == 3)
        #expect(parsed5[1200]?.rssKB == 40_960)
        #expect(parsed5[1200]?.cpuPercent == 0.0)
        #expect(parsed5[1200]?.command == "/opt/homebrew/bin/node /opt/srv/api.js --port 4100")
        #expect(parsed5[1201]?.ppid == 1200)
        #expect(parsed5[510]?.uid == 0)

        // Synthetic tabular `lsof -nP -iTCP -sTCP:LISTEN` sample
        let syntheticLsofTabular = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node       1200 demo   19u  IPv4 0x1111111111111111      0t0  TCP 127.0.0.1:4100 (LISTEN)
        node       1200 demo   20u  IPv6 0x2222222222222222      0t0  TCP [::1]:4100 (LISTEN)
        Google\\x20 8800 demo   12u  IPv4 0x3333333333333333      0t0  TCP *:9091 (LISTEN)
        """
        let ports = LaunchScanner.parseLsofPorts(syntheticLsofTabular)
        #expect(ports[1200] == [4100])
        #expect(ports[8800] == [9091])
    }

    @Test("M1 Item 1 (L4): Detects CLI framework Python.app and Ruby.app orphans while excluding genuine GUI .app/.xpc/.appex bundles")
    func testM1OrphanPythonAppVsGenuineGUIAppExclusion() {
        let procs: [Int: ProcessRow] = [
            // CLI framework interpreters whose paths contain Python.app / Ruby.app / Xcode.app/Contents/Developer -> MUST be flagged!
            9101: ProcessRow(
                pid: 9101, ppid: 1, uid: 501, rssKB: 48_000, cpuPercent: 0.4,
                command: "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python -m http.server 18123"
            ),
            9102: ProcessRow(
                pid: 9102, ppid: 1, uid: 501, rssKB: 36_000, cpuPercent: 0.2,
                command: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python /opt/dev/orphan_worker.py"
            ),
            9103: ProcessRow(
                pid: 9103, ppid: 1, uid: 501, rssKB: 32_000, cpuPercent: 0.1,
                command: "/opt/homebrew/Cellar/ruby/3.3.5/Frameworks/Ruby.framework/Versions/3.3/Resources/Ruby.app/Contents/MacOS/ruby /opt/dev/orphan_job.rb"
            ),
            // Genuine GUI .app bundles, embedded GUI helpers, .xpc, and .appex -> MUST be excluded!
            9201: ProcessRow(
                pid: 9201, ppid: 1, uid: 501, rssKB: 250_000, cpuPercent: 1.0,
                command: "/Applications/Slack.app/Contents/MacOS/Slack"
            ),
            9202: ProcessRow(
                pid: 9202, ppid: 1, uid: 501, rssKB: 180_000, cpuPercent: 0.5,
                command: "/Applications/ChatGPT.app/Contents/Resources/codex --app-server"
            ),
            9203: ProcessRow(
                pid: 9203, ppid: 1, uid: 501, rssKB: 140_000, cpuPercent: 0.3,
                command: "/Applications/StudioSuite.app/Contents/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python embedded_helper.py"
            ),
            9204: ProcessRow(
                pid: 9204, ppid: 1, uid: 501, rssKB: 60_000, cpuPercent: 0.1,
                command: "/Library/Application Support/Vendor/SyncService.xpc/Contents/MacOS/SyncService"
            ),
            9205: ProcessRow(
                pid: 9205, ppid: 1, uid: 501, rssKB: 70_000, cpuPercent: 0.1,
                command: "/Applications/CloudDrive.app/Contents/PlugIns/FinderExt.appex/Contents/MacOS/FinderExt"
            )
        ]

        let items = LaunchScanner.correlate(
            plists: [],
            launchctlMap: [:],
            processes: procs,
            listeningPorts: [9101: [18123], 9202: [49152]],
            frozenRecords: [],
            currentUID: 501
        )
        let orphanPIDs = Set(items.filter { $0.domain == .orphanDaemon }.compactMap(\.pid))
        #expect(orphanPIDs == [9101, 9102, 9103])
    }

    @Test("M1 Item 1 (L5): Uses exact executable basename and interpreter target script/-m matching with zero substring false positives")
    func testM1OrphanExactBasenameAndInterpreterScriptClassification() {
        let plists = [
            PlistMetadata(
                label: "com.vendor.syncd",
                plistPath: "/tmp/LaunchAgents/com.vendor.syncd.plist",
                domain: .userAgent,
                programCommand: "/opt/vendor/bin/syncd --daemon",
                programArguments: ["/opt/vendor/bin/syncd", "--daemon"],
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.example.managed-py",
                plistPath: "/tmp/LaunchAgents/com.example.managed-py.plist",
                domain: .userAgent,
                programCommand: "/usr/bin/python3 /opt/services/managed_agent.py",
                programArguments: ["/usr/bin/python3", "/opt/services/managed_agent.py"],
                runAtLoad: true,
                keepAlive: true
            )
        ]

        let procs: [Int: ProcessRow] = [
            // Substring traps (PPID==1, UID==501, no listening port) -> MUST NOT be flagged!
            6001: ProcessRow(
                pid: 6001, ppid: 1, uid: 501, rssKB: 20_000, cpuPercent: 0.0,
                command: "/usr/local/bin/readme-viewer /tmp/mcp-notes/claude-python-node_modules.md"
            ),
            6002: ProcessRow(
                pid: 6002, ppid: 1, uid: 501, rssKB: 20_000, cpuPercent: 0.0,
                command: "/opt/tools/pythonista-indexer --daemon"
            ),
            6003: ProcessRow(
                pid: 6003, ppid: 1, uid: 501, rssKB: 20_000, cpuPercent: 0.0,
                command: "/opt/tools/mynodehelper --watch"
            ),
            // Known plist native binary -> matched to com.vendor.syncd, NOT orphan!
            6100: ProcessRow(
                pid: 6100, ppid: 1, uid: 501, rssKB: 44_000, cpuPercent: 0.2,
                command: "/opt/vendor/bin/syncd --daemon"
            ),
            // Known plist Python script -> matched to com.example.managed-py, NOT orphan!
            6101: ProcessRow(
                pid: 6101, ppid: 1, uid: 501, rssKB: 55_000, cpuPercent: 0.3,
                command: "/usr/bin/python3 /opt/services/managed_agent.py"
            ),
            // Different Python script & -m module -> MUST be flagged as distinct orphans!
            6102: ProcessRow(
                pid: 6102, ppid: 1, uid: 501, rssKB: 66_000, cpuPercent: 0.5,
                command: "/usr/bin/python3 /opt/experiments/rogue_worker.py --port 19102"
            ),
            6103: ProcessRow(
                pid: 6103, ppid: 1, uid: 501, rssKB: 77_000, cpuPercent: 0.6,
                command: "/usr/bin/python3 -u -m http.server 19103"
            ),
            // Live parent (ppid > 1) with node_modules in path -> MUST NOT be flagged!
            6200: ProcessRow(
                pid: 6200, ppid: 950, uid: 501, rssKB: 88_000, cpuPercent: 1.0,
                command: "node /tmp/work/node_modules/.bin/worker.js"
            ),
            // Root UID (uid == 0) -> MUST NOT be flagged as user orphan!
            6201: ProcessRow(
                pid: 6201, ppid: 1, uid: 0, rssKB: 99_000, cpuPercent: 0.2,
                command: "node /tmp/work/node_modules/.bin/root-worker.js"
            )
        ]

        let items = LaunchScanner.correlate(
            plists: plists,
            launchctlMap: [:],
            processes: procs,
            listeningPorts: [6102: [19102], 6103: [19103], 6200: [19200]],
            frozenRecords: [],
            currentUID: 501
        )

        let orphans = items.filter { $0.domain == .orphanDaemon }
        #expect(Set(orphans.compactMap(\.pid)) == [6102, 6103])

        let orphan6102 = orphans.first(where: { $0.pid == 6102 })
        let orphan6103 = orphans.first(where: { $0.pid == 6103 })
        #expect(orphan6102?.label.contains("rogue_worker.py") == true)
        #expect(orphan6103?.label.contains("-m http.server") == true)
        #expect(orphan6102?.label != orphan6103?.label)
    }

    @Test("M1 Item 2 (L7): Sums service RSS & ports across root + transitive descendants deduplicated by PID and matches system daemons by Program")
    func testM1ServiceDescendantTreeRSSDeduplicationAndSystemDaemonProgramMatch() {
        let plists = [
            PlistMetadata(
                label: "io.example.supervisor",
                plistPath: "~/Library/LaunchAgents/io.example.supervisor.plist",
                domain: .userAgent,
                programCommand: "/opt/bin/supervisor",
                programArguments: ["/opt/bin/supervisor"],
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.example.sysdaemon",
                plistPath: "/Library/LaunchDaemons/com.example.sysdaemon.plist",
                domain: .systemDaemon,
                programCommand: "/Library/PrivilegedHelperTools/com.example.sysdaemon",
                programArguments: ["/Library/PrivilegedHelperTools/com.example.sysdaemon"],
                runAtLoad: true,
                keepAlive: true
            )
        ]

        let lctl: [String: LaunchctlEntry] = [
            "io.example.supervisor": LaunchctlEntry(pid: 2000, lastExitStatus: 0, label: "io.example.supervisor")
            // Note: com.example.sysdaemon is a System LaunchDaemon, so user `launchctl list` does NOT include it
        ]

        let procs: [Int: ProcessRow] = [
            // User agent tree: 2000 -> 2001 -> 2002 (plus 2003 sibling child of 2000)
            2000: ProcessRow(pid: 2000, ppid: 1, uid: 501, rssKB: 100_000, cpuPercent: 1.5, command: "/opt/bin/supervisor"),
            2001: ProcessRow(pid: 2001, ppid: 2000, uid: 501, rssKB: 50_000, cpuPercent: 2.0, command: "python3 /opt/bin/child_worker.py"),
            2002: ProcessRow(pid: 2002, ppid: 2001, uid: 501, rssKB: 25_000, cpuPercent: 0.5, command: "node /opt/bin/grandchild_lsp.js"),
            2003: ProcessRow(pid: 2003, ppid: 2000, uid: 501, rssKB: 15_000, cpuPercent: 0.2, command: "/opt/bin/sidecar"),

            // System daemon tree (uid 0, not in user launchctl list): 612 -> 613
            612: ProcessRow(pid: 612, ppid: 1, uid: 0, rssKB: 300_000, cpuPercent: 1.0, command: "/Library/PrivilegedHelperTools/com.example.sysdaemon --foreground"),
            613: ProcessRow(pid: 613, ppid: 612, uid: 0, rssKB: 100_000, cpuPercent: 0.4, command: "/Library/PrivilegedHelperTools/com.example.sysdaemon-worker")
        ]

        let ports: [Int: [Int]] = [
            2000: [19000],
            2001: [19000, 19001], // 19000 shared socket inherited by child -> must be deduplicated
            2002: [19002],
            613: [2375]
        ]

        let items = LaunchScanner.correlate(
            plists: plists,
            launchctlMap: lctl,
            processes: procs,
            listeningPorts: ports,
            frozenRecords: [],
            currentUID: 501
        )

        let supervisor = items.first(where: { $0.label == "io.example.supervisor" })
        let expectedSupervisorRSS: Int64 = (100_000 + 50_000 + 25_000 + 15_000) * 1024
        #expect(supervisor?.pid == 2000)
        #expect(supervisor?.rssBytes == expectedSupervisorRSS)
        #expect(supervisor?.listeningPorts == [19000, 19001, 19002])

        let sysDaemon = items.first(where: { $0.label == "com.example.sysdaemon" })
        let expectedSysDaemonRSS: Int64 = (300_000 + 100_000) * 1024
        #expect(sysDaemon?.pid == 612)
        #expect(sysDaemon?.rssBytes == expectedSysDaemonRSS)
        #expect(sysDaemon?.listeningPorts == [2375])

        let orphans = items.filter { $0.domain == .orphanDaemon }
        #expect(orphans.isEmpty)

        // Direct unit check on tree deduplication helper with cyclic/diamond parent map
        let cyclicChildren: [Int: [Int]] = [10: [11, 12], 11: [12, 10], 12: [13]]
        let tree = LaunchScanner.collectProcessTreePIDs(roots: [10], childrenByPPID: cyclicChildren)
        #expect(tree == [10, 11, 12, 13])
    }

    @Test("M1 Item 4: Parses scrubbed real-machine macOS captures and enforces capture/synthetic fixture header rules")
    func testM1ScrubbedRealMachineFixturesAndSyntheticFixtureHeaders() throws {
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let fm = FileManager.default
        let fixtureFiles = try fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "txt" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        #expect(fixtureFiles.count >= 4)

        // Enforce fixture provenance rule across every fixture file in Tests/Fixtures
        for url in fixtureFiles {
            let name = url.lastPathComponent.lowercased()
            let content = try String(contentsOf: url, encoding: .utf8)
            let headerLines = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
            if name.contains("synthetic") {
                #expect(headerLines.lowercased().contains("synthetic"), "Synthetic fixture \(url.lastPathComponent) must state synthetic in header")
            } else {
                #expect(headerLines.contains("# Capture command:"), "Real capture \(url.lastPathComponent) must record exact capture command")
                #expect(headerLines.contains("# Capture timestamp: 2026-11-15"), "Real capture \(url.lastPathComponent) must record 2026-11-15 timestamp")
            }
            // Privacy guard: zero macOS user home paths in committed fixtures
            let macHomeDirPrefix = "/" + "Users" + "/"
            #expect(!content.contains(macHomeDirPrefix))
        }

        let lctlRaw = try String(contentsOf: fixturesDir.appendingPathComponent("macos-launchctl-list-2026-11-15.txt"), encoding: .utf8)
        let psRaw = try String(contentsOf: fixturesDir.appendingPathComponent("macos-ps-axo-2026-11-15.txt"), encoding: .utf8)
        let lsofRaw = try String(contentsOf: fixturesDir.appendingPathComponent("macos-lsof-listen-2026-11-15.txt"), encoding: .utf8)

        let lctlMap = LaunchScanner.parseLaunchctlList(lctlRaw)
        let psRows = LaunchScanner.parsePSOutput(psRaw)
        let lsofPorts = LaunchScanner.parseLsofPorts(lsofRaw)

        #expect(lctlMap.count == 548)
        #expect(psRows.count == 618)
        #expect(lsofPorts[23500] == [63767])
        #expect(lsofPorts[23501] == [63768])

        let scrubbedPlists = [
            PlistMetadata(
                label: "com.example.agent.11",
                plistPath: "/tmp/LaunchAgents/com.example.agent.11.plist",
                domain: .userAgent,
                programCommand: "/opt/example/services/com-example-agent-11",
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.example.agent.13",
                plistPath: "/tmp/LaunchAgents/com.example.agent.13.plist",
                domain: .userAgent,
                programCommand: "/opt/example/services/com-example-agent-13",
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.example.agent.15",
                plistPath: "/tmp/LaunchAgents/com.example.agent.15.plist",
                domain: .userAgent,
                programCommand: "/opt/example/services/com-example-agent-15",
                runAtLoad: true,
                keepAlive: true
            )
        ]

        let correlated = LaunchScanner.correlate(
            plists: scrubbedPlists,
            launchctlMap: lctlMap,
            processes: psRows,
            listeningPorts: lsofPorts,
            frozenRecords: [],
            currentUID: 501
        )

        let orphans = correlated.filter { $0.domain == .orphanDaemon }
        #expect(Set(orphans.compactMap(\.pid)) == [23500, 23501])
        let pyOrphan = orphans.first(where: { $0.pid == 23500 })
        let nodeOrphan = orphans.first(where: { $0.pid == 23501 })
        #expect(pyOrphan?.listeningPorts == [63767])
        #expect(pyOrphan?.label.contains("orphan_http_probe.py") == true)
        #expect(nodeOrphan?.listeningPorts == [63768])
        #expect(nodeOrphan?.label.contains("orphan_mcp_probe.js") == true)

        // Also verify synthetic edge-case fixture parses cleanly and sums Python.app orphan + child tree RSS
        let synPSRaw = try String(contentsOf: fixturesDir.appendingPathComponent("synthetic-ps-edge-cases.txt"), encoding: .utf8)
        let synRows = LaunchScanner.parsePSOutput(synPSRaw)
        #expect(synRows.count == 3)
        let synItems = LaunchScanner.correlate(
            plists: [],
            launchctlMap: [:],
            processes: synRows,
            listeningPorts: [77001: [28080]],
            frozenRecords: [],
            currentUID: 501
        )
        #expect(synItems.count == 1)
        let expectedSynRSS: Int64 = (51_200 + 12_800) * 1024
        #expect(synItems.first?.pid == 77001)
        #expect(synItems.first?.rssBytes == expectedSynRSS)
    }
}
