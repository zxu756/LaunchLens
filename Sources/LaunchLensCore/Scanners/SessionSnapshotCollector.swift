import Darwin
import Foundation

public struct HostCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol HostCommandExecuting: Sendable {
    func runCommand(executablePath: String, arguments: [String]) -> HostCommandResult
}

public struct SystemHostCommandExecutor: HostCommandExecuting {
    public init() {}

    public func runCommand(executablePath: String, arguments: [String]) -> HostCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return HostCommandResult(
                exitCode: 127,
                stdout: "",
                stderr: "Executable not found or not executable: \(executablePath)"
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return HostCommandResult(
                exitCode: 127,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        proc.waitUntilExit()

        let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
        let stderr = (String(data: errBox.data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HostCommandResult(
            exitCode: proc.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

public enum SnapshotCaptureError: LocalizedError, Equatable, Sendable {
    case commandFailed(executablePath: String, arguments: [String], exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(executablePath, arguments, exitCode, stderr):
            let cmd = ([executablePath] + arguments).joined(separator: " ")
            if stderr.isEmpty {
                return "Command failed with exit code \(exitCode): \(cmd)"
            }
            return "Command failed with exit code \(exitCode): \(cmd) (\(stderr))"
        }
    }
}

public struct RichProcessRow: Equatable, Sendable {
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var rssKB: Int64
    public var etime: String
    public var etimeSeconds: Int
    public var lstart: String
    public var command: String

    public init(
        pid: Int,
        ppid: Int,
        uid: Int,
        rssKB: Int64,
        etime: String,
        etimeSeconds: Int,
        lstart: String,
        command: String
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.rssKB = rssKB
        self.etime = etime
        self.etimeSeconds = max(0, etimeSeconds)
        self.lstart = lstart
        self.command = command
    }
}

public struct RawListeningEndpoint: Equatable, Sendable {
    public var pid: Int
    public var commandName: String
    public var protocolName: String
    public var bindAddress: String
    public var port: Int

    public init(
        pid: Int,
        commandName: String = "",
        protocolName: String,
        bindAddress: String,
        port: Int
    ) {
        self.pid = pid
        self.commandName = commandName
        self.protocolName = protocolName
        self.bindAddress = bindAddress
        self.port = port
    }
}

public struct LaunchctlPrintServiceInfo: Equatable, Sendable {
    public var plistPath: String?
    public var program: String?
    public var arguments: [String]?
    public var state: String?

    public init(
        plistPath: String? = nil,
        program: String? = nil,
        arguments: [String]? = nil,
        state: String? = nil
    ) {
        self.plistPath = plistPath
        self.program = program
        self.arguments = arguments
        self.state = state
    }
}

public extension LaunchScanner {

    // MARK: - Path Canonicalization & Redaction Entrypoints

    static func canonicalizePath(_ rawPath: String) -> String {
        SnapshotPathCanonicalizer.canonicalizePath(rawPath)
    }

    static func canonicalizePlistPath(_ rawPath: String?) -> String? {
        SnapshotPathCanonicalizer.canonicalizePlistPath(rawPath)
    }

    static func redactSensitiveArguments(_ command: String) -> String {
        CommandArgumentRedactor.redactCommandLine(command)
    }

    // MARK: - Rich M2 Output Parsers

    /// Parses macOS `ps` elapsed time `[[dd-]hh:]mm:ss` into seconds.
    static func parseEtimeSeconds(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var days = 0
        let timePortion: Substring
        if let dashIdx = trimmed.firstIndex(of: "-") {
            let daySlice = trimmed[..<dashIdx]
            guard let parsedDays = Int(daySlice), parsedDays >= 0 else { return 0 }
            days = parsedDays
            timePortion = trimmed[trimmed.index(after: dashIdx)...]
        } else {
            timePortion = Substring(trimmed)
        }

        let parts = timePortion.split(separator: ":", omittingEmptySubsequences: false)
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return 0 }

        switch nums.count {
        case 3:
            return days * 86_400 + nums[0] * 3_600 + nums[1] * 60 + nums[2]
        case 2:
            return days * 86_400 + nums[0] * 60 + nums[1]
        case 1:
            return days * 86_400 + nums[0]
        default:
            return 0
        }
    }

    /// Parses `/bin/ps -axo pid,ppid,uid,rss,etime,lstart,args`.
    static func parseRichPSOutput(_ output: String) -> [Int: RichProcessRow] {
        var rows: [Int: RichProcessRow] = [:]
        output.enumerateLines { line, _ in
            guard let row = parseRichPSLine(line) else { return }
            rows[row.pid] = row
        }
        return rows
    }

    private static func parseRichPSLine(_ line: String) -> RichProcessRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("PID") {
            return nil
        }

        // Expected 10 leading tokens:
        // 0:pid, 1:ppid, 2:uid, 3:rss, 4:etime, 5..9:lstart (Dow Mon Day HH:MM:SS YYYY), remainder:args
        var cursor = trimmed.startIndex
        var tokens: [String] = []
        tokens.reserveCapacity(10)

        for _ in 0..<10 {
            while cursor < trimmed.endIndex && (trimmed[cursor] == " " || trimmed[cursor] == "\t") {
                cursor = trimmed.index(after: cursor)
            }
            guard cursor < trimmed.endIndex else { return nil }
            let start = cursor
            while cursor < trimmed.endIndex && trimmed[cursor] != " " && trimmed[cursor] != "\t" {
                cursor = trimmed.index(after: cursor)
            }
            tokens.append(String(trimmed[start..<cursor]))
        }

        while cursor < trimmed.endIndex && (trimmed[cursor] == " " || trimmed[cursor] == "\t") {
            cursor = trimmed.index(after: cursor)
        }
        guard cursor < trimmed.endIndex else { return nil }

        guard let pid = Int(tokens[0]),
              let ppid = Int(tokens[1]),
              let uid = Int(tokens[2]),
              let rssKB = Int64(tokens[3]),
              tokens[9].count == 4,
              Int(tokens[9]) != nil else {
            return nil
        }

        let etime = tokens[4]
        let lstart = tokens[5...9].joined(separator: " ")
        let command = String(trimmed[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        return RichProcessRow(
            pid: pid,
            ppid: ppid,
            uid: uid,
            rssKB: rssKB,
            etime: etime,
            etimeSeconds: parseEtimeSeconds(etime),
            lstart: lstart,
            command: command
        )
    }

    /// Parses `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcnPt` (as well as `-F pn` and tabular `lsof -nP -iTCP -sTCP:LISTEN`).
    static func parseLsofListeningEndpoints(_ output: String) -> [RawListeningEndpoint] {
        struct DedupKey: Hashable {
            let pid: Int
            let proto: String
            let addr: String
            let port: Int
        }

        var endpoints: [RawListeningEndpoint] = []
        var seen: Set<DedupKey> = []

        var currentPID: Int?
        var currentCmd = ""
        var currentIPType: String?
        var sawTabularHeader = false

        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return }

            if trimmed.hasPrefix("COMMAND ") || trimmed.hasPrefix("COMMAND\t") {
                sawTabularHeader = true
                return
            }

            if !sawTabularHeader, let tag = trimmed.first {
                let body = String(trimmed.dropFirst())
                switch tag {
                case "p":
                    if let pid = Int(body) {
                        currentPID = pid
                        currentCmd = ""
                        currentIPType = nil
                        return
                    }
                case "c":
                    if currentPID != nil {
                        currentCmd = body
                        return
                    }
                case "f":
                    if currentPID != nil {
                        currentIPType = nil
                        return
                    }
                case "t":
                    if currentPID != nil {
                        currentIPType = body
                        return
                    }
                case "P":
                    if currentPID != nil {
                        return
                    }
                case "n":
                    if let pid = currentPID, !body.contains(" ") {
                        guard !body.contains("->"),
                              let (addr, port) = splitEndpointAddressAndPort(body) else {
                            return
                        }
                        let proto = normalizeTCPProtocolLabel(ipType: currentIPType, bindAddress: addr)
                        let key = DedupKey(pid: pid, proto: proto, addr: addr, port: port)
                        if seen.insert(key).inserted {
                            endpoints.append(
                                RawListeningEndpoint(
                                    pid: pid,
                                    commandName: currentCmd,
                                    protocolName: proto,
                                    bindAddress: addr,
                                    port: port
                                )
                            )
                        }
                        return
                    }
                default:
                    if currentPID != nil && !trimmed.contains(" ") {
                        return
                    }
                }
            }

            // Tabular fallback: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(LISTEN)]
            let cols = trimmed.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 8, let pid = Int(cols[1]) else { return }
            let cmdName = cols[0]
            let ipType = cols[4]
            let endpointToken: String
            if cols.last == "(LISTEN)", cols.count >= 9 {
                endpointToken = cols[cols.count - 2]
            } else {
                endpointToken = cols[cols.count - 1]
            }
            guard !endpointToken.contains("->"),
                  let (addr, port) = splitEndpointAddressAndPort(endpointToken) else {
                return
            }
            let proto = normalizeTCPProtocolLabel(ipType: ipType, bindAddress: addr)
            let key = DedupKey(pid: pid, proto: proto, addr: addr, port: port)
            if seen.insert(key).inserted {
                endpoints.append(
                    RawListeningEndpoint(
                        pid: pid,
                        commandName: cmdName,
                        protocolName: proto,
                        bindAddress: addr,
                        port: port
                    )
                )
            }
        }

        return endpoints
    }

    /// Parses `/bin/launchctl print gui/<uid>/<label>` output to extract external `.plist` path, program, arguments, and state.
    static func parseLaunchctlPrintService(_ output: String) -> LaunchctlPrintServiceInfo {
        var plistPath: String?
        var program: String?
        var state: String?
        var arguments: [String]?

        var braceDepth = 0
        var inArgumentsBlock = false
        var argCollector: [String] = []

        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            if inArgumentsBlock {
                if trimmed == "}" || trimmed.hasPrefix("}") {
                    inArgumentsBlock = false
                    arguments = argCollector
                    braceDepth = max(0, braceDepth - 1)
                } else {
                    argCollector.append(trimmed)
                }
                return
            }

            if braceDepth <= 1 {
                if trimmed == "arguments = {" {
                    inArgumentsBlock = true
                    argCollector = []
                    braceDepth += 1
                    return
                }
                if plistPath == nil, trimmed.hasPrefix("path = ") {
                    plistPath = String(trimmed.dropFirst("path = ".count)).trimmingCharacters(in: .whitespaces)
                } else if program == nil, trimmed.hasPrefix("program = ") {
                    program = String(trimmed.dropFirst("program = ".count)).trimmingCharacters(in: .whitespaces)
                } else if state == nil, trimmed.hasPrefix("state = ") {
                    state = String(trimmed.dropFirst("state = ".count)).trimmingCharacters(in: .whitespaces)
                }
            }

            if trimmed.hasSuffix("{") {
                braceDepth += 1
            } else if trimmed == "}" || trimmed.hasPrefix("}") {
                braceDepth = max(0, braceDepth - 1)
            }
        }

        return LaunchctlPrintServiceInfo(
            plistPath: plistPath,
            program: program,
            arguments: arguments,
            state: state
        )
    }

    // MARK: - Live / Mocked Session Snapshot Capture

    static func captureSessionSnapshot(
        plistDirectories: [(URL, ServiceDomain)]? = nil,
        userLaunchAgentsDirectory: URL? = nil,
        currentUID: Int = Int(getuid()),
        capturedAt: Date = Date(),
        hostInfo: SnapshotHostInfo? = nil,
        executor: any HostCommandExecuting = SystemHostCommandExecutor()
    ) throws -> SessionSnapshot {
        let fm = FileManager.default
        let resolvedDirectories: [(URL, ServiceDomain)] = plistDirectories ?? {
            let userDir = userLaunchAgentsDirectory
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            return [
                (userDir, .userAgent),
                (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
                (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon)
            ]
        }()

        // 1. Read `.plist` definitions from standard directories.
        var standardPlistItems: [(meta: PlistMetadata, sha256: String?)] = []
        var standardLabels: Set<String> = []

        for (dir, domain) in resolvedDirectories {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension.lowercased() == "plist" {
                guard var meta = readPlistMetadata(at: url, domain: domain) else { continue }
                meta.plistPath = canonicalizePath(url.path)
                let sha256 = (try? Data(contentsOf: url)).map(FreezeLedgerStore.sha256Hex)
                standardPlistItems.append((meta, sha256))
                standardLabels.insert(meta.label)
            }
        }

        // 2. Capture `launchctl list` (must exit 0).
        let lctlArgs = ["list"]
        let lctlRes = executor.runCommand(executablePath: "/bin/launchctl", arguments: lctlArgs)
        guard lctlRes.exitCode == 0 else {
            throw SnapshotCaptureError.commandFailed(
                executablePath: "/bin/launchctl",
                arguments: lctlArgs,
                exitCode: lctlRes.exitCode,
                stderr: lctlRes.stderr
            )
        }
        let launchctlMap = parseLaunchctlList(lctlRes.stdout)

        // 3. Probe `launchctl print gui/<uid>/<label>` for non-Apple, non-application.* labels outside the standard directories.
        var externalServices: [(entry: SnapshotServiceEntry, meta: PlistMetadata)] = []
        for label in launchctlMap.keys.sorted() {
            if standardLabels.contains(label) || isEphemeralOrAppleLaunchdLabel(label) {
                continue
            }
            let printArgs = ["print", "gui/\(currentUID)/\(label)"]
            let printRes = executor.runCommand(executablePath: "/bin/launchctl", arguments: printArgs)
            if printRes.exitCode == 113 {
                // Transient job unloaded between `launchctl list` and `launchctl print`
                continue
            }
            guard printRes.exitCode == 0 else {
                throw SnapshotCaptureError.commandFailed(
                    executablePath: "/bin/launchctl",
                    arguments: printArgs,
                    exitCode: printRes.exitCode,
                    stderr: printRes.stderr
                )
            }

            let info = parseLaunchctlPrintService(printRes.stdout)
            // D4: Exclude `(submitted by ...)` and non-`.plist` dynamic handles.
            guard let canonicalPlist = canonicalizePlistPath(info.plistPath) else {
                continue
            }

            let lctlEntry = launchctlMap[label]
            let fileURL = URL(fileURLWithPath: canonicalPlist)
            if var diskMeta = readPlistMetadata(at: fileURL, domain: .userAgent) {
                diskMeta.label = label
                diskMeta.plistPath = canonicalPlist
                let sha256 = (try? Data(contentsOf: fileURL)).map(FreezeLedgerStore.sha256Hex)
                let redactedCmd = redactedServiceCommand(from: diskMeta)
                let svc = SnapshotServiceEntry(
                    domainScope: .user,
                    label: label,
                    plistPath: canonicalPlist,
                    isExternalPlist: true,
                    plistSHA256: sha256,
                    programCommand: redactedCmd,
                    runAtLoad: diskMeta.runAtLoad,
                    keepAlive: diskMeta.keepAlive,
                    pid: lctlEntry?.pid,
                    lastExitStatus: lctlEntry?.lastExitStatus
                )
                externalServices.append((svc, diskMeta))
            } else {
                let rawArgs = info.arguments?.filter { !$0.isEmpty }
                let rawCommand: String = {
                    if let rawArgs, !rawArgs.isEmpty {
                        return rawArgs.joined(separator: " ")
                    }
                    if let prog = info.program, !prog.isEmpty {
                        return prog
                    }
                    return label
                }()
                let redactedCmd: String = {
                    if let rawArgs, !rawArgs.isEmpty {
                        return CommandArgumentRedactor.redactArgumentTokens(rawArgs).joined(separator: " ")
                    }
                    return redactSensitiveArguments(rawCommand)
                }()
                let syntheticMeta = PlistMetadata(
                    label: label,
                    plistPath: canonicalPlist,
                    domain: .userAgent,
                    programCommand: rawCommand,
                    programArguments: rawArgs,
                    runAtLoad: false,
                    keepAlive: false
                )
                let svc = SnapshotServiceEntry(
                    domainScope: .user,
                    label: label,
                    plistPath: canonicalPlist,
                    isExternalPlist: true,
                    plistSHA256: nil,
                    programCommand: redactedCmd,
                    runAtLoad: false,
                    keepAlive: false,
                    pid: lctlEntry?.pid,
                    lastExitStatus: lctlEntry?.lastExitStatus
                )
                externalServices.append((svc, syntheticMeta))
            }
        }

        // 4. Capture rich `ps` process table (`etime` + `lstart`, must exit 0).
        let psArgs = ["-axo", "pid,ppid,uid,rss,etime,lstart,args"]
        let psRes = executor.runCommand(executablePath: "/bin/ps", arguments: psArgs)
        guard psRes.exitCode == 0 else {
            throw SnapshotCaptureError.commandFailed(
                executablePath: "/bin/ps",
                arguments: psArgs,
                exitCode: psRes.exitCode,
                stderr: psRes.stderr
            )
        }
        let processes = parseRichPSOutput(psRes.stdout)

        // 5. Capture `lsof` TCP LISTEN endpoints (must exit 0).
        let lsofArgs = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPt"]
        let lsofRes = executor.runCommand(executablePath: "/usr/sbin/lsof", arguments: lsofArgs)
        guard lsofRes.exitCode == 0 else {
            throw SnapshotCaptureError.commandFailed(
                executablePath: "/usr/sbin/lsof",
                arguments: lsofArgs,
                exitCode: lsofRes.exitCode,
                stderr: lsofRes.stderr
            )
        }
        let rawEndpoints = parseLsofListeningEndpoints(lsofRes.stdout)

        return correlateSessionSnapshot(
            standardPlists: standardPlistItems,
            externalServices: externalServices,
            launchctlMap: launchctlMap,
            processes: processes,
            rawEndpoints: rawEndpoints,
            currentUID: currentUID,
            capturedAt: capturedAt,
            hostInfo: hostInfo ?? SnapshotHostInfo.current(uid: currentUID)
        )
    }

    // MARK: - Deterministic Snapshot Correlation

    internal static func correlateSessionSnapshot(
        standardPlists: [(meta: PlistMetadata, sha256: String?)],
        externalServices: [(entry: SnapshotServiceEntry, meta: PlistMetadata)],
        launchctlMap: [String: LaunchctlEntry],
        processes: [Int: RichProcessRow],
        rawEndpoints: [RawListeningEndpoint],
        currentUID: Int,
        capturedAt: Date,
        hostInfo: SnapshotHostInfo
    ) -> SessionSnapshot {
        var childrenByPPID: [Int: [Int]] = [:]
        var redactedCommands: [Int: String] = [:]
        var parsedProcesses: [Int: ParsedInvocation] = [:]

        for proc in processes.values {
            if proc.pid > 0 && proc.pid != proc.ppid {
                childrenByPPID[proc.ppid, default: []].append(proc.pid)
            }
            let redacted = redactSensitiveArguments(proc.command)
            redactedCommands[proc.pid] = redacted
            parsedProcesses[proc.pid] = parseInvocation(command: redacted, explicitArguments: nil)
        }

        // 1. Claim process trees belonging to `launchctl list` entries and plist-backed daemons.
        var claimedByLaunchd: Set<Int> = []
        var serviceLabelByPID: [Int: String] = [:]

        for label in launchctlMap.keys.sorted() {
            guard let entry = launchctlMap[label], let rootPID = entry.pid, rootPID > 0 else { continue }
            let tree = collectProcessTreePIDs(roots: [rootPID], childrenByPPID: childrenByPPID)
            claimedByLaunchd.formUnion(tree)
            if !label.lowercased().hasPrefix("application.") {
                for mpid in tree where serviceLabelByPID[mpid] == nil {
                    serviceLabelByPID[mpid] = label
                }
            }
        }

        let allPlistMetas: [PlistMetadata] = standardPlists.map(\.meta) + externalServices.map(\.meta)
        let allPlistInvocations: [ParsedInvocation] = allPlistMetas.map { meta in
            let redactedCmd = redactSensitiveArguments(meta.programCommand)
            let redactedArgs = meta.programArguments.map(CommandArgumentRedactor.redactArgumentTokens)
            return parseInvocation(command: redactedCmd, explicitArguments: redactedArgs)
        }

        // Fallback PID lookup for plists not visible in unprivileged `launchctl list` (e.g. System LaunchDaemons).
        var fallbackPIDByLabel: [String: Int] = [:]
        for (idx, meta) in allPlistMetas.enumerated() where launchctlMap[meta.label] == nil {
            let metaInv = allPlistInvocations[idx]
            let candidates = processes.values
                .filter { proc in
                    guard !claimedByLaunchd.contains(proc.pid) else { return false }
                    if meta.domain == .userAgent && proc.uid != currentUID {
                        return false
                    }
                    guard let procInv = parsedProcesses[proc.pid] else { return false }
                    return doesProcessMatchPlistInvocation(procInv: procInv, plistInv: metaInv)
                }
                .map(\.pid)

            if !candidates.isEmpty {
                let candidateSet = Set(candidates)
                let minimalRoots = candidates
                    .filter { pid in
                        guard let ppid = processes[pid]?.ppid else { return true }
                        return !candidateSet.contains(ppid)
                    }
                    .sorted()
                let roots = minimalRoots.isEmpty ? [candidates.min()!] : minimalRoots
                fallbackPIDByLabel[meta.label] = roots.first
                let tree = collectProcessTreePIDs(roots: Set(roots), childrenByPPID: childrenByPPID)
                claimedByLaunchd.formUnion(tree)
                for mpid in tree where serviceLabelByPID[mpid] == nil {
                    serviceLabelByPID[mpid] = meta.label
                }
            }
        }

        // 2. Assemble non-Apple services (standard directories + external `launchctl print` `.plist`s).
        var serviceEntries: [SnapshotServiceEntry] = []
        for (meta, sha256) in standardPlists {
            guard !meta.label.lowercased().hasPrefix("com.apple."),
                  let scope = SnapshotServiceDomain(serviceDomain: meta.domain) else {
                continue
            }
            let lctl = launchctlMap[meta.label]
            let resolvedPID = lctl?.pid ?? fallbackPIDByLabel[meta.label]
            serviceEntries.append(
                SnapshotServiceEntry(
                    domainScope: scope,
                    label: meta.label,
                    plistPath: meta.plistPath,
                    isExternalPlist: false,
                    plistSHA256: sha256,
                    programCommand: redactedServiceCommand(from: meta),
                    runAtLoad: meta.runAtLoad,
                    keepAlive: meta.keepAlive,
                    pid: resolvedPID,
                    lastExitStatus: lctl?.lastExitStatus
                )
            )
        }
        for (extEntry, _) in externalServices where !extEntry.label.lowercased().hasPrefix("com.apple.") {
            serviceEntries.append(extEntry)
        }

        // 3. Assemble current-user TCP LISTEN endpoints merged by `(port, invocationIdentity)` (D5).
        struct CandidateListenerRecord {
            var endpoint: RawListeningEndpoint
            var process: RichProcessRow
            var canonicalExe: String
            var invocationIdentity: String
            var redactedCommand: String
            var serviceLabel: String?
            var isOrphan: Bool
        }

        var portsByPID: [Int: Set<Int>] = [:]
        for ep in rawEndpoints {
            portsByPID[ep.pid, default: []].insert(ep.port)
        }

        var candidateListeners: [CandidateListenerRecord] = []
        var includedListenerPIDs: Set<Int> = []

        for ep in rawEndpoints {
            guard let proc = processes[ep.pid],
                  proc.uid == currentUID,
                  let procInv = parsedProcesses[ep.pid] else {
                continue
            }
            if isAppleSystemOrGenuineAppBundle(executablePath: procInv.executablePath) {
                continue
            }
            let svcLabel = serviceLabelByPID[ep.pid]
            if let svcLabel, svcLabel.lowercased().hasPrefix("com.apple.") {
                continue
            }

            let isOrphan = isProcessUnclaimedOrphanOrDescendant(
                pid: ep.pid,
                processes: processes,
                parsedProcesses: parsedProcesses,
                claimedByLaunchd: claimedByLaunchd,
                activePlistInvocations: allPlistInvocations,
                currentUID: currentUID
            )

            let invId = invocationIdentity(for: procInv)
            let canonicalExe = canonicalizePath(procInv.normalizedExecutablePath)
            let redactedCmd = redactedCommands[ep.pid] ?? redactSensitiveArguments(proc.command)

            includedListenerPIDs.insert(ep.pid)
            candidateListeners.append(
                CandidateListenerRecord(
                    endpoint: ep,
                    process: proc,
                    canonicalExe: canonicalExe,
                    invocationIdentity: invId,
                    redactedCommand: redactedCmd,
                    serviceLabel: svcLabel,
                    isOrphan: isOrphan
                )
            )
        }

        var groupedListeners: [String: [CandidateListenerRecord]] = [:]
        for cand in candidateListeners {
            let key = "\(cand.endpoint.port)::\(cand.invocationIdentity)"
            groupedListeners[key, default: []].append(cand)
        }

        var listenerEntries: [SnapshotListenerEntry] = []
        for group in groupedListeners.values {
            let sortedGroup = group.sorted { a, b in
                if a.process.pid != b.process.pid { return a.process.pid < b.process.pid }
                if a.endpoint.protocolName != b.endpoint.protocolName {
                    return a.endpoint.protocolName < b.endpoint.protocolName
                }
                return a.endpoint.bindAddress < b.endpoint.bindAddress
            }
            guard let primary = sortedGroup.first else { continue }
            let protocols = Array(Set(sortedGroup.map(\.endpoint.protocolName))).sorted()
            let bindAddresses = Array(Set(sortedGroup.map(\.endpoint.bindAddress))).sorted()
            let anyOrphan = sortedGroup.contains(where: \.isOrphan)

            listenerEntries.append(
                SnapshotListenerEntry(
                    port: primary.endpoint.port,
                    protocols: protocols,
                    bindAddresses: bindAddresses,
                    pid: primary.process.pid,
                    ppid: primary.process.ppid,
                    uid: primary.process.uid,
                    lstart: primary.process.lstart,
                    etimeSeconds: primary.process.etimeSeconds,
                    executable: primary.canonicalExe,
                    invocationIdentity: primary.invocationIdentity,
                    programCommand: primary.redactedCommand,
                    serviceLabel: primary.serviceLabel,
                    isOrphan: anyOrphan
                )
            )
        }

        // 4. Assemble non-listening orphans using exact M1 rules + D1 listener deduplication.
        var claimedOrphanPIDs = claimedByLaunchd
        var orphanEntries: [SnapshotOrphanEntry] = []

        for proc in processes.values.sorted(by: { $0.pid < $1.pid }) {
            guard proc.uid == currentUID,
                  proc.ppid == 1,
                  !claimedOrphanPIDs.contains(proc.pid),
                  let procInv = parsedProcesses[proc.pid] else {
                continue
            }

            if isAppleSystemOrGenuineAppBundle(executablePath: procInv.executablePath) {
                continue
            }

            if allPlistInvocations.contains(where: { doesProcessMatchPlistInvocation(procInv: procInv, plistInv: $0) }) {
                continue
            }

            let treePIDs = collectProcessTreePIDs(roots: [proc.pid], childrenByPPID: childrenByPPID)
            var totalRSSKB: Int64 = 0
            var treePortSet: Set<Int> = []
            for mpid in treePIDs {
                if let row = processes[mpid] {
                    totalRSSKB += max(0, row.rssKB)
                }
                if let pts = portsByPID[mpid] {
                    treePortSet.formUnion(pts)
                }
            }

            guard qualifiesAsOrphanDaemon(procInv: procInv, listeningPorts: treePortSet.sorted()) else {
                continue
            }

            claimedOrphanPIDs.formUnion(treePIDs)

            // D1: Any process (or orphan tree) with listening ports is represented strictly in `listeners` (`isOrphan: true`).
            if includedListenerPIDs.contains(proc.pid) || !treePIDs.isDisjoint(with: includedListenerPIDs) {
                continue
            }

            orphanEntries.append(
                SnapshotOrphanEntry(
                    pid: proc.pid,
                    ppid: proc.ppid,
                    uid: proc.uid,
                    lstart: proc.lstart,
                    etimeSeconds: proc.etimeSeconds,
                    executable: canonicalizePath(procInv.normalizedExecutablePath),
                    invocationIdentity: invocationIdentity(for: procInv),
                    programCommand: redactedCommands[proc.pid] ?? redactSensitiveArguments(proc.command),
                    rssBytes: totalRSSKB * 1024
                )
            )
        }

        return SessionSnapshot(
            capturedAt: capturedAt,
            host: hostInfo,
            services: serviceEntries,
            listeners: listenerEntries,
            orphans: orphanEntries
        )
    }

    // MARK: - Internal Helpers

    private static func redactedServiceCommand(from meta: PlistMetadata) -> String {
        if let args = meta.programArguments, !args.isEmpty {
            return CommandArgumentRedactor.redactArgumentTokens(args).joined(separator: " ")
        }
        return redactSensitiveArguments(meta.programCommand)
    }

    internal static func invocationIdentity(for inv: ParsedInvocation) -> String {
        let canonicalExe = canonicalizePath(inv.normalizedExecutablePath)
        switch inv.target {
        case .none:
            return canonicalExe
        case .scriptPath(let normalizedPath, _):
            return "\(canonicalExe)::script:\(canonicalizePath(normalizedPath))"
        case .module(let mod):
            return "\(canonicalExe)::module:\(mod)"
        case .jarPath(let normalizedPath, _):
            return "\(canonicalExe)::jar:\(canonicalizePath(normalizedPath))"
        case .packageCommand(let pkg):
            return "\(canonicalExe)::pkg:\(pkg)"
        case .inlineCode(let snippet):
            return "\(canonicalExe)::inline:\(redactSensitiveArguments(snippet))"
        }
    }

    private static func isEphemeralOrAppleLaunchdLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.hasPrefix("com.apple.")
            || lower.hasPrefix("application.")
            || lower.hasPrefix("0x")
    }

    private static func isProcessUnclaimedOrphanOrDescendant(
        pid: Int,
        processes: [Int: RichProcessRow],
        parsedProcesses: [Int: ParsedInvocation],
        claimedByLaunchd: Set<Int>,
        activePlistInvocations: [ParsedInvocation],
        currentUID: Int
    ) -> Bool {
        var visited: Set<Int> = []
        var cursor = pid

        while cursor > 1, visited.insert(cursor).inserted {
            if claimedByLaunchd.contains(cursor) {
                return false
            }
            guard let row = processes[cursor], row.uid == currentUID else {
                return false
            }
            if let inv = parsedProcesses[cursor] {
                if isAppleSystemOrGenuineAppBundle(executablePath: inv.executablePath) {
                    return false
                }
                if activePlistInvocations.contains(where: { doesProcessMatchPlistInvocation(procInv: inv, plistInv: $0) }) {
                    return false
                }
            }
            if row.ppid == 1 {
                return true
            }
            cursor = row.ppid
        }
        return false
    }

    private static func splitEndpointAddressAndPort(_ endpoint: String) -> (String, Int)? {
        guard let colonIdx = endpoint.lastIndex(of: ":") else { return nil }
        let addrSlice = endpoint[..<colonIdx]
        let portSlice = endpoint[endpoint.index(after: colonIdx)...]
        guard !addrSlice.isEmpty,
              !portSlice.isEmpty,
              portSlice.allSatisfy(\.isNumber),
              let port = Int(portSlice),
              port > 0 else {
            return nil
        }
        return (String(addrSlice), port)
    }

    private static func normalizeTCPProtocolLabel(ipType: String?, bindAddress: String) -> String {
        if let ipType {
            let upper = ipType.uppercased()
            if upper.contains("IPV4") || upper == "4" {
                return "TCP4"
            }
            if upper.contains("IPV6") || upper == "6" {
                return "TCP6"
            }
        }
        if bindAddress.hasPrefix("[") {
            return "TCP6"
        }
        if bindAddress == "*" {
            return "TCP"
        }
        return "TCP4"
    }
}
