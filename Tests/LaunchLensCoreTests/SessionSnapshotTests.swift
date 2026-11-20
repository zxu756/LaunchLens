import Foundation
import Testing
@testable import LaunchLensCore

private struct FakeHostCommandExecutor: HostCommandExecuting {
    typealias Handler = @Sendable (String, [String]) -> HostCommandResult
    let handler: Handler

    func runCommand(executablePath: String, arguments: [String]) -> HostCommandResult {
        handler(executablePath, arguments)
    }
}

private enum SnapshotTestFixtures {
    static let defaultHost = SnapshotHostInfo(
        hostname: "dev-mac.local",
        osVersion: "macOS 15.1",
        architecture: "arm64",
        uid: 501
    )

    static let t0 = Date(timeIntervalSince1970: 1_763_700_000)
    static let t1 = Date(timeIntervalSince1970: 1_763_700_060)

    static func makeTempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchlens-m2-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func writePlist(
        in dir: URL,
        filename: String,
        label: String,
        programArguments: [String],
        runAtLoad: Bool = true,
        keepAlive: Bool = false
    ) throws -> URL {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": runAtLoad,
            "KeepAlive": keepAlive
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }
}

@Suite("SessionSnapshotTests", .timeLimit(.minutes(1)))
struct SessionSnapshotTests {

    @Test("M2 Row 1a: Service restart with changed PID or exit status produces zero diff")
    func testServiceRestartWithChangedPIDProducesZeroDiff() throws {
        let tmp = try SnapshotTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let userAgents = tmp.appendingPathComponent("UserAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: userAgents, withIntermediateDirectories: true)
        _ = try SnapshotTestFixtures.writePlist(
            in: userAgents,
            filename: "io.example.sync-agent.plist",
            label: "io.example.sync-agent",
            programArguments: ["/opt/example/bin/sync-agent", "--daemon"],
            runAtLoad: true,
            keepAlive: true
        )
        _ = try SnapshotTestFixtures.writePlist(
            in: userAgents,
            filename: "io.example.periodic.plist",
            label: "io.example.periodic",
            programArguments: ["/opt/example/bin/periodic-worker"],
            runAtLoad: false,
            keepAlive: false
        )

        let psBefore = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:10:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
         1010     1   501  24576       10:00 Sat Nov 21 09:00:00 2026 /opt/example/bin/sync-agent --daemon
        """
        let psAfter = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:11:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
         2940     1   501  25600       00:12 Sat Nov 21 09:10:48 2026 /opt/example/bin/sync-agent --daemon
         3100     1   501  12288       00:04 Sat Nov 21 09:10:56 2026 /opt/example/bin/periodic-worker
        """
        let lsofMinimal = """
        p1
        claunchd
        tIPv4
        PTCP
        n127.0.0.1:49152
        """

        let execBefore = FakeHostCommandExecutor { exe, args in
            switch (exe, args.first) {
            case ("/bin/launchctl", "list"):
                return HostCommandResult(
                    exitCode: 0,
                    stdout: "PID\tStatus\tLabel\n1010\t0\tio.example.sync-agent\n-\t0\tio.example.periodic\n"
                )
            case ("/bin/ps", _):
                return HostCommandResult(exitCode: 0, stdout: psBefore)
            case ("/usr/sbin/lsof", _):
                return HostCommandResult(exitCode: 0, stdout: lsofMinimal)
            default:
                return HostCommandResult(exitCode: 1, stderr: "Unexpected command \(exe) \(args)")
            }
        }

        let execAfter = FakeHostCommandExecutor { exe, args in
            switch (exe, args.first) {
            case ("/bin/launchctl", "list"):
                return HostCommandResult(
                    exitCode: 0,
                    stdout: "PID\tStatus\tLabel\n2940\t-9\tio.example.sync-agent\n3100\t0\tio.example.periodic\n"
                )
            case ("/bin/ps", _):
                return HostCommandResult(exitCode: 0, stdout: psAfter)
            case ("/usr/sbin/lsof", _):
                return HostCommandResult(exitCode: 0, stdout: lsofMinimal)
            default:
                return HostCommandResult(exitCode: 1, stderr: "Unexpected command \(exe) \(args)")
            }
        }

        let before = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [(userAgents, .userAgent)],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: execBefore
        )
        let after = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [(userAgents, .userAgent)],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t1,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: execAfter
        )

        #expect(before.services.count == 2)
        #expect(after.services.count == 2)
        #expect(before.services.first(where: { $0.label == "io.example.sync-agent" })?.pid == 1010)
        #expect(after.services.first(where: { $0.label == "io.example.sync-agent" })?.pid == 2940)

        let diff = SessionSnapshotDiffer.diff(before: before, after: after)
        #expect(diff.hasChanges == false)
        #expect(diff.hasAdditions == false)
        #expect(diff.hasModifications == false)
        #expect(diff.services.added.isEmpty)
        #expect(diff.services.removed.isEmpty)
        #expect(diff.services.modified.isEmpty)
    }

    @Test("M2 Row 1b: Same service key changing plist content is modified while changed plist path is reported as removed and added")
    func testServiceSameKeyModifiedContentVsChangedPlistPathReportedAsRemovedAndAdded() throws {
        // Half 1: Identical (domainScope, label, canonicalPlistPath) with changed sha256/program -> modified
        let beforeContentSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.mutable",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.mutable.plist",
            plistSHA256: "1111aaaa",
            programCommand: "/opt/example/bin/mutable --v1",
            runAtLoad: true,
            keepAlive: false,
            pid: 1200
        )
        let afterContentSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.mutable",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.mutable.plist",
            plistSHA256: "2222bbbb",
            programCommand: "/opt/example/bin/mutable --v2",
            runAtLoad: true,
            keepAlive: false,
            pid: 1250
        )

        let contentBefore = SessionSnapshot(
            capturedAt: SnapshotTestFixtures.t0,
            host: SnapshotTestFixtures.defaultHost,
            services: [beforeContentSvc],
            listeners: [],
            orphans: []
        )
        let contentAfter = SessionSnapshot(
            capturedAt: SnapshotTestFixtures.t1,
            host: SnapshotTestFixtures.defaultHost,
            services: [afterContentSvc],
            listeners: [],
            orphans: []
        )

        let contentDiff = SessionSnapshotDiffer.diff(before: contentBefore, after: contentAfter)
        #expect(contentDiff.hasChanges == true)
        #expect(contentDiff.hasModifications == true)
        #expect(contentDiff.hasAdditions == false)
        #expect(contentDiff.services.added.isEmpty)
        #expect(contentDiff.services.removed.isEmpty)
        try #require(contentDiff.services.modified.count == 1)
        #expect(contentDiff.services.modified[0].after.label == "io.example.mutable")
        #expect(contentDiff.services.modified[0].reasons.contains(.plistContentChanged))
        #expect(contentDiff.services.modified[0].reasons.contains(.programChanged))

        // Half 2: Same (domainScope, label) but changed plistPath -> distinct identity keys (-1 old, +1 new, 0 modified)
        let beforeRelocatedSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.relocated",
            plistPath: "/Users/devuser/Library/LaunchAgents/io.example.relocated.plist",
            plistSHA256: "cccc3333",
            programCommand: "/opt/example/bin/relocated",
            runAtLoad: true,
            keepAlive: false
        )
        let afterRelocatedSvc = SnapshotServiceEntry(
            domainScope: .user,
            label: "io.example.relocated",
            plistPath: "/private/var/folders/xx/yy/T/io.example.relocated.plist",
            isExternalPlist: true,
            plistSHA256: "cccc3333",
            programCommand: "/opt/example/bin/relocated",
            runAtLoad: true,
            keepAlive: false
        )

        let relocatedBefore = SessionSnapshot(
            capturedAt: SnapshotTestFixtures.t0,
            host: SnapshotTestFixtures.defaultHost,
            services: [beforeRelocatedSvc],
            listeners: [],
            orphans: []
        )
        let relocatedAfter = SessionSnapshot(
            capturedAt: SnapshotTestFixtures.t1,
            host: SnapshotTestFixtures.defaultHost,
            services: [afterRelocatedSvc],
            listeners: [],
            orphans: []
        )

        let relocatedDiff = SessionSnapshotDiffer.diff(before: relocatedBefore, after: relocatedAfter)
        #expect(relocatedDiff.hasChanges == true)
        #expect(relocatedDiff.hasAdditions == true)
        #expect(relocatedDiff.hasModifications == false)
        #expect(relocatedDiff.services.modified.isEmpty)
        #expect(relocatedDiff.summary.servicesModified == 0)
        #expect(relocatedDiff.summary.servicesRemoved == 1)
        #expect(relocatedDiff.summary.servicesAdded == 1)
        try #require(relocatedDiff.services.removed.count == 1)
        try #require(relocatedDiff.services.added.count == 1)
        #expect(relocatedDiff.services.removed[0].plistPath == "/Users/devuser/Library/LaunchAgents/io.example.relocated.plist")
        #expect(relocatedDiff.services.added[0].plistPath == "/private/var/folders/xx/yy/T/io.example.relocated.plist")
    }

    @Test("M2 Row 1c: PID reuse with identical executable and different lstart reports removed old orphan and added new orphan")
    func testPIDReuseDifferentLstartReportsRemovedAndAddedOrphan() throws {
        let pythonCmd = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python /opt/example/workspace/worker.py"
        let psBefore = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        42100     1   501  36864       15:00 Sat Nov 21 09:00:01 2026 \(pythonCmd)
        """
        let psAfter = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:16:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        42100     1   501  38912       00:18 Sat Nov 21 09:15:42 2026 \(pythonCmd)
        """
        let lsofOut = "p1\ncrapportd\ntIPv4\nPTCP\nn*:49152\n"

        func makeExec(ps: String) -> FakeHostCommandExecutor {
            FakeHostCommandExecutor { exe, args in
                switch (exe, args.first) {
                case ("/bin/launchctl", "list"):
                    return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                case ("/bin/ps", _):
                    return HostCommandResult(exitCode: 0, stdout: ps)
                case ("/usr/sbin/lsof", _):
                    return HostCommandResult(exitCode: 0, stdout: lsofOut)
                default:
                    return HostCommandResult(exitCode: 1, stderr: "Unexpected \(exe)")
                }
            }
        }

        let before = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: makeExec(ps: psBefore)
        )
        let after = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t1,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: makeExec(ps: psAfter)
        )

        try #require(before.orphans.count == 1)
        try #require(after.orphans.count == 1)
        #expect(before.orphans[0].pid == 42100)
        #expect(after.orphans[0].pid == 42100)

        let diff = SessionSnapshotDiffer.diff(before: before, after: after)
        try #require(diff.orphans.removed.count == 1)
        try #require(diff.orphans.added.count == 1)
        #expect(diff.orphans.removed[0].lstart == "Sat Nov 21 09:00:01 2026")
        #expect(diff.orphans.added[0].lstart == "Sat Nov 21 09:15:42 2026")
    }

    @Test("M2 Row 1d (D5): Dual-stack IPv4 and IPv6 sockets on the same port merge into a single listener entry")
    func testDualStackIPv4AndIPv6SamePortMergedIntoSingleListener() throws {
        let psBefore = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        """
        let psAfter = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:01:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        48210   900   501  65536       00:08 Sat Nov 21 09:20:00 2026 /opt/homebrew/bin/node /opt/example/workspace/mcp_server.js --port 9222
        """
        let lsofBefore = "p1\nclaunchd\ntIPv4\nPTCP\nn*:49152\n"
        let lsofAfter = """
        p1
        claunchd
        tIPv4
        PTCP
        n*:49152
        p48210
        cnode
        f19
        tIPv4
        PTCP
        n127.0.0.1:9222
        f20
        tIPv6
        PTCP
        n[::1]:9222
        """

        let before = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: FakeHostCommandExecutor { exe, _ in
                switch exe {
                case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psBefore)
                case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofBefore)
                default: return HostCommandResult(exitCode: 1)
                }
            }
        )
        let after = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t1,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: FakeHostCommandExecutor { exe, _ in
                switch exe {
                case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psAfter)
                case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofAfter)
                default: return HostCommandResult(exitCode: 1)
                }
            }
        )

        try #require(after.listeners.count == 1)
        #expect(after.listeners[0].port == 9222)
        #expect(after.listeners[0].protocols == ["TCP4", "TCP6"])
        #expect(after.listeners[0].bindAddresses == ["127.0.0.1", "[::1]"])
        #expect(after.listeners[0].isOrphan == false)

        let diff = SessionSnapshotDiffer.diff(before: before, after: after)
        #expect(diff.listeners.added.count == 1)
        #expect(diff.listeners.removed.isEmpty)

        // Listener restart on same port + same script target -> 0 diff
        var restarted = after
        restarted.listeners[0].pid = 49999
        restarted.listeners[0].lstart = "Sat Nov 21 09:25:00 2026"
        let restartDiff = SessionSnapshotDiffer.diff(before: after, after: restarted)
        #expect(restartDiff.hasChanges == false)
    }

    @Test("M2 Row 1e (D1): Detached PPID==1 listener is marked isOrphan in listeners and excluded from orphans")
    func testListeningOrphanReportedOnceOnlyInListeners() throws {
        let psBefore = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        """
        let psAfter = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:01:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        67866     1   501   4096       00:02 Sat Nov 21 09:30:43 2026 /bin/sleep 300
        67871     1   501  28672       00:02 Sat Nov 21 09:30:43 2026 /usr/bin/python3 /opt/example/workspace/detached_orphan.py
        67876     1   501  32768       00:02 Sat Nov 21 09:30:43 2026 /usr/bin/python3 -m http.server 51505 --bind 127.0.0.1
        """
        let lsofBefore = "p1\nclaunchd\ntIPv4\nPTCP\nn*:49152\n"
        let lsofAfter = """
        p1
        claunchd
        tIPv4
        PTCP
        n*:49152
        p67876
        cPython
        f3
        tIPv4
        PTCP
        n127.0.0.1:51505
        """
        let printExt = """
        gui/501/com.example.session.agent = {
            active count = 1
            path = /private/var/folders/xx/yy/T/agent/com.example.session.agent.plist
            type = LaunchAgent
            state = running
            program = /bin/sleep
            arguments = {
                /bin/sleep
                300
            }
        }
        """

        let before = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: FakeHostCommandExecutor { exe, _ in
                switch exe {
                case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psBefore)
                case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofBefore)
                default: return HostCommandResult(exitCode: 1)
                }
            }
        )

        let after = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t1,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: FakeHostCommandExecutor { exe, args in
                switch (exe, args.first) {
                case ("/bin/launchctl", "list"):
                    return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n67866\t0\tcom.example.session.agent\n")
                case ("/bin/launchctl", "print"):
                    return HostCommandResult(exitCode: 0, stdout: printExt)
                case ("/bin/ps", _):
                    return HostCommandResult(exitCode: 0, stdout: psAfter)
                case ("/usr/sbin/lsof", _):
                    return HostCommandResult(exitCode: 0, stdout: lsofAfter)
                default:
                    return HostCommandResult(exitCode: 1)
                }
            }
        )

        #expect(after.services.count == 1)
        try #require(after.listeners.count == 1)
        #expect(after.listeners[0].pid == 67876)
        #expect(after.listeners[0].port == 51505)
        #expect(after.listeners[0].isOrphan == true)
        #expect(after.orphans.map(\.pid) == [67871])

        let diff = SessionSnapshotDiffer.diff(before: before, after: after)
        #expect(diff.summary.servicesAdded == 1)
        #expect(diff.summary.listenersAdded == 1)
        #expect(diff.summary.orphansAdded == 1)
    }

    @Test("M2 Row 1f: Second orphan with identical executable and arguments is reported as +1 added")
    func testSecondOrphanWithIdenticalCommandAndExecutableReportedAsAdded() throws {
        let cmd = "/opt/homebrew/bin/node /opt/example/workspace/queue_worker.js --concurrency 2"
        let psBefore = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        51001     1   501  40960       05:00 Sat Nov 21 09:10:00 2026 \(cmd)
        """
        let psAfter = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:03:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        51001     1   501  40960       08:00 Sat Nov 21 09:10:00 2026 \(cmd)
        51099     1   501  41984       00:55 Sat Nov 21 09:12:05 2026 \(cmd)
        """
        let lsofOut = "p1\nclaunchd\ntIPv4\nPTCP\nn*:49152\n"

        func capture(ps: String, at date: Date) throws -> SessionSnapshot {
            try LaunchScanner.captureSessionSnapshot(
                plistDirectories: [],
                currentUID: 501,
                capturedAt: date,
                hostInfo: SnapshotTestFixtures.defaultHost,
                executor: FakeHostCommandExecutor { exe, _ in
                    switch exe {
                    case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                    case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: ps)
                    case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofOut)
                    default: return HostCommandResult(exitCode: 1)
                    }
                }
            )
        }

        let before = try capture(ps: psBefore, at: SnapshotTestFixtures.t0)
        let after = try capture(ps: psAfter, at: SnapshotTestFixtures.t1)
        let diff = SessionSnapshotDiffer.diff(before: before, after: after)

        #expect(diff.orphans.removed.isEmpty)
        #expect(diff.orphans.added.map(\.pid) == [51099])
    }

    @Test("M2 Row 1g: External directory bootstrapped plist is captured via launchctl print and canonicalizes /var to /private/var")
    func testExternalBootstrappedPlistCapturedAndVarPrivateVarCanonicalized() throws {
        let tmp = try SnapshotTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let extDir = tmp.appendingPathComponent("ext", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let extPlistURL = try SnapshotTestFixtures.writePlist(
            in: extDir,
            filename: "com.example.external.agent.plist",
            label: "com.example.external.agent",
            programArguments: ["/bin/sleep", "300"],
            runAtLoad: true,
            keepAlive: false
        )

        // Construct a /var/... alias path if under /private/var/... (and also test synthetic /var/folders/... path)
        let canonicalExtPath = LaunchScanner.canonicalizePath(extPlistURL.path)
        let varAliasPath: String = canonicalExtPath.hasPrefix("/private/var/")
            ? String(canonicalExtPath.dropFirst("/private".count))
            : "/var/folders/synthetic_unit/T/com.example.external.agent.plist"

        #expect(LaunchScanner.canonicalizePlistPath("/var/folders/ab/cd/T/test.plist") == "/private/var/folders/ab/cd/T/test.plist")
        #expect(LaunchScanner.canonicalizePlistPath("/private/var/folders/ab/cd/T/test.plist") == "/private/var/folders/ab/cd/T/test.plist")

        let psOut = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        77100     1   501   2048       00:05 Sat Nov 21 09:30:00 2026 /bin/sleep 300
        """
        let lsofOut = "p1\nclaunchd\ntIPv4\nPTCP\nn*:49152\n"

        func makeExec(reportedPath: String) -> FakeHostCommandExecutor {
            FakeHostCommandExecutor { exe, args in
                switch (exe, args.first) {
                case ("/bin/launchctl", "list"):
                    return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n77100\t0\tcom.example.external.agent\n")
                case ("/bin/launchctl", "print"):
                    #expect(args == ["print", "gui/501/com.example.external.agent"])
                    let out = """
                    gui/501/com.example.external.agent = {
                        active count = 1
                        path = \(reportedPath)
                        state = running
                        program = /bin/sleep
                    }
                    """
                    return HostCommandResult(exitCode: 0, stdout: out)
                case ("/bin/ps", _):
                    return HostCommandResult(exitCode: 0, stdout: psOut)
                case ("/usr/sbin/lsof", _):
                    return HostCommandResult(exitCode: 0, stdout: lsofOut)
                default:
                    return HostCommandResult(exitCode: 1)
                }
            }
        }

        let snapVar = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: makeExec(reportedPath: varAliasPath)
        )
        let snapPrivateVar = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t1,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: makeExec(reportedPath: LaunchScanner.canonicalizePath(varAliasPath))
        )

        try #require(snapVar.services.count == 1)
        #expect(snapVar.services[0].isExternalPlist == true)
        #expect(snapVar.services[0].plistPath.hasPrefix("/private/var/"))
        if canonicalExtPath.hasPrefix("/private/var/") {
            #expect(snapVar.services[0].plistSHA256 != nil)
            #expect(snapVar.services[0].runAtLoad == true)
        }

        let diff = SessionSnapshotDiffer.diff(before: snapVar, after: snapPrivateVar)
        #expect(diff.hasChanges == false)
    }

    @Test("M2 Row 1h (D4): Dynamic submitted items without a real .plist path are excluded from services")
    func testDynamicSubmittedItemsWithoutRealPlistExcluded() throws {
        let lctlList = """
        PID\tStatus\tLabel
        24100\t0\tcom.example.desktop.ShipIt
        -\t0\tcom.example.sparkle-updater
        512\t0\tcom.openssh.ssh-agent
        24200\t0\tcom.example.real-external
        31777\t0\tapplication.com.example.desktop-app.01
        564\t0\tcom.apple.Finder
        """
        let psOut = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        24100     1   501  16384       00:10 Sat Nov 21 09:30:00 2026 /opt/homebrew/bin/node /opt/updater/shipit.js
        24200     1   501   4096       00:10 Sat Nov 21 09:30:00 2026 /bin/sleep 120
        """
        let lsofOut = "p1\nclaunchd\ntIPv4\nPTCP\nn*:49152\n"

        let exec = FakeHostCommandExecutor { exe, args in
            switch (exe, args.first) {
            case ("/bin/launchctl", "list"):
                return HostCommandResult(exitCode: 0, stdout: lctlList)
            case ("/bin/launchctl", "print"):
                let target = args.count > 1 ? args[1] : ""
                if target.hasSuffix("com.example.desktop.ShipIt") {
                    return HostCommandResult(exitCode: 0, stdout: "gui/501/com.example.desktop.ShipIt = {\n\tpath = (submitted by DesktopApp[23991])\n\tstate = running\n}\n")
                }
                if target.hasSuffix("com.example.sparkle-updater") {
                    return HostCommandResult(exitCode: 0, stdout: "gui/501/com.example.sparkle-updater = {\n\tpath = (submitted by Updater[881])\n\tstate = waiting\n}\n")
                }
                if target.hasSuffix("com.openssh.ssh-agent") {
                    return HostCommandResult(exitCode: 0, stdout: "gui/501/com.openssh.ssh-agent = {\n\tpath = /private/var/run/com.openssh.ssh-agent.Listeners\n\tstate = waiting\n}\n")
                }
                if target.hasSuffix("com.example.real-external") {
                    return HostCommandResult(exitCode: 0, stdout: "gui/501/com.example.real-external = {\n\tpath = /private/var/folders/xx/yy/T/com.example.real-external.plist\n\tprogram = /bin/sleep\n\tstate = running\n}\n")
                }
                return HostCommandResult(exitCode: 1, stderr: "Should not probe \(target)")
            case ("/bin/ps", _):
                return HostCommandResult(exitCode: 0, stdout: psOut)
            case ("/usr/sbin/lsof", _):
                return HostCommandResult(exitCode: 0, stdout: lsofOut)
            default:
                return HostCommandResult(exitCode: 1)
            }
        }

        let snap = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: exec
        )

        #expect(snap.services.map(\.label) == ["com.example.real-external"])
        // PID 24100 is claimed by launchctl list entry ShipIt, so it must NOT leak into orphans either
        #expect(snap.orphans.isEmpty)
    }

    @Test("M2 Row 1i & Row 5: Capture throws SnapshotCaptureError when launchctl, ps, or lsof fails")
    func testCaptureThrowsOnAnyExternalCommandFailure() {
        let validLctl = "PID\tStatus\tLabel\n8001\t0\tcom.example.ext\n"
        let validPS = "  PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS\n    1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd\n"
        let validLsof = "p1\nclaunchd\ntIPv4\nPTCP\nn*:49152\n"

        // 1. launchctl list fails
        #expect(throws: SnapshotCaptureError.self) {
            _ = try LaunchScanner.captureSessionSnapshot(
                plistDirectories: [],
                currentUID: 501,
                executor: FakeHostCommandExecutor { exe, _ in
                    if exe == "/bin/launchctl" { return HostCommandResult(exitCode: 1, stderr: "launchctl failed") }
                    return HostCommandResult(exitCode: 0, stdout: validPS)
                }
            )
        }

        // 2. ps fails
        #expect(throws: SnapshotCaptureError.self) {
            _ = try LaunchScanner.captureSessionSnapshot(
                plistDirectories: [],
                currentUID: 501,
                executor: FakeHostCommandExecutor { exe, _ in
                    if exe == "/bin/launchctl" { return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n") }
                    if exe == "/bin/ps" { return HostCommandResult(exitCode: 1, stderr: "ps denied") }
                    return HostCommandResult(exitCode: 0, stdout: validLsof)
                }
            )
        }

        // 3. lsof fails
        #expect(throws: SnapshotCaptureError.self) {
            _ = try LaunchScanner.captureSessionSnapshot(
                plistDirectories: [],
                currentUID: 501,
                executor: FakeHostCommandExecutor { exe, _ in
                    if exe == "/bin/launchctl" { return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n") }
                    if exe == "/bin/ps" { return HostCommandResult(exitCode: 0, stdout: validPS) }
                    return HostCommandResult(exitCode: 1, stderr: "lsof failed")
                }
            )
        }

        // 4. launchctl print fails with unexpected error (e.g. exitCode 1)
        #expect(throws: SnapshotCaptureError.self) {
            _ = try LaunchScanner.captureSessionSnapshot(
                plistDirectories: [],
                currentUID: 501,
                executor: FakeHostCommandExecutor { exe, args in
                    if exe == "/bin/launchctl" && args.first == "list" {
                        return HostCommandResult(exitCode: 0, stdout: validLctl)
                    }
                    if exe == "/bin/launchctl" && args.first == "print" {
                        return HostCommandResult(exitCode: 1, stderr: "permission error")
                    }
                    if exe == "/bin/ps" { return HostCommandResult(exitCode: 0, stdout: validPS) }
                    return HostCommandResult(exitCode: 0, stdout: validLsof)
                }
            )
        }
    }

    @Test("M2 Item 4 & Row 6: Redacts sensitive flag values, ENV=value tokens, and Authorization headers at capture time")
    func testSensitiveArgumentsAndAuthorizationHeadersRedactedAtCaptureTime() throws {
        let tmp = try SnapshotTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let agentsDir = tmp.appendingPathComponent("Agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        _ = try SnapshotTestFixtures.writePlist(
            in: agentsDir,
            filename: "io.example.secret-svc.plist",
            label: "io.example.secret-svc",
            programArguments: [
                "/opt/example/bin/secret-svc",
                "--api-key=svc_secret_alpha_111",
                "--password",
                "svc_secret_beta_222"
            ]
        )

        let psOut = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
        61001     1   501  32768       00:15 Sat Nov 21 09:30:00 2026 env API_KEY=env_secret_gamma_333 GITHUB_TOKEN=ghp_delta_444 /usr/bin/python3 /opt/example/workspace/auth_worker.py --token=tok_epsilon_555 --secret sec_zeta_666 --passwd=pw_eta_777 --auth auth_theta_888 --port 8080 -p 9090
        61002   900   501  40960       00:10 Sat Nov 21 09:30:05 2026 /opt/homebrew/bin/node /opt/example/workspace/token_proxy.js -H Authorization: Bearer jwt_iota_999_secret --header="Authorization: Basic dXNlcjpzZWNyZXRfMTAwMA=="
        """
        let lsofOut = """
        p61002
        cnode
        tIPv4
        PTCP
        n127.0.0.1:18080
        """

        let snapshot = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [(agentsDir, .userAgent)],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: FakeHostCommandExecutor { exe, _ in
                switch exe {
                case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psOut)
                case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofOut)
                default: return HostCommandResult(exitCode: 1)
                }
            }
        )

        let directRedacted = LaunchScanner.redactSensitiveArguments(
            "python3 /opt/example/auth_worker.py --token=tok_direct_000 API_KEY=key_direct_001 -H \"Authorization: Bearer jwt_direct_002\""
        )
        #expect(!directRedacted.contains("tok_direct_000"))
        #expect(!directRedacted.contains("key_direct_001"))
        #expect(!directRedacted.contains("jwt_direct_002"))
        #expect(directRedacted.contains("auth_worker.py"))
        #expect(directRedacted.contains("***"))

        let jsonData = try SessionSnapshot.encodePrettyJSON(snapshot)
        let jsonText = String(decoding: jsonData, as: UTF8.self)

        let forbiddenSecrets = [
            "svc_secret_alpha_111",
            "svc_secret_beta_222",
            "env_secret_gamma_333",
            "ghp_delta_444",
            "tok_epsilon_555",
            "sec_zeta_666",
            "pw_eta_777",
            "auth_theta_888",
            "jwt_iota_999_secret",
            "dXNlcjpzZWNyZXRfMTAwMA=="
        ]
        for secret in forbiddenSecrets {
            #expect(!jsonText.contains(secret), "Leaked secret \(secret) in snapshot JSON")
        }

        // Non-sensitive script paths and port flags must remain intact
        #expect(jsonText.contains("auth_worker.py"))
        #expect(jsonText.contains("token_proxy.js"))
        #expect(jsonText.contains("--port 8080"))
        #expect(jsonText.contains("-p 9090"))
        #expect(jsonText.contains("***"))
    }

    @Test("M2 Row 1j & Row 4: Diff output is deterministically sorted and byte-identical across repeated runs; validates schemaVersion")
    func testDeterministicOrderingAndByteIdenticalRepeatedDiff() throws {
        let s1 = SnapshotServiceEntry(domainScope: .system, label: "com.vendor.z", plistPath: "/Library/LaunchDaemons/com.vendor.z.plist", programCommand: "/opt/z")
        let s2 = SnapshotServiceEntry(domainScope: .user, label: "com.vendor.a", plistPath: "/Users/devuser/Library/LaunchAgents/com.vendor.a.plist", programCommand: "/opt/a")
        let l1 = SnapshotListenerEntry(port: 9090, protocols: ["TCP4"], bindAddresses: ["127.0.0.1"], pid: 200, ppid: 1, uid: 501, lstart: "Sat Nov 21 09:00:00 2026", executable: "/opt/b", invocationIdentity: "/opt/b", programCommand: "/opt/b", isOrphan: true)
        let l2 = SnapshotListenerEntry(port: 8080, protocols: ["TCP4"], bindAddresses: ["127.0.0.1"], pid: 100, ppid: 1, uid: 501, lstart: "Sat Nov 21 09:00:00 2026", executable: "/opt/a", invocationIdentity: "/opt/a", programCommand: "/opt/a", isOrphan: true)
        let o1 = SnapshotOrphanEntry(pid: 900, uid: 501, lstart: "Sat Nov 21 09:00:00 2026", executable: "/opt/o2", invocationIdentity: "/opt/o2", programCommand: "/opt/o2")
        let o2 = SnapshotOrphanEntry(pid: 300, uid: 501, lstart: "Sat Nov 21 09:00:00 2026", executable: "/opt/o1", invocationIdentity: "/opt/o1", programCommand: "/opt/o1")

        let empty = SessionSnapshot(capturedAt: SnapshotTestFixtures.t0, host: SnapshotTestFixtures.defaultHost, services: [], listeners: [], orphans: [])
        let snapOrderA = SessionSnapshot(capturedAt: SnapshotTestFixtures.t1, host: SnapshotTestFixtures.defaultHost, services: [s1, s2], listeners: [l1, l2], orphans: [o1, o2])
        let snapOrderB = SessionSnapshot(capturedAt: SnapshotTestFixtures.t1, host: SnapshotTestFixtures.defaultHost, services: [s2, s1], listeners: [l2, l1], orphans: [o2, o1])

        let diff1 = SessionSnapshotDiffer.diff(before: empty, after: snapOrderA)
        let diff2 = SessionSnapshotDiffer.diff(before: empty, after: snapOrderB)
        #expect(diff1 == diff2)
        #expect(diff1.services.added.map(\.label) == ["com.vendor.a", "com.vendor.z"])
        #expect(diff1.listeners.added.map(\.port) == [8080, 9090])
        #expect(diff1.orphans.added.map(\.pid) == [300, 900])

        let bytes1 = try SessionSnapshotDiffer.encodePrettyJSON(diff1)
        let bytes2 = try SessionSnapshotDiffer.encodePrettyJSON(diff2)
        #expect(bytes1 == bytes2)

        // Schema version validation check
        let badSnap = SessionSnapshot(schemaVersion: 99, capturedAt: SnapshotTestFixtures.t0, host: SnapshotTestFixtures.defaultHost, services: [], listeners: [], orphans: [])
        let badBytes = try SessionSnapshot.encodePrettyJSON(badSnap)
        #expect(throws: SnapshotValidationError.self) {
            _ = try SessionSnapshot.decodeAndValidate(from: badBytes)
        }
    }

    @Test("M2 Orphan Rules: Preserves M1 UID, Apple, and genuine GUI .app exclusions while keeping Python.app and Ruby.app")
    func testM1OrphanFilteringRulesPreservedInSessionSnapshot() throws {
        let psOut = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
            1     0     0  19104    05:00:00 Sat Nov 21 04:00:00 2026 /sbin/launchd
         9101     1   501  48000       01:00 Sat Nov 21 09:20:00 2026 /opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python /opt/example/workspace/orphan_worker.py
         9102     1   501  32000       01:00 Sat Nov 21 09:20:00 2026 /opt/homebrew/Cellar/ruby/3.3.5/Frameworks/Ruby.framework/Versions/3.3/Resources/Ruby.app/Contents/MacOS/ruby /opt/example/workspace/orphan_job.rb
         9201     1   501 250000       10:00 Sat Nov 21 09:10:00 2026 /Applications/Slack.app/Contents/MacOS/Slack
         9202     1   501 180000       10:00 Sat Nov 21 09:10:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex --app-server
         9203     1   502  64000       10:00 Sat Nov 21 09:10:00 2026 /opt/homebrew/bin/node /opt/example/workspace/other_uid.js
         9204     1   501  40000       10:00 Sat Nov 21 09:10:00 2026 /usr/libexec/rapportd
        """
        let lsofOut = """
        p9202
        ccodex
        tIPv4
        PTCP
        n127.0.0.1:49152
        p9204
        crapportd
        tIPv4
        PTCP
        n*:49153
        """

        let snap = try LaunchScanner.captureSessionSnapshot(
            plistDirectories: [],
            currentUID: 501,
            capturedAt: SnapshotTestFixtures.t0,
            hostInfo: SnapshotTestFixtures.defaultHost,
            executor: FakeHostCommandExecutor { exe, _ in
                switch exe {
                case "/bin/launchctl": return HostCommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n")
                case "/bin/ps": return HostCommandResult(exitCode: 0, stdout: psOut)
                case "/usr/sbin/lsof": return HostCommandResult(exitCode: 0, stdout: lsofOut)
                default: return HostCommandResult(exitCode: 1)
                }
            }
        )

        #expect(snap.listeners.isEmpty)
        #expect(snap.orphans.map(\.pid) == [9101, 9102])
    }

    @Test("M2 Parsers & Edge Cases: Parses single-digit lstart day, dd-hh:mm:ss etime, tabular/F lsof, nested launchctl print, and multi-word plist secrets")
    func testRichParsersAndMultiWordPlistSecretRedaction() throws {
        #expect(LaunchScanner.parseEtimeSeconds("00:05") == 5)
        #expect(LaunchScanner.parseEtimeSeconds("02:03:04") == 7384)
        #expect(LaunchScanner.parseEtimeSeconds("2-01:00:00") == 176_400)

        let psSample = """
          PID  PPID   UID    RSS     ELAPSED STARTED                      ARGS
         7701     1   501  20480  2-01:00:00 Sat Nov  7 09:02:39 2026 /opt/homebrew/bin/node /opt/work/server.js --port 7000
        """
        let psRows = LaunchScanner.parseRichPSOutput(psSample)
        try #require(psRows[7701] != nil)
        #expect(psRows[7701]?.lstart == "Sat Nov 7 09:02:39 2026")
        #expect(psRows[7701]?.etimeSeconds == 176_400)

        let lsofTabularAndConnected = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node       7701 dev    19u  IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:7000 (LISTEN)
        node       7701 dev    20u  IPv6 0x1000000000000000      0t0  TCP [::1]:7000 (LISTEN)
        node       7701 dev    21u  IPv4 0x1000000000000000      0t0  TCP 127.0.0.1:7000->127.0.0.1:59001
        """
        let endpoints = LaunchScanner.parseLsofListeningEndpoints(lsofTabularAndConnected)
        #expect(endpoints.count == 2)
        #expect(endpoints.map(\.protocolName) == ["TCP4", "TCP6"])

        let nestedPrint = """
        gui/501/com.example.nested = {
            active count = 1
            path = /var/folders/aa/bb/T/com.example.nested.plist
            state = running
            program = /opt/bin/nested
            arguments = {
                /opt/bin/nested
                --secret=multi word secret alpha
                --password
                multi word secret beta
            }
            endpoints = {
                path = /var/run/nested.sock
                state = bound
            }
        }
        """
        let parsedPrint = LaunchScanner.parseLaunchctlPrintService(nestedPrint)
        #expect(parsedPrint.plistPath == "/var/folders/aa/bb/T/com.example.nested.plist")
        #expect(parsedPrint.state == "running")
        #expect(parsedPrint.arguments?.count == 4)

        let redactedTokens = CommandArgumentRedactor.redactArgumentTokens(parsedPrint.arguments ?? [])
        let joined = redactedTokens.joined(separator: " ")
        #expect(!joined.contains("alpha"))
        #expect(!joined.contains("beta"))
        #expect(joined == "/opt/bin/nested --secret=*** --password ***")
    }
}
