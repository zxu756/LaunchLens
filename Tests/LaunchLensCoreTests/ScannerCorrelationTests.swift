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

        #expect(lctlMap.count == 543)
        #expect(psRows.count == 597)
        #expect(lsofPorts[74202] == [55381])
        #expect(lsofPorts[23500] == [63767])
        #expect(lsofPorts[23501] == [63768])

        let scrubbedPlists = [
            PlistMetadata(
                label: "com.example.agent.04",
                plistPath: "/tmp/LaunchAgents/com.example.agent.04.plist",
                domain: .userAgent,
                programCommand: "/opt/example/services/com-example-agent-04",
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.example.agent.06",
                plistPath: "/tmp/LaunchAgents/com.example.agent.06.plist",
                domain: .userAgent,
                programCommand: "/opt/example/services/com-example-agent-06",
                runAtLoad: true,
                keepAlive: true
            ),
            PlistMetadata(
                label: "com.example.agent.07",
                plistPath: "/tmp/LaunchAgents/com.example.agent.07.plist",
                domain: .userAgent,
                programCommand: "/opt/example/services/com-example-agent-07",
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
        #expect(Set(orphans.compactMap(\.pid)) == [74202, 23500, 23501])
        let liveCapturedPyOrphan = orphans.first(where: { $0.pid == 74202 })
        let pyOrphan = orphans.first(where: { $0.pid == 23500 })
        let nodeOrphan = orphans.first(where: { $0.pid == 23501 })
        #expect(liveCapturedPyOrphan?.listeningPorts == [55381])
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

    @Test("LR3: Repeatable scrubbing script regenerates deterministic sanitized fixtures with exact command, real timestamp, scrubbing rules, and test-added line provenance")
    func testLR3FixtureScrubbingScriptDeterminismAndHeaderProvenance() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("Scripts/scrub-fixtures.py")
        let fixturesDir = repoRoot.appendingPathComponent("Tests/Fixtures")
        let fm = FileManager.default

        try #require(fm.fileExists(atPath: scriptURL.path), "Expected repeatable scrubbing script at Scripts/scrub-fixtures.py")

        // 1. Verify committed real-machine fixtures carry full LR3 provenance headers and exact test-added line numbers
        for fileName in [
            "macos-launchctl-list-2026-11-15.txt",
            "macos-ps-axo-2026-11-15.txt",
            "macos-lsof-listen-2026-11-15.txt"
        ] {
            let text = try String(contentsOf: fixturesDir.appendingPathComponent(fileName), encoding: .utf8)
            let allLines = text.components(separatedBy: "\n")
            let header = allLines.prefix(12).joined(separator: "\n")
            #expect(header.contains("# Capture command:"))
            #expect(header.contains("# Capture timestamp: 2026-11-15T"))
            #expect(!header.contains("2026-11-15T04:26:00Z"), "Fixture \(fileName) still has hand-rounded 04:26:00Z timestamp")
            #expect(header.contains("# Scrubbing rules:"))
            #expect(header.contains("# Test-added lines:"))

            if fileName == "macos-ps-axo-2026-11-15.txt" {
                var probeLines: [Int] = []
                for (zeroIdx, ln) in allLines.enumerated() where !ln.hasPrefix("#") {
                    if ln.contains("orphan_http_probe.py") || ln.contains("orphan_mcp_probe.js") {
                        probeLines.append(zeroIdx + 1)
                    }
                }
                #expect(probeLines.count == 2)
                for lineNo in probeLines {
                    #expect(header.contains("\(lineNo)"), "ps header must name exact 1-based test-added line \(lineNo)")
                }
            } else if fileName == "macos-lsof-listen-2026-11-15.txt" {
                var probeLines: [Int] = []
                for (zeroIdx, ln) in allLines.enumerated() where !ln.hasPrefix("#") {
                    if ln.contains(":63767") || ln.contains(":63768") {
                        probeLines.append(zeroIdx + 1)
                    }
                }
                #expect(probeLines.count == 2)
                for lineNo in probeLines {
                    #expect(header.contains("\(lineNo)"), "lsof header must name exact 1-based test-added line \(lineNo)")
                }
            }
        }

        // 2. Verify Scripts/scrub-fixtures.py deterministically scrubs raw inputs and records exact test-added lines
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensLR3-\(UUID().uuidString)")
        let rawDir = tempRoot.appendingPathComponent("raw")
        let outDir1 = tempRoot.appendingPathComponent("out1")
        let outDir2 = tempRoot.appendingPathComponent("out2")
        let outDirClean = tempRoot.appendingPathComponent("out_clean")
        try fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try Data("""
        PID\tStatus\tLabel
        4120\t0\tapplication.com.secretcorp.chat.991122
        -\t0\tcom.apple.Finder
        910\t0\tcom.secretcorp.sync-helper
        """.utf8).write(to: rawDir.appendingPathComponent("launchctl-list.txt"))

        let fakeHome = "/" + "Users" + "/alice_dev"
        let fakeSecret = "sk" + "-live-secret999"
        try Data("""
          PID  PPID   UID    RSS ARGS
            1     0     0  12000 /sbin/launchd
          910     1   501  24000 \(fakeHome)/Library/Application Support/SecretCorp/sync-helper --token=\(fakeSecret)
         4120     1   501 180000 /Applications/SecretCorpChat.app/Contents/MacOS/SecretCorpChat --user=alice_dev@example.com
         4200  4120   501  42000 /opt/homebrew/bin/node \(fakeHome)/Projects/secret-agent/worker.js
        """.utf8).write(to: rawDir.appendingPathComponent("ps-axo.txt"))

        try Data("""
        COMMAND     PID USER       FD   TYPE             DEVICE SIZE/OFF NODE NAME
        sync-help   910 alice_dev  11u  IPv4 0xdeadbeefcafebabe      0t0  TCP 127.0.0.1:49100 (LISTEN)
        SecretCor  4120 alice_dev  19u  IPv4 0xdeadbeefcafebabe      0t0  TCP 127.0.0.1:49200 (LISTEN)
        """.utf8).write(to: rawDir.appendingPathComponent("lsof-listen.txt"))

        func runScrubber(outDir: URL, injectOrphans: Bool) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var args = [
                scriptURL.path,
                "--raw-dir", rawDir.path,
                "--out-dir", outDir.path,
                "--captured-at", "2026-11-15T10:34:27Z"
            ]
            if injectOrphans {
                args.append("--inject-test-orphans")
            }
            proc.arguments = args
            let errPipe = Pipe()
            proc.standardError = errPipe
            try proc.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            #expect(proc.terminationStatus == 0, "Scrubber failed: \(errText)")
        }

        try runScrubber(outDir: outDir1, injectOrphans: true)
        try runScrubber(outDir: outDir2, injectOrphans: true)
        try runScrubber(outDir: outDirClean, injectOrphans: false)

        for fileName in [
            "macos-launchctl-list-2026-11-15.txt",
            "macos-ps-axo-2026-11-15.txt",
            "macos-lsof-listen-2026-11-15.txt"
        ] {
            let d1 = try Data(contentsOf: outDir1.appendingPathComponent(fileName))
            let d2 = try Data(contentsOf: outDir2.appendingPathComponent(fileName))
            #expect(d1 == d2, "Scrubber must be byte-for-byte deterministic on \(fileName)")

            let s1 = try #require(String(data: d1, encoding: .utf8))
            let macHomePrefix = "/" + "Users" + "/"
            #expect(!s1.contains(macHomePrefix))
            #expect(!s1.contains("alice_dev"))
            #expect(!s1.contains("secret-agent"))
            #expect(!s1.lowercased().contains("secretcorp"))
            #expect(!s1.contains(fakeSecret))
            #expect(!s1.contains("0xdeadbeefcafebabe"))

            let sClean = try String(contentsOf: outDirClean.appendingPathComponent(fileName), encoding: .utf8)
            #expect(sClean.contains("# Test-added lines: none"))
            #expect(!sClean.contains("orphan_mcp_probe.js"))
        }
    }

    @Test("LR1 & LR2: Bracketed before/after snapshots tolerate mid-scan child churn within 5%, print uptime on failure, use bottom-up ppid reference, and detail excluded listener reasons")
    func testLR1AndLR2BracketedSnapshotUptimeOnFailureAndBottomUpReferenceWithExcludedPortReasons() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let refScriptURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1_ledger_ref.py")
        let ledgerShURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1-ledger.sh")
        let fm = FileManager.default

        try #require(fm.fileExists(atPath: refScriptURL.path), "Expected standalone reference verifier at Scripts/acceptance/m1_ledger_ref.py")

        let refSource = try String(contentsOf: refScriptURL, encoding: .utf8)
        let shSource = try String(contentsOf: ledgerShURL, encoding: .utf8)

        // LR2 structural independence: neither m1-ledger.sh nor m1_ledger_ref.py may use top-down children_by_ppid / collect_tree
        #expect(!refSource.contains("children_by_ppid"))
        #expect(!refSource.contains("collect_tree"))
        #expect(!shSource.contains("children_by_ppid"))
        #expect(!shSource.contains("collect_tree"))
        #expect(refSource.contains("ancestor_chain"))

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensLR12-\(UUID().uuidString)")
        let userAgentsDir = tempRoot.appendingPathComponent("UserAgents")
        let globalAgentsDir = tempRoot.appendingPathComponent("GlobalAgents")
        let systemDaemonsDir = tempRoot.appendingPathComponent("SystemDaemons")
        let beforeDir = tempRoot.appendingPathComponent("before")
        let afterDir = tempRoot.appendingPathComponent("after")
        try fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: globalAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: systemDaemonsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: beforeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: afterDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.test.svc</string>
            <key>ProgramArguments</key>
            <array>
                <string>/opt/example/bin/test-svc</string>
            </array>
        </dict>
        </plist>
        """.utf8).write(to: userAgentsDir.appendingPathComponent("io.test.svc.plist"))

        let lctlText = """
        PID\tStatus\tLabel
        1000\t0\tio.test.svc
        -\t0\tcom.apple.Finder
        """
        try Data(lctlText.utf8).write(to: beforeDir.appendingPathComponent("launchctl-list.txt"))
        try Data(lctlText.utf8).write(to: afterDir.appendingPathComponent("launchctl-list.txt"))

        // Before snapshot: root 1000 alone = 100,000 KB (102,400,000 B)
        try Data("""
          PID  PPID   UID    RSS ARGS
            1     0     0  15000 /sbin/launchd
           88     1     0   4000 /Library/PrivilegedHelperTools/com.example.rootd
          499     1     0   2000 /usr/bin/login
          500   499   501   3000 -zsh
          507     1   501   5000 /usr/libexec/rapportd
          610     1   501  90000 /Applications/ExampleApp.app/Contents/MacOS/ExampleApp
          700   499   501   2500 -zsh
          710   700   501  12000 /opt/homebrew/bin/python3 /tmp/session_worker.py
         1000     1   501 100000 /opt/example/bin/test-svc
         2001     1   501  38000 /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
         2002     1   501  10000 /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
         2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
         9001  9002   501   1024 /opt/example/bin/cycle-a
         9002  9001   501   1024 /opt/example/bin/cycle-b
        """.utf8).write(to: beforeDir.appendingPathComponent("ps-axo.txt"))

        // After snapshot: root 1000 spawned child 1001 (+10,000 KB -> 110,000 KB = +10.0% <= 25% width cap)
        try Data("""
          PID  PPID   UID    RSS ARGS
            1     0     0  15000 /sbin/launchd
           88     1     0   4000 /Library/PrivilegedHelperTools/com.example.rootd
          499     1     0   2000 /usr/bin/login
          500   499   501   3000 -zsh
          507     1   501   5000 /usr/libexec/rapportd
          610     1   501  90000 /Applications/ExampleApp.app/Contents/MacOS/ExampleApp
          700   499   501   2500 -zsh
          710   700   501  12000 /opt/homebrew/bin/python3 /tmp/session_worker.py
         1000     1   501 100000 /opt/example/bin/test-svc
         1001  1000   501  10000 /opt/example/bin/test-svc-worker
         2001     1   501  38000 /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
         2002     1   501  10000 /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
         2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
         9001  9002   501   1024 /opt/example/bin/cycle-a
         9002  9001   501   1024 /opt/example/bin/cycle-b
        """.utf8).write(to: afterDir.appendingPathComponent("ps-axo.txt"))

        let lsofBefore = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rootd        88 root   5u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:8088 (LISTEN)
        rapportd    507 dev    4u   IPv4 0x1000000000000000      0t0  TCP *:49152 (LISTEN)
        ExampleAp   610 dev    9u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:7679 (LISTEN)
        python3     710 dev    6u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:55270 (LISTEN)
        test-svc   1000 dev    8u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:18080 (LISTEN)
        node       2001 dev   10u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19001 (LISTEN)
        python3    2002 dev   11u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19002 (LISTEN)
        node       2003 dev   12u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19003 (LISTEN)
        """
        let lsofAfter = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rootd        88 root   5u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:8088 (LISTEN)
        rapportd    507 dev    4u   IPv4 0x1000000000000000      0t0  TCP *:49152 (LISTEN)
        ExampleAp   610 dev    9u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:7679 (LISTEN)
        python3     710 dev    6u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:55270 (LISTEN)
        test-svc   1001 dev    8u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:18080 (LISTEN)
        node       2001 dev   10u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19001 (LISTEN)
        python3    2002 dev   11u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19002 (LISTEN)
        node       2003 dev   12u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19003 (LISTEN)
        """
        try Data(lsofBefore.utf8).write(to: beforeDir.appendingPathComponent("lsof-listen.txt"))
        try Data(lsofAfter.utf8).write(to: afterDir.appendingPathComponent("lsof-listen.txt"))

        func writeCLIJSON(to url: URL, serviceRSSBytes: Int64) throws {
            let orphanRSS: Int64 = (38_000 + 10_000) * 1024
            let json = """
            {
              "orphanRSSBytes": \(orphanRSS),
              "totalBackgroundRSSBytes": \(serviceRSSBytes + orphanRSS),
              "services": [
                {
                  "domain": "User LaunchAgent",
                  "isAppleSystem": false,
                  "label": "io.test.svc",
                  "listeningPorts": [18080],
                  "pid": 1000,
                  "rssBytes": \(serviceRSSBytes)
                }
              ],
              "orphans": [
                {
                  "domain": "Orphaned Process",
                  "isAppleSystem": false,
                  "label": "node (m1_orphan_node_probe.js)",
                  "listeningPorts": [19001],
                  "pid": 2001,
                  "rssBytes": \(38_000 * 1024)
                },
                {
                  "domain": "Orphaned Process",
                  "isAppleSystem": false,
                  "label": "python3 (m1_orphan_py_probe.py)",
                  "listeningPorts": [19002],
                  "pid": 2002,
                  "rssBytes": \(10_000 * 1024)
                }
              ]
            }
            """
            try Data(json.utf8).write(to: url)
        }

        func runRefVerifier(before: URL = beforeDir, after: URL = afterDir, cliJSONURL: URL) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [
                refScriptURL.path,
                "--before-dir", before.path,
                "--after-dir", after.path,
                "--cli-json", cliJSONURL.path,
                "--user-agents-dir", userAgentsDir.path,
                "--global-agents-dir", globalAgentsDir.path,
                "--system-daemons-dir", systemDaemonsDir.path,
                "--current-uid", "501",
                "--node-pid", "2001", "--node-port", "19001",
                "--py-pid", "2002", "--py-port", "19002",
                "--live-child-pid", "2003", "--live-child-ppid", "500", "--live-child-port", "19003"
            ]
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
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // Case A: Stable 10% bracket shift (100,000 KB before -> 110,000 KB after, product 105,000 KB inside bracket) passes with 0.0000% diff
        let validCLIURL = tempRoot.appendingPathComponent("cli-valid-10pct.json")
        try writeCLIJSON(to: validCLIURL, serviceRSSBytes: 105_000 * 1024)
        let passRun = try runRefVerifier(cliJSONURL: validCLIURL)
        #expect(passRun.exitCode == 0, "Expected stable 10% bracketed sample to pass, got stderr: \(passRun.stderr)")
        #expect(passRun.stdout.contains("[M1 Row 1 PASS]"))
        #expect(passRun.stdout.contains("max_rss_diff=0.0000%"))
        #expect(passRun.stdout.contains("[M1 Row 2 PASS]"))
        #expect(passRun.stdout.contains("host_lsof_listener_pids=8"))
        #expect(passRun.stdout.contains("tracked_listener_pids=3"))
        #expect(passRun.stdout.contains("excluded_listener_pids=5"))
        #expect(passRun.stdout.contains("apple_system=1"))
        #expect(passRun.stdout.contains("gui_app_bundle=1"))
        #expect(passRun.stdout.contains("live_session_child=1"))
        #expect(passRun.stdout.contains("injected_live_parent_control=1"))
        #expect(passRun.stdout.contains("other_uid=1"))
        #expect(passRun.stdout.contains("unaccounted_listeners=0"))
        #expect(passRun.stdout.contains("[M1 Row 3 PASS]"))

        // Case B: Out-of-bracket >5% deviation on stable 10% bracket (130,000 KB vs max 110,000 KB = +18.18%) MUST fail AND print host uptime
        let badCLIURL = tempRoot.appendingPathComponent("cli-bad.json")
        try writeCLIJSON(to: badCLIURL, serviceRSSBytes: 130_000 * 1024)
        let failRun = try runRefVerifier(cliJSONURL: badCLIURL)
        #expect(failRun.exitCode != 0)
        #expect(failRun.stderr.contains("exceeded 5%"))
        #expect(failRun.stderr.lowercased().contains("load averages:"), "Failure diagnostic must print uptime load averages, got: \(failRun.stderr)")

        // Case C: Unstable wide bracket (14 MB before -> 480 MB after, product 247 MB in the middle) MUST fail (> 25% width cap) AND print before/after + uptime
        let wideBeforeDir = tempRoot.appendingPathComponent("wide_before")
        let wideAfterDir = tempRoot.appendingPathComponent("wide_after")
        try fm.createDirectory(at: wideBeforeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wideAfterDir, withIntermediateDirectories: true)
        try Data(lctlText.utf8).write(to: wideBeforeDir.appendingPathComponent("launchctl-list.txt"))
        try Data(lctlText.utf8).write(to: wideAfterDir.appendingPathComponent("launchctl-list.txt"))
        try Data(lsofBefore.utf8).write(to: wideBeforeDir.appendingPathComponent("lsof-listen.txt"))
        try Data(lsofAfter.utf8).write(to: wideAfterDir.appendingPathComponent("lsof-listen.txt"))
        // 14 MB = 14,336 KB (14,680,064 B); 480 MB = 491,520 KB (503,316,480 B)
        try Data("""
          PID  PPID   UID    RSS ARGS
            1     0     0  15000 /sbin/launchd
           88     1     0   4000 /Library/PrivilegedHelperTools/com.example.rootd
          499     1     0   2000 /usr/bin/login
          500   499   501   3000 -zsh
          507     1   501   5000 /usr/libexec/rapportd
          610     1   501  90000 /Applications/ExampleApp.app/Contents/MacOS/ExampleApp
          700   499   501   2500 -zsh
          710   700   501  12000 /opt/homebrew/bin/python3 /tmp/session_worker.py
         1000     1   501  14336 /opt/example/bin/test-svc
         2001     1   501  38000 /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
         2002     1   501  10000 /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
         2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
        """.utf8).write(to: wideBeforeDir.appendingPathComponent("ps-axo.txt"))
        try Data("""
          PID  PPID   UID    RSS ARGS
            1     0     0  15000 /sbin/launchd
           88     1     0   4000 /Library/PrivilegedHelperTools/com.example.rootd
          499     1     0   2000 /usr/bin/login
          500   499   501   3000 -zsh
          507     1   501   5000 /usr/libexec/rapportd
          610     1   501  90000 /Applications/ExampleApp.app/Contents/MacOS/ExampleApp
          700   499   501   2500 -zsh
          710   700   501  12000 /opt/homebrew/bin/python3 /tmp/session_worker.py
         1000     1   501  14336 /opt/example/bin/test-svc
         1001  1000   501 477184 /opt/example/bin/test-svc-worker
         2001     1   501  38000 /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
         2002     1   501  10000 /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
         2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
        """.utf8).write(to: wideAfterDir.appendingPathComponent("ps-axo.txt"))

        let wideMidCLIURL = tempRoot.appendingPathComponent("cli-wide-mid.json")
        try writeCLIJSON(to: wideMidCLIURL, serviceRSSBytes: 247 * 1024 * 1024)
        let wideFailRun = try runRefVerifier(before: wideBeforeDir, after: wideAfterDir, cliJSONURL: wideMidCLIURL)
        #expect(wideFailRun.exitCode != 0, "14 MB -> 480 MB wide bracket with middle product value MUST fail (>25% cap), not pass!")
        #expect(!wideFailRun.stdout.contains("PASS"))
        #expect(!wideFailRun.stdout.contains("SKIPPED"))
        #expect(wideFailRun.stderr.contains("14680064"))
        #expect(wideFailRun.stderr.contains("503316480"))
        #expect(wideFailRun.stderr.lowercased().contains("load averages:"))
    }

    @Test("LR1 Cap & Retry: Enforces 25% bracket width cap (with 64KB small-amount exemption), retries up to 3 rounds, and fails with per-round before/after & uptime after 3 unstable retries")
    func testLR1BracketWidthCapResamplingUpToThreeRetriesAndExhaustionFailure() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let refScriptURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1_ledger_ref.py")
        let fm = FileManager.default

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensLR1CapRetry-\(UUID().uuidString)")
        let userAgentsDir = tempRoot.appendingPathComponent("UserAgents")
        let globalAgentsDir = tempRoot.appendingPathComponent("GlobalAgents")
        let systemDaemonsDir = tempRoot.appendingPathComponent("SystemDaemons")
        try fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: globalAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: systemDaemonsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.test.svc</string>
            <key>ProgramArguments</key>
            <array>
                <string>/opt/example/bin/test-svc</string>
            </array>
        </dict>
        </plist>
        """.utf8).write(to: userAgentsDir.appendingPathComponent("io.test.svc.plist"))

        let lctlText = """
        PID\tStatus\tLabel
        1000\t0\tio.test.svc
        """
        let lsofText = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        test-svc   1000 dev    8u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:18080 (LISTEN)
        node       2001 dev   10u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19001 (LISTEN)
        python3    2002 dev   11u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19002 (LISTEN)
        node       2003 dev   12u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19003 (LISTEN)
        """

        func makeRoundDir(name: String, beforeSvcKB: Int64, afterSvcKB: Int64, cliSvcKB: Int64) throws -> URL {
            let rDir = tempRoot.appendingPathComponent(name)
            let bDir = rDir.appendingPathComponent("before")
            let aDir = rDir.appendingPathComponent("after")
            try fm.createDirectory(at: bDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
            try Data(lctlText.utf8).write(to: bDir.appendingPathComponent("launchctl-list.txt"))
            try Data(lctlText.utf8).write(to: aDir.appendingPathComponent("launchctl-list.txt"))
            try Data(lsofText.utf8).write(to: bDir.appendingPathComponent("lsof-listen.txt"))
            try Data(lsofText.utf8).write(to: aDir.appendingPathComponent("lsof-listen.txt"))

            func psFor(_ svcKB: Int64) -> String {
                """
                  PID  PPID   UID    RSS ARGS
                    1     0     0  15000 /sbin/launchd
                  499     1     0   2000 /usr/bin/login
                  500   499   501   3000 -zsh
                 1000     1   501  \(svcKB) /opt/example/bin/test-svc
                 2001     1   501  38000 /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
                 2002     1   501  10000 /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
                 2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
                """
            }
            try Data(psFor(beforeSvcKB).utf8).write(to: bDir.appendingPathComponent("ps-axo.txt"))
            try Data(psFor(afterSvcKB).utf8).write(to: aDir.appendingPathComponent("ps-axo.txt"))

            let orphanBytes: Int64 = (38_000 + 10_000) * 1024
            let svcBytes = cliSvcKB * 1024
            let cliJSON = """
            {
              "orphanRSSBytes": \(orphanBytes),
              "totalBackgroundRSSBytes": \(svcBytes + orphanBytes),
              "services": [
                {
                  "domain": "User LaunchAgent",
                  "isAppleSystem": false,
                  "label": "io.test.svc",
                  "listeningPorts": [18080],
                  "pid": 1000,
                  "rssBytes": \(svcBytes)
                }
              ],
              "orphans": [
                {
                  "domain": "Orphaned Process",
                  "isAppleSystem": false,
                  "label": "node (m1_orphan_node_probe.js)",
                  "listeningPorts": [19001],
                  "pid": 2001,
                  "rssBytes": \(38_000 * 1024)
                },
                {
                  "domain": "Orphaned Process",
                  "isAppleSystem": false,
                  "label": "python3 (m1_orphan_py_probe.py)",
                  "listeningPorts": [19002],
                  "pid": 2002,
                  "rssBytes": \(10_000 * 1024)
                }
              ]
            }
            """
            try Data(cliJSON.utf8).write(to: rDir.appendingPathComponent("cli.json"))
            return rDir
        }

        func runRounds(_ roundDirs: [URL], maxRetries: Int = 3) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var args = [
                refScriptURL.path,
                "--max-retries", "\(maxRetries)",
                "--user-agents-dir", userAgentsDir.path,
                "--global-agents-dir", globalAgentsDir.path,
                "--system-daemons-dir", systemDaemonsDir.path,
                "--current-uid", "501",
                "--node-pid", "2001", "--node-port", "19001",
                "--py-pid", "2002", "--py-port", "19002",
                "--live-child-pid", "2003", "--live-child-ppid", "500", "--live-child-port", "19003",
                "--round-dirs"
            ]
            args.append(contentsOf: roundDirs.map(\.path))
            proc.arguments = args
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
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // 1. 64KB small-amount exemption: 120 KB -> 168 KB (+40% > 25%, abs diff 48 KB <= 64 KB) passes; 120 KB -> 220 KB (abs diff 100 KB > 64 KB) fails
        let tinyExemptRound = try makeRoundDir(name: "tiny_exempt", beforeSvcKB: 120, afterSvcKB: 168, cliSvcKB: 144)
        let tinyPass = try runRounds([tinyExemptRound], maxRetries: 0)
        #expect(tinyPass.exitCode == 0, "Expected <=64KB small-process diff to be exempted, stderr: \(tinyPass.stderr)")

        let tinyExceedRound = try makeRoundDir(name: "tiny_exceed", beforeSvcKB: 120, afterSvcKB: 220, cliSvcKB: 170)
        let tinyFail = try runRounds([tinyExceedRound], maxRetries: 0)
        #expect(tinyFail.exitCode != 0, "Expected >25% & >64KB diff to fail")

        // 2. Resampling succeeds within <= 3 retries: Round 1 unstable (14MB->480MB), Retry 1 unstable (480MB->14MB), Retry 2 stable (100MB->110MB, 10%)
        let u1 = try makeRoundDir(name: "u1", beforeSvcKB: 14 * 1024, afterSvcKB: 480 * 1024, cliSvcKB: 247 * 1024)
        let u2 = try makeRoundDir(name: "u2", beforeSvcKB: 480 * 1024, afterSvcKB: 14 * 1024, cliSvcKB: 200 * 1024)
        let s3 = try makeRoundDir(name: "s3", beforeSvcKB: 100 * 1024, afterSvcKB: 110 * 1024, cliSvcKB: 105 * 1024)
        let retryPass = try runRounds([u1, u2, s3], maxRetries: 3)
        #expect(retryPass.exitCode == 0, "Expected retry 2 (10% bracket) to succeed after discarding 2 unstable rounds, stderr: \(retryPass.stderr)")
        #expect(retryPass.stdout.contains("[M1 Row 1 PASS]"))

        // 3. Exhausting all 3 retries (initial + 3 retries = 4 unstable rounds; 5th stable round ignored) MUST fail (neither pass nor skip) and print EVERY round's before/after + uptime
        let ex1 = try makeRoundDir(name: "ex1", beforeSvcKB: 14_000, afterSvcKB: 480_000, cliSvcKB: 200_000)
        let ex2 = try makeRoundDir(name: "ex2", beforeSvcKB: 16_000, afterSvcKB: 460_000, cliSvcKB: 200_000)
        let ex3 = try makeRoundDir(name: "ex3", beforeSvcKB: 18_000, afterSvcKB: 440_000, cliSvcKB: 200_000)
        let ex4 = try makeRoundDir(name: "ex4", beforeSvcKB: 20_000, afterSvcKB: 420_000, cliSvcKB: 200_000)
        let ex5TooLate = try makeRoundDir(name: "ex5_ignored", beforeSvcKB: 100_000, afterSvcKB: 105_000, cliSvcKB: 102_000)
        let retryExhausted = try runRounds([ex1, ex2, ex3, ex4, ex5TooLate], maxRetries: 3)
        #expect(retryExhausted.exitCode != 0, "All 3 retries unstable MUST fail")
        #expect(!retryExhausted.stdout.contains("PASS"))
        #expect(!retryExhausted.stdout.contains("SKIPPED"))
        // Must contain before & after bytes for all 4 attempted rounds (initial + 3 retries)
        for expectedBytes in [
            14_000 * 1024, 480_000 * 1024,
            16_000 * 1024, 460_000 * 1024,
            18_000 * 1024, 440_000 * 1024,
            20_000 * 1024, 420_000 * 1024
        ] {
            #expect(retryExhausted.stderr.contains("\(expectedBytes)"), "Missing per-round reference value \(expectedBytes) in stderr: \(retryExhausted.stderr)")
        }
        let uptimeMentions = retryExhausted.stderr.lowercased().components(separatedBy: "load averages:").count - 1
        #expect(uptimeMentions >= 4, "Expected uptime load averages for each of the 4 unstable rounds, got \(uptimeMentions) in: \(retryExhausted.stderr)")
    }

    @Test("LR1 Orphan RSS & Dynamic Date: Verifies orphanRSSBytes with bracket + 25% width cap and checks m1-ledger.sh uses runtime date")
    func testLR1OrphanRSSBytesBracketWidthCapAndDynamicLedgerDate() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let refScriptURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1_ledger_ref.py")
        let ledgerShURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1-ledger.sh")
        let fm = FileManager.default

        // Item 3: m1-ledger.sh must NOT hardcode "Date: 2026-11-15", and must wire live resampling with max-retries=3
        let shSource = try String(contentsOf: ledgerShURL, encoding: .utf8)
        #expect(!shSource.contains("Date: 2026-11-15"), "m1-ledger.sh must use runtime date instead of hardcoded 2026-11-15")
        #expect(shSource.contains("date +%Y-%m-%d"))
        #expect(shSource.contains("\"--live-capture\""))
        #expect(shSource.contains("\"--max-retries\", \"3\""))

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LaunchLensLR1OrphanCap-\(UUID().uuidString)")
        let userAgentsDir = tempRoot.appendingPathComponent("UserAgents")
        let globalAgentsDir = tempRoot.appendingPathComponent("GlobalAgents")
        let systemDaemonsDir = tempRoot.appendingPathComponent("SystemDaemons")
        try fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: globalAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: systemDaemonsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.test.svc</string>
            <key>ProgramArguments</key>
            <array>
                <string>/opt/example/bin/test-svc</string>
            </array>
        </dict>
        </plist>
        """.utf8).write(to: userAgentsDir.appendingPathComponent("io.test.svc.plist"))

        let lctlText = "PID\tStatus\tLabel\n1000\t0\tio.test.svc\n"
        let lsofText = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        test-svc   1000 dev    8u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:18080 (LISTEN)
        node       2001 dev   10u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19001 (LISTEN)
        python3    2002 dev   11u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19002 (LISTEN)
        node       2003 dev   12u   IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:19003 (LISTEN)
        """

        func runOrphanCase(
            name: String,
            beforeNodeKB: Int64,
            afterNodeKB: Int64,
            afterNodeChildKB: Int64 = 0,
            pyKB: Int64 = 10_000,
            cliNodeKB: Int64,
            cliPyKB: Int64 = 10_000,
            cliOrphanTotalKB: Int64
        ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let cDir = tempRoot.appendingPathComponent(name)
            let bDir = cDir.appendingPathComponent("before")
            let aDir = cDir.appendingPathComponent("after")
            try fm.createDirectory(at: bDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
            try Data(lctlText.utf8).write(to: bDir.appendingPathComponent("launchctl-list.txt"))
            try Data(lctlText.utf8).write(to: aDir.appendingPathComponent("launchctl-list.txt"))
            try Data(lsofText.utf8).write(to: bDir.appendingPathComponent("lsof-listen.txt"))
            try Data(lsofText.utf8).write(to: aDir.appendingPathComponent("lsof-listen.txt"))

            let beforePS = """
              PID  PPID   UID    RSS ARGS
                1     0     0  15000 /sbin/launchd
              499     1     0   2000 /usr/bin/login
              500   499   501   3000 -zsh
             1000     1   501  80000 /opt/example/bin/test-svc
             2001     1   501  \(beforeNodeKB) /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
             2002     1   501  \(pyKB) /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
             2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
            """
            var afterPS = """
              PID  PPID   UID    RSS ARGS
                1     0     0  15000 /sbin/launchd
              499     1     0   2000 /usr/bin/login
              500   499   501   3000 -zsh
             1000     1   501  80000 /opt/example/bin/test-svc
             2001     1   501  \(afterNodeKB) /opt/homebrew/bin/node /tmp/m1_orphan_node_probe.js
             2002     1   501  \(pyKB) /opt/homebrew/bin/python3 /tmp/m1_orphan_py_probe.py
             2003   500   501  16000 /opt/homebrew/bin/node /tmp/node_modules/.bin/live_parent_worker.js
            """
            if afterNodeChildKB > 0 {
                afterPS += "\n 2099  2001   501  \(afterNodeChildKB) /opt/homebrew/bin/node /tmp/m1_orphan_node_child.js\n"
            }
            try Data(beforePS.utf8).write(to: bDir.appendingPathComponent("ps-axo.txt"))
            try Data(afterPS.utf8).write(to: aDir.appendingPathComponent("ps-axo.txt"))

            let cliPath = cDir.appendingPathComponent("cli.json")
            let svcBytes: Int64 = 80_000 * 1024
            let orphanBytes: Int64 = cliOrphanTotalKB * 1024
            try Data("""
            {
              "orphanRSSBytes": \(orphanBytes),
              "totalBackgroundRSSBytes": \(svcBytes + orphanBytes),
              "services": [
                {
                  "domain": "User LaunchAgent",
                  "isAppleSystem": false,
                  "label": "io.test.svc",
                  "listeningPorts": [18080],
                  "pid": 1000,
                  "rssBytes": \(svcBytes)
                }
              ],
              "orphans": [
                {
                  "domain": "Orphaned Process",
                  "isAppleSystem": false,
                  "label": "node (m1_orphan_node_probe.js)",
                  "listeningPorts": [19001],
                  "pid": 2001,
                  "rssBytes": \(cliNodeKB * 1024)
                },
                {
                  "domain": "Orphaned Process",
                  "isAppleSystem": false,
                  "label": "python3 (m1_orphan_py_probe.py)",
                  "listeningPorts": [19002],
                  "pid": 2002,
                  "rssBytes": \(cliPyKB * 1024)
                }
              ]
            }
            """.utf8).write(to: cliPath)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [
                refScriptURL.path,
                "--before-dir", bDir.path,
                "--after-dir", aDir.path,
                "--cli-json", cliPath.path,
                "--user-agents-dir", userAgentsDir.path,
                "--global-agents-dir", globalAgentsDir.path,
                "--system-daemons-dir", systemDaemonsDir.path,
                "--current-uid", "501",
                "--node-pid", "2001", "--node-port", "19001",
                "--py-pid", "2002", "--py-port", "19002",
                "--live-child-pid", "2003", "--live-child-ppid", "500", "--live-child-port", "19003"
            ]
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
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // 1. orphanRSSBytes > 5% outside stable orphan bracket (before=48,000 KB, after=50,400 KB, cli=60,000 KB -> +19.05%) MUST fail
        let badOrphanDiff = try runOrphanCase(
            name: "orphan_gt5pct",
            beforeNodeKB: 38_000,
            afterNodeKB: 40_400,
            cliNodeKB: 50_000,
            cliOrphanTotalKB: 60_000
        )
        #expect(badOrphanDiff.exitCode != 0, "orphanRSSBytes exceeding 5% of reference bracket MUST fail")
        #expect(badOrphanDiff.stderr.contains("orphanRSSBytes"))
        #expect(badOrphanDiff.stderr.contains("exceeded 5%"))
        #expect(badOrphanDiff.stderr.lowercased().contains("load averages:"))

        // 2. orphanRSSBytes wide bracket > 25% (before=48,000 KB, after=240,000 KB via child, cli=140,000 KB in middle) MUST fail
        let wideOrphanBracket = try runOrphanCase(
            name: "orphan_wide_gt25pct",
            beforeNodeKB: 38_000,
            afterNodeKB: 38_000,
            afterNodeChildKB: 192_000,
            cliNodeKB: 130_000,
            cliOrphanTotalKB: 140_000
        )
        #expect(wideOrphanBracket.exitCode != 0, "Unstable >25% orphanRSSBytes bracket with middle CLI value MUST fail")
        #expect(wideOrphanBracket.stderr.contains("orphanRSSBytes"))
        #expect(wideOrphanBracket.stderr.contains("\(48_000 * 1024)"))
        #expect(wideOrphanBracket.stderr.contains("\(240_000 * 1024)"))
        #expect(wideOrphanBracket.stderr.lowercased().contains("load averages:"))

        // 3. Stable 10% orphanRSSBytes bracket (before=50,000 KB, after=55,000 KB via child 5,000 KB, cli=52,500 KB inside) MUST pass
        let okOrphanBracket = try runOrphanCase(
            name: "orphan_ok_10pct",
            beforeNodeKB: 40_000,
            afterNodeKB: 40_000,
            afterNodeChildKB: 5_000,
            cliNodeKB: 42_500,
            cliOrphanTotalKB: 52_500
        )
        #expect(okOrphanBracket.exitCode == 0, "Stable 10% orphanRSSBytes bracket should pass, stderr: \(okOrphanBracket.stderr)")
        #expect(okOrphanBracket.stdout.contains("[M1 Row 1 PASS]"))
    }
}
