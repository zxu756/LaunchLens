import Foundation

public struct ProcessRow: Equatable, Sendable {
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var rssKB: Int64
    public var cpuPercent: Double
    public var command: String

    public init(pid: Int, ppid: Int, uid: Int, rssKB: Int64, cpuPercent: Double, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.rssKB = rssKB
        self.cpuPercent = cpuPercent
        self.command = command
    }
}

public struct LaunchctlEntry: Equatable, Sendable {
    public var pid: Int?
    public var lastExitStatus: Int?
    public var label: String

    public init(pid: Int?, lastExitStatus: Int?, label: String) {
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.label = label
    }
}

public struct PlistMetadata: Equatable, Sendable {
    public var label: String
    public var plistPath: String
    public var domain: ServiceDomain
    public var programCommand: String
    public var programArguments: [String]?
    public var runAtLoad: Bool
    public var keepAlive: Bool

    public init(
        label: String,
        plistPath: String,
        domain: ServiceDomain,
        programCommand: String,
        programArguments: [String]? = nil,
        runAtLoad: Bool,
        keepAlive: Bool
    ) {
        self.label = label
        self.plistPath = plistPath
        self.domain = domain
        self.programCommand = programCommand
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
    }
}

public enum LaunchScanner {

    // Exact executable basenames for standalone native developer / AI agent daemons (never matched by substring).
    private static let exactDevDaemonBasenames: Set<String> = [
        "codex", "claude", "opencode", "opencode-cli", "vibe",
        "ollama", "llama-server", "whisper-server", "playwright",
        "chromium", "chromedriver", "geckodriver", "workerd",
        "uvicorn", "gunicorn", "celery", "jupyter", "jupyter-lab",
        "jupyter-notebook", "streamlit", "gradio", "vite", "esbuild",
        "webpack", "next-server", "mcp-proxy", "fastmcp",
        "ngrok", "cloudflared", "redis-server", "postgres", "mysqld",
        "mariadbd", "mongod", "caddy"
    ]

    private static let cliFrameworkInterpreterBundles: Set<String> = [
        "python.app", "python3.app", "ruby.app"
    ]

    private static let genericScriptFilenames: Set<String> = [
        "index.js", "index.mjs", "index.cjs", "index.ts",
        "cli.js", "cli.mjs", "cli.cjs", "main.js", "main.py",
        "server.js", "server.py", "__main__.py", "app.py", "app.js"
    ]

    private enum RuntimeFamily: String, Equatable, Sendable {
        case python
        case node
        case deno
        case bun
        case uv
        case ruby
        case perl
        case java
    }

    private enum RuntimeKind: Equatable, Sendable {
        case nativeBinary
        case scriptingRuntime(RuntimeFamily)
        case shell
    }

    private enum InvocationTarget: Equatable, Sendable {
        case none
        case scriptPath(normalizedPath: String, displayName: String)
        case module(String)
        case jarPath(normalizedPath: String, displayName: String)
        case packageCommand(String)
        case inlineCode(String)

        var identityKey: String? {
            switch self {
            case .none:
                return nil
            case .scriptPath(let normalizedPath, _):
                return "script:\(normalizedPath)"
            case .module(let mod):
                return "module:\(mod)"
            case .jarPath(let normalizedPath, _):
                return "jar:\(normalizedPath)"
            case .packageCommand(let pkg):
                return "pkg:\(pkg)"
            case .inlineCode(let snippet):
                return "inline:\(snippet)"
            }
        }

        var displayLabel: String? {
            switch self {
            case .none:
                return nil
            case .scriptPath(_, let displayName):
                return displayName
            case .module(let mod):
                return "-m \(mod)"
            case .jarPath(_, let displayName):
                return displayName
            case .packageCommand(let pkg):
                return pkg
            case .inlineCode:
                return "-c"
            }
        }
    }

    private struct ParsedInvocation: Equatable, Sendable {
        var executablePath: String
        var normalizedExecutablePath: String
        var executableBasename: String
        var displayExecutable: String
        var rawArguments: [String]
        var runtimeKind: RuntimeKind
        var target: InvocationTarget
        var shellRunsDevOrScriptTarget: Bool
    }

    // MARK: - Deterministic Output Parsers

    public static func parseLaunchctlList(_ output: String) -> [String: LaunchctlEntry] {
        var map: [String: LaunchctlEntry] = [:]
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("PID") { return }
            let cols = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard cols.count >= 3 else { return }
            let pid = cols[0] == "-" ? nil : Int(cols[0])
            let status = cols[1] == "-" ? nil : Int(cols[1])
            let label = cols.dropFirst(2).joined(separator: " ")
            map[label] = LaunchctlEntry(pid: pid, lastExitStatus: status, label: label)
        }
        return map
    }

    /// Parses both `ps -axo pid,ppid,uid,rss,pcpu,args` (6-column) and `ps -axo pid,ppid,uid,rss,args` (5-column).
    public static func parsePSOutput(_ output: String) -> [Int: ProcessRow] {
        var rows: [Int: ProcessRow] = [:]
        var headerHasCPU: Bool?

        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return }
            if trimmed.hasPrefix("PID") {
                let upper = trimmed.uppercased()
                headerHasCPU = upper.contains("%CPU") || upper.contains("PCPU")
                return
            }

            let expectsCPU: Bool
            if let headerHasCPU {
                expectsCPU = headerHasCPU
            } else {
                let probe = trimmed.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                expectsCPU = probe.count == 6 && isStrictDecimalToken(String(probe[4]))
            }

            if expectsCPU {
                let parts = trimmed.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 6,
                      let pid = Int(parts[0]),
                      let ppid = Int(parts[1]),
                      let uid = Int(parts[2]),
                      let rssKB = Int64(parts[3]) else { return }
                let cpu = Double(parts[4]) ?? 0.0
                let cmd = String(parts[5])
                rows[pid] = ProcessRow(pid: pid, ppid: ppid, uid: uid, rssKB: rssKB, cpuPercent: cpu, command: cmd)
            } else {
                let parts = trimmed.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 5,
                      let pid = Int(parts[0]),
                      let ppid = Int(parts[1]),
                      let uid = Int(parts[2]),
                      let rssKB = Int64(parts[3]) else { return }
                let cmd = String(parts[4])
                rows[pid] = ProcessRow(pid: pid, ppid: ppid, uid: uid, rssKB: rssKB, cpuPercent: 0.0, command: cmd)
            }
        }
        return rows
    }

    /// Parses both `lsof -iTCP -sTCP:LISTEN -P -n -F pn` and standard tabular `lsof -nP -iTCP -sTCP:LISTEN`.
    public static func parseLsofPorts(_ output: String) -> [Int: [Int]] {
        var result: [Int: Set<Int>] = [:]
        var currentPID: Int?
        var sawTabularHeader = false

        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return }

            if trimmed.hasPrefix("COMMAND ") || trimmed.hasPrefix("COMMAND\t") {
                sawTabularHeader = true
                return
            }

            if !sawTabularHeader, let prefix = trimmed.first {
                let body = String(trimmed.dropFirst())
                if prefix == "p", let pid = Int(body) {
                    currentPID = pid
                    return
                } else if prefix == "n", let pid = currentPID, !body.contains(" ") {
                    if let port = extractPortFromEndpoint(body) {
                        result[pid, default: []].insert(port)
                    }
                    return
                }
            }

            // Tabular lsof row: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(LISTEN)]
            let cols = trimmed.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 8, let pid = Int(cols[1]) else { return }
            let endpointToken: String
            if cols.last == "(LISTEN)", cols.count >= 9 {
                endpointToken = cols[cols.count - 2]
            } else {
                endpointToken = cols[cols.count - 1]
            }
            if let port = extractPortFromEndpoint(endpointToken) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { Array($0).sorted() }
    }

    public static func readPlistMetadata(at url: URL, domain: ServiceDomain) -> PlistMetadata? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any] else { return nil }

        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let rawProg = (dict["Program"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawArgs = (dict["ProgramArguments"] as? [String])?.filter { !$0.isEmpty }

        let resolvedArgs: [String]? = {
            if let rawProg, !rawProg.isEmpty {
                if let rawArgs, !rawArgs.isEmpty {
                    return [rawProg] + Array(rawArgs.dropFirst())
                }
                return [rawProg]
            }
            if let rawArgs, !rawArgs.isEmpty {
                return rawArgs
            }
            return nil
        }()

        let program: String = {
            if let resolvedArgs, !resolvedArgs.isEmpty {
                return resolvedArgs.joined(separator: " ")
            }
            return label
        }()
        let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
        let keepAlive: Bool = {
            if let b = dict["KeepAlive"] as? Bool { return b }
            if let d = dict["KeepAlive"] as? [String: Any] { return !d.isEmpty }
            return false
        }()

        return PlistMetadata(
            label: label,
            plistPath: url.path,
            domain: domain,
            programCommand: program,
            programArguments: resolvedArgs,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive
        )
    }

    // MARK: - Process Tree Aggregation (L7)

    /// Computes `{roots} ∪ all transitive descendants via ppid`, deduplicated by PID and cycle-safe.
    public static func collectProcessTreePIDs(
        roots: Set<Int>,
        childrenByPPID: [Int: [Int]]
    ) -> Set<Int> {
        var visited: Set<Int> = []
        var stack = roots.filter { $0 > 0 }.sorted()
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            if let children = childrenByPPID[current] {
                for child in children where child > 0 && !visited.contains(child) {
                    stack.append(child)
                }
            }
        }
        return visited
    }

    private static func aggregateTreeMetrics(
        roots: Set<Int>,
        childrenByPPID: [Int: [Int]],
        processes: [Int: ProcessRow],
        listeningPorts: [Int: [Int]]
    ) -> (treePIDs: Set<Int>, rssBytes: Int64, cpuPercent: Double, ports: [Int]) {
        let treePIDs = collectProcessTreePIDs(roots: roots, childrenByPPID: childrenByPPID)
        var totalRSSKB: Int64 = 0
        var totalCPU: Double = 0.0
        var portSet: Set<Int> = []
        for pid in treePIDs {
            if let row = processes[pid] {
                totalRSSKB += max(0, row.rssKB)
                totalCPU += max(0.0, row.cpuPercent)
            }
            if let ports = listeningPorts[pid] {
                portSet.formUnion(ports)
            }
        }
        return (treePIDs, totalRSSKB * 1024, totalCPU, portSet.sorted())
    }

    // MARK: - Full Correlation & Orphan Detection (M1: L4, L5, L7)

    public static func correlate(
        plists: [PlistMetadata],
        launchctlMap: [String: LaunchctlEntry],
        processes: [Int: ProcessRow],
        listeningPorts: [Int: [Int]],
        frozenRecords: [FreezeSnapshotRecord],
        currentUID: Int
    ) -> [LaunchItem] {
        var childrenByPPID: [Int: [Int]] = [:]
        var parsedProcesses: [Int: ParsedInvocation] = [:]
        for proc in processes.values {
            if proc.pid > 0 && proc.pid != proc.ppid {
                childrenByPPID[proc.ppid, default: []].append(proc.pid)
            }
            parsedProcesses[proc.pid] = parseInvocation(command: proc.command, explicitArguments: nil)
        }

        var claimedPIDs: Set<Int> = []
        let committedFrozenRecords = frozenRecords.filter { $0.status == .frozen }
        let frozenSet = Set(committedFrozenRecords.map(\.label))

        // Claim all live PIDs (and their descendant trees) explicitly reported by `launchctl list`
        for entry in launchctlMap.values {
            if let pid = entry.pid, pid > 0 {
                let tree = collectProcessTreePIDs(roots: [pid], childrenByPPID: childrenByPPID)
                claimedPIDs.formUnion(tree)
            }
        }

        // Pre-parse plist invocations for exact service matching (L5, L7)
        let plistInvocations: [ParsedInvocation] = plists.map {
            parseInvocation(command: $0.programCommand, explicitArguments: $0.programArguments)
        }

        var items: [LaunchItem] = []
        items.reserveCapacity(plists.count + committedFrozenRecords.count)

        for (idx, meta) in plists.enumerated() {
            let lctl = launchctlMap[meta.label]
            let isFrozen = frozenSet.contains(meta.label)
            let isApple = meta.label.lowercased().hasPrefix("com.apple.")
            let metaInv = plistInvocations[idx]

            var primaryPID: Int? = lctl?.pid
            var rssBytes: Int64 = 0
            var cpuPercent: Double = 0.0
            var ports: [Int] = []

            if let pid = lctl?.pid, pid > 0 {
                let metrics = aggregateTreeMetrics(
                    roots: [pid],
                    childrenByPPID: childrenByPPID,
                    processes: processes,
                    listeningPorts: listeningPorts
                )
                claimedPIDs.formUnion(metrics.treePIDs)
                rssBytes = metrics.rssBytes
                cpuPercent = metrics.cpuPercent
                ports = metrics.ports
            } else if lctl == nil && !isFrozen {
                // System LaunchDaemons (or plists not listed in user `launchctl list`):
                // Cross-reference unclaimed processes by exact executable path (+ interpreter target if interpreter).
                let candidatePIDs = processes.values
                    .filter { proc in
                        guard !claimedPIDs.contains(proc.pid) else { return false }
                        if meta.domain == .userAgent && proc.uid != currentUID {
                            return false
                        }
                        guard let procInv = parsedProcesses[proc.pid] else { return false }
                        return doesProcessMatchPlistInvocation(procInv: procInv, plistInv: metaInv)
                    }
                    .map(\.pid)

                if !candidatePIDs.isEmpty {
                    let candidateSet = Set(candidatePIDs)
                    let minimalRoots = candidatePIDs
                        .filter { pid in
                            guard let ppid = processes[pid]?.ppid else { return true }
                            return !candidateSet.contains(ppid)
                        }
                        .sorted()
                    let roots = minimalRoots.isEmpty ? [candidatePIDs.min()!] : minimalRoots
                    primaryPID = roots.first
                    let metrics = aggregateTreeMetrics(
                        roots: Set(roots),
                        childrenByPPID: childrenByPPID,
                        processes: processes,
                        listeningPorts: listeningPorts
                    )
                    claimedPIDs.formUnion(metrics.treePIDs)
                    rssBytes = metrics.rssBytes
                    cpuPercent = metrics.cpuPercent
                    ports = metrics.ports
                }
            }

            items.append(
                LaunchItem(
                    id: "\(meta.domain.rawValue)::\(meta.label)",
                    label: meta.label,
                    domain: meta.domain,
                    plistPath: meta.plistPath,
                    programCommand: meta.programCommand,
                    pid: primaryPID,
                    rssBytes: rssBytes,
                    cpuPercent: cpuPercent,
                    listeningPorts: ports,
                    runAtLoad: meta.runAtLoad,
                    keepAlive: meta.keepAlive,
                    lastExitStatus: lctl?.lastExitStatus,
                    isAppleSystem: isApple,
                    isFrozen: isFrozen
                )
            )
        }

        // Surface already-frozen items whose .plist was moved into the snapshot vault
        let seenLabels = Set(items.map(\.label))
        for rec in committedFrozenRecords where !seenLabels.contains(rec.label) {
            items.append(
                LaunchItem(
                    id: "frozen::\(rec.label)",
                    label: rec.label,
                    domain: .userAgent,
                    plistPath: rec.originalPlistPath,
                    programCommand: "Frozen snapshot (\(URL(fileURLWithPath: rec.originalPlistPath).lastPathComponent))",
                    pid: nil,
                    rssBytes: 0,
                    cpuPercent: 0,
                    listeningPorts: [],
                    runAtLoad: false,
                    keepAlive: false,
                    lastExitStatus: 0,
                    isAppleSystem: false,
                    isFrozen: true
                )
            )
        }

        let activePlistInvocations: [ParsedInvocation] = zip(plists, plistInvocations)
            .filter { !frozenSet.contains($0.0.label) }
            .map(\.1)

        // Detect orphaned developer / AI agent daemons (PPID == 1, owned by current user, not backed by launchd or GUI .app)
        for proc in processes.values.sorted(by: { $0.pid < $1.pid }) {
            guard proc.uid == currentUID,
                  proc.ppid == 1,
                  !claimedPIDs.contains(proc.pid) else { continue }

            guard let procInv = parsedProcesses[proc.pid] else { continue }

            // L4: Exclude Apple system binaries, .xpc/.appex bundles, and genuine GUI .app bundles,
            // while keeping CLI framework interpreter shims such as Python.app and Ruby.app.
            if isAppleSystemOrGenuineAppBundle(executablePath: procInv.executablePath) {
                continue
            }

            // L5: Check known non-frozen LaunchAgent/Daemon plists by exact executable / interpreter script target.
            if activePlistInvocations.contains(where: { doesProcessMatchPlistInvocation(procInv: procInv, plistInv: $0) }) {
                continue
            }

            let metrics = aggregateTreeMetrics(
                roots: [proc.pid],
                childrenByPPID: childrenByPPID,
                processes: processes,
                listeningPorts: listeningPorts
            )

            guard qualifiesAsOrphanDaemon(procInv: procInv, listeningPorts: metrics.ports) else {
                continue
            }

            claimedPIDs.formUnion(metrics.treePIDs)
            let shortName = formatOrphanLabel(procInv: procInv, pid: proc.pid)
            items.append(
                LaunchItem(
                    id: "orphan::\(proc.pid)",
                    label: shortName,
                    domain: .orphanDaemon,
                    plistPath: nil,
                    programCommand: proc.command,
                    pid: proc.pid,
                    rssBytes: metrics.rssBytes,
                    cpuPercent: metrics.cpuPercent,
                    listeningPorts: metrics.ports,
                    runAtLoad: false,
                    keepAlive: false,
                    lastExitStatus: nil,
                    isAppleSystem: false,
                    isFrozen: false
                )
            )
        }

        return items.sorted { a, b in
            if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
            if a.isFrozen != b.isFrozen { return a.isFrozen && !b.isFrozen }
            return a.label < b.label
        }
    }

    // MARK: - Live Host Scan

    public static func scanLiveHost(
        ledgerStore: FreezeLedgerStore,
        plistDirectories: [(URL, ServiceDomain)]? = nil
    ) -> LaunchSnapshot {
        let fm = FileManager.default
        let directories: [(URL, ServiceDomain)] = plistDirectories ?? [
            (ledgerStore.userLaunchAgentsDirectory, .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon)
        ]

        var plists: [PlistMetadata] = []
        for (dir, domain) in directories {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "plist" {
                if let meta = readPlistMetadata(at: url, domain: domain) {
                    plists.append(meta)
                }
            }
        }

        let lctlOut = runCommand("/bin/launchctl", ["list"])
        let psOut = runCommand("/bin/ps", ["-axo", "pid,ppid,uid,rss,pcpu,args"])
        let lsofOut = runCommand("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pn"])

        let records = ledgerStore.loadFrozenRecords()
        let items = correlate(
            plists: plists,
            launchctlMap: parseLaunchctlList(lctlOut),
            processes: parsePSOutput(psOut),
            listeningPorts: parseLsofPorts(lsofOut),
            frozenRecords: records,
            currentUID: Int(getuid())
        )
        return LaunchSnapshot(capturedAt: Date(), items: items, frozenRecords: records)
    }

    // MARK: - M1 Classification & Matching Helpers (L4, L5)

    private static func isAppleSystemOrGenuineAppBundle(executablePath: String) -> Bool {
        let lower = executablePath.lowercased()
        if lower.hasPrefix("/system/")
            || lower.hasPrefix("/usr/libexec/")
            || lower.hasPrefix("/usr/sbin/")
            || lower.hasPrefix("/sbin/") {
            return true
        }
        if lower.contains(".xpc/contents/") || lower.contains(".appex/contents/") {
            return true
        }

        // Ignore Xcode.app/Contents/Developer/ which houses CLI toolchains & Python3.framework
        let cleaned = lower.replacingOccurrences(of: "/xcode.app/contents/developer/", with: "/_xcode_cli_developer_/")
        let segments = cleaned.split(separator: "/").map(String.init)
        var appSegments: [String] = []
        for idx in 0..<segments.count {
            if segments[idx].hasSuffix(".app"),
               idx + 1 < segments.count,
               segments[idx + 1] == "contents" {
                appSegments.append(segments[idx])
            }
        }
        if appSegments.isEmpty {
            return false
        }
        return appSegments.contains { !cliFrameworkInterpreterBundles.contains($0) }
    }

    private static func doesProcessMatchPlistInvocation(
        procInv: ParsedInvocation,
        plistInv: ParsedInvocation
    ) -> Bool {
        guard !plistInv.executableBasename.isEmpty else { return false }

        switch (plistInv.runtimeKind, procInv.runtimeKind) {
        case let (.scriptingRuntime(pFam), .scriptingRuntime(cFam)):
            guard pFam == cFam,
                  let pTarget = plistInv.target.identityKey,
                  let cTarget = procInv.target.identityKey else {
                return false
            }
            return pTarget == cTarget

        case (.shell, .shell):
            guard let pTarget = plistInv.target.identityKey,
                  let cTarget = procInv.target.identityKey else {
                return false
            }
            return pTarget == cTarget

        case (.nativeBinary, .nativeBinary):
            if plistInv.normalizedExecutablePath.hasPrefix("/") && procInv.normalizedExecutablePath.hasPrefix("/") {
                return plistInv.normalizedExecutablePath == procInv.normalizedExecutablePath
            }
            return plistInv.executableBasename == procInv.executableBasename

        default:
            return false
        }
    }

    private static func qualifiesAsOrphanDaemon(
        procInv: ParsedInvocation,
        listeningPorts: [Int]
    ) -> Bool {
        if !listeningPorts.isEmpty {
            return true
        }
        switch procInv.runtimeKind {
        case .scriptingRuntime:
            return procInv.target != .none || !procInv.rawArguments.isEmpty
        case .shell:
            return procInv.shellRunsDevOrScriptTarget
        case .nativeBinary:
            return exactDevDaemonBasenames.contains(procInv.executableBasename)
        }
    }

    private static func formatOrphanLabel(procInv: ParsedInvocation, pid: Int) -> String {
        let exe = procInv.displayExecutable.isEmpty ? "orphan" : procInv.displayExecutable
        if let targetLabel = procInv.target.displayLabel, !targetLabel.isEmpty {
            return "\(exe) / \(targetLabel) (PID \(pid))"
        }
        if let firstArg = procInv.rawArguments.first(where: { !$0.hasPrefix("-") && !$0.isEmpty }) {
            let argDisplay = concisePathDisplay(firstArg)
            return "\(exe) / \(argDisplay) (PID \(pid))"
        }
        return "\(exe) (PID \(pid))"
    }

    private static func parseInvocation(
        command: String,
        explicitArguments: [String]?
    ) -> ParsedInvocation {
        let initialTokens: (exe: String, args: [String]) = {
            if let explicitArguments, let first = explicitArguments.first, !first.isEmpty {
                return (first, Array(explicitArguments.dropFirst()))
            }
            let (exe, rest) = splitExecutableAndArgumentsString(command)
            return (exe, tokenizeArguments(rest))
        }()

        var exeToken = initialTokens.exe
        var args = initialTokens.args

        // Strip leading login-shell dash (e.g. "-zsh" -> "zsh") for basename inspection
        if exeToken.hasPrefix("-") && exeToken.count > 1 && !exeToken.contains("/") {
            exeToken = String(exeToken.dropFirst())
        }

        // Unwrap `/usr/bin/env` or `env`
        let initialBase = URL(fileURLWithPath: exeToken).lastPathComponent.lowercased()
        if initialBase == "env" {
            var idx = 0
            while idx < args.count {
                let tok = args[idx]
                if tok == "-i" || tok == "-S" || tok == "--" {
                    idx += 1
                } else if tok == "-u" && idx + 1 < args.count {
                    idx += 2
                } else if tok.hasPrefix("-") {
                    idx += 1
                } else if tok.contains("=") && !tok.hasPrefix("/") && !tok.hasPrefix("./") {
                    idx += 1
                } else {
                    break
                }
            }
            if idx < args.count {
                exeToken = args[idx]
                args = Array(args.dropFirst(idx + 1))
            }
        }

        let normalizedExe = normalizePathToken(exeToken)
        let rawBase = URL(fileURLWithPath: normalizedExe).lastPathComponent
        let lowerBase = rawBase.lowercased()
        let kind = classifyRuntime(executableBasename: lowerBase)
        let displayExe: String = {
            if case .scriptingRuntime(.python) = kind, lowerBase == "python" && normalizedExe.lowercased().contains("python3") {
                return "python3"
            }
            return rawBase.isEmpty ? exeToken : rawBase
        }()

        let (target, shellDev) = extractInvocationTarget(kind: kind, args: args)
        return ParsedInvocation(
            executablePath: exeToken,
            normalizedExecutablePath: normalizedExe,
            executableBasename: lowerBase,
            displayExecutable: displayExe,
            rawArguments: args,
            runtimeKind: kind,
            target: target,
            shellRunsDevOrScriptTarget: shellDev
        )
    }

    private static func classifyRuntime(executableBasename base: String) -> RuntimeKind {
        if base == "python" || base == "python2" || base == "python3" || base == "pypy" || base == "pypy3"
            || matchesVersionedInterpreter(base, prefix: "python2.")
            || matchesVersionedInterpreter(base, prefix: "python3.") {
            return .scriptingRuntime(.python)
        }
        if base == "node" || base == "nodejs" || base == "tsx" || base == "ts-node" || base == "npx" {
            return .scriptingRuntime(.node)
        }
        if base == "deno" {
            return .scriptingRuntime(.deno)
        }
        if base == "bun" || base == "bunx" {
            return .scriptingRuntime(.bun)
        }
        if base == "uv" || base == "uvx" {
            return .scriptingRuntime(.uv)
        }
        if base == "ruby" || matchesVersionedInterpreter(base, prefix: "ruby") {
            return .scriptingRuntime(.ruby)
        }
        if base == "perl" || matchesVersionedInterpreter(base, prefix: "perl") {
            return .scriptingRuntime(.perl)
        }
        if base == "java" {
            return .scriptingRuntime(.java)
        }
        if base == "sh" || base == "bash" || base == "zsh" || base == "dash" || base == "fish" {
            return .shell
        }
        return .nativeBinary
    }

    private static func matchesVersionedInterpreter(_ base: String, prefix: String) -> Bool {
        guard base.hasPrefix(prefix), base.count > prefix.count else { return false }
        let suffix = base.dropFirst(prefix.count)
        return suffix.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func extractInvocationTarget(
        kind: RuntimeKind,
        args: [String]
    ) -> (InvocationTarget, Bool) {
        switch kind {
        case .nativeBinary:
            return (.none, false)

        case .scriptingRuntime(let family):
            switch family {
            case .python:
                var idx = 0
                while idx < args.count {
                    let tok = args[idx]
                    if tok == "-m", idx + 1 < args.count {
                        return (.module(args[idx + 1]), false)
                    }
                    if tok == "-c", idx + 1 < args.count {
                        return (.inlineCode(String(args[idx + 1].prefix(64))), false)
                    }
                    if (tok == "-W" || tok == "-X") && idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok == "--" {
                        idx += 1
                        break
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    return (makeScriptTarget(tok), false)
                }
                return (.none, false)

            case .node:
                var idx = 0
                let flagsWithValue: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-p", "--package"]
                while idx < args.count {
                    let tok = args[idx]
                    if (tok == "-e" || tok == "--eval" || tok == "--print"), idx + 1 < args.count {
                        return (.inlineCode(String(args[idx + 1].prefix(64))), false)
                    }
                    if flagsWithValue.contains(tok), idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok == "--" {
                        idx += 1
                        break
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    if tok.contains("/") || tok.hasSuffix(".js") || tok.hasSuffix(".mjs") || tok.hasSuffix(".cjs") || tok.hasSuffix(".ts") {
                        return (makeScriptTarget(tok), false)
                    }
                    return (.packageCommand(tok), false)
                }
                return (.none, false)

            case .deno:
                var idx = 0
                while idx < args.count {
                    let tok = args[idx]
                    if tok == "run" || tok == "serve" || tok == "task" {
                        idx += 1
                        continue
                    }
                    if (tok == "--config" || tok == "-c" || tok == "--import-map") && idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    return (makeScriptTarget(tok), false)
                }
                return (.none, false)

            case .bun:
                var idx = 0
                while idx < args.count {
                    let tok = args[idx]
                    if tok == "run" || tok == "x" {
                        idx += 1
                        continue
                    }
                    if tok == "-e", idx + 1 < args.count {
                        return (.inlineCode(String(args[idx + 1].prefix(64))), false)
                    }
                    if tok == "--cwd", idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    if tok.contains("/") || tok.hasSuffix(".js") || tok.hasSuffix(".ts") || tok.hasSuffix(".mjs") {
                        return (makeScriptTarget(tok), false)
                    }
                    return (.packageCommand(tok), false)
                }
                return (.none, false)

            case .uv:
                var idx = 0
                let uvValueFlags: Set<String> = ["--from", "--with", "--python", "-p", "--directory", "--project"]
                while idx < args.count {
                    let tok = args[idx]
                    if tok == "run" || tok == "tool" {
                        idx += 1
                        continue
                    }
                    if uvValueFlags.contains(tok), idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    if tok.contains("/") || tok.hasSuffix(".py") {
                        return (makeScriptTarget(tok), false)
                    }
                    return (.packageCommand(tok), false)
                }
                return (.none, false)

            case .ruby, .perl:
                var idx = 0
                while idx < args.count {
                    let tok = args[idx]
                    if (tok == "-e" || tok == "-E"), idx + 1 < args.count {
                        return (.inlineCode(String(args[idx + 1].prefix(64))), false)
                    }
                    if (tok == "-I" || tok == "-r"), idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    return (makeScriptTarget(tok), false)
                }
                return (.none, false)

            case .java:
                var idx = 0
                let javaValueFlags: Set<String> = ["-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-opens", "--add-exports"]
                while idx < args.count {
                    let tok = args[idx]
                    if tok == "-jar", idx + 1 < args.count {
                        let norm = normalizePathToken(args[idx + 1])
                        return (.jarPath(normalizedPath: norm, displayName: concisePathDisplay(norm)), false)
                    }
                    if (tok == "-m" || tok == "--module"), idx + 1 < args.count {
                        return (.module(args[idx + 1]), false)
                    }
                    if javaValueFlags.contains(tok), idx + 1 < args.count {
                        idx += 2
                        continue
                    }
                    if tok.hasPrefix("-") {
                        idx += 1
                        continue
                    }
                    return (.module(tok), false)
                }
                return (.none, false)
            }

        case .shell:
            var idx = 0
            while idx < args.count {
                let tok = args[idx]
                if tok == "-c" || tok == "-lc" || tok == "-ic", idx + 1 < args.count {
                    let subCmd = args[idx + 1]
                    let nested = parseInvocation(command: subCmd, explicitArguments: nil)
                    switch nested.runtimeKind {
                    case .scriptingRuntime:
                        let label = nested.target.displayLabel.map { "\(nested.displayExecutable) \($0)" } ?? nested.displayExecutable
                        return (.packageCommand(label), true)
                    case .nativeBinary:
                        if exactDevDaemonBasenames.contains(nested.executableBasename) {
                            return (.packageCommand(nested.displayExecutable), true)
                        }
                        return (.inlineCode(String(subCmd.prefix(64))), false)
                    case .shell:
                        return (.inlineCode(String(subCmd.prefix(64))), false)
                    }
                }
                if tok.hasPrefix("-") || tok.hasPrefix("+") {
                    idx += 1
                    continue
                }
                return (makeScriptTarget(tok), true)
            }
            return (.none, false)
        }
    }

    private static func makeScriptTarget(_ rawPath: String) -> InvocationTarget {
        let normalized = normalizePathToken(rawPath)
        return .scriptPath(normalizedPath: normalized, displayName: concisePathDisplay(normalized))
    }

    private static func normalizePathToken(_ raw: String) -> String {
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if unquoted.hasPrefix("~/") || unquoted == "~" {
            return URL(fileURLWithPath: (unquoted as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        if unquoted.hasPrefix("/") {
            return URL(fileURLWithPath: unquoted).standardizedFileURL.path
        }
        return unquoted
    }

    private static func concisePathDisplay(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return path }
        if genericScriptFilenames.contains(leaf.lowercased()), components.count >= 2 {
            let parent = components[components.count - 2]
            if components.count >= 3 && components[components.count - 3].hasPrefix("@") {
                return "\(components[components.count - 3])/\(parent)/\(leaf)"
            }
            return "\(parent)/\(leaf)"
        }
        return leaf
    }

    /// Splits a `ps` command line into `(executable, remainingArguments)` while preserving spaces inside
    /// macOS `.app`, `.xpc`, `.appex`, `.framework`, `.bundle`, and `Application Support` paths.
    private static func splitExecutableAndArgumentsString(_ command: String) -> (String, String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        if let firstChar = trimmed.first, firstChar == "\"" || firstChar == "'" {
            let afterQuote = trimmed.index(after: trimmed.startIndex)
            if let endQuote = trimmed[afterQuote...].firstIndex(of: firstChar) {
                let exe = String(trimmed[afterQuote..<endQuote])
                let rest = String(trimmed[trimmed.index(after: endQuote)...]).trimmingCharacters(in: .whitespaces)
                return (exe, rest)
            }
        }

        if !(trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")) {
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { return ("", "") }
            let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            return (String(head), rest)
        }

        var searchStart = trimmed.startIndex
        while searchStart < trimmed.endIndex {
            guard let spaceIdx = trimmed[searchStart...].firstIndex(of: " ") else {
                return (trimmed, "")
            }
            let prefix = String(trimmed[..<spaceIdx])
            let after = String(trimmed[trimmed.index(after: spaceIdx)...]).drop(while: { $0 == " " })
            if after.isEmpty || after.hasPrefix("-") || after.hasPrefix("/") || after.hasPrefix("~/") {
                return (prefix, String(after))
            }

            let afterStr = String(after)
            if continuesBundleOrSupportDirectory(afterStr) {
                searchStart = trimmed.index(after: spaceIdx)
                continue
            }

            let lowerPrefix = prefix.lowercased()
            if let macosRange = lowerPrefix.range(of: "/contents/macos/", options: .backwards) {
                let tailAfterMacOS = lowerPrefix[macosRange.upperBound...]
                if !tailAfterMacOS.contains("/") {
                    let nextWord = String(afterStr.prefix(while: { $0 != " " && $0 != "\t" })).lowercased()
                    let looksLikeScriptArg = nextWord.contains("/")
                        || nextWord.hasSuffix(".py")
                        || nextWord.hasSuffix(".js")
                        || nextWord.hasSuffix(".mjs")
                        || nextWord.hasSuffix(".cjs")
                        || nextWord.hasSuffix(".ts")
                        || nextWord.hasSuffix(".rb")
                        || nextWord.hasSuffix(".pl")
                        || nextWord.hasSuffix(".sh")
                        || nextWord.hasSuffix(".jar")
                    if !looksLikeScriptArg {
                        searchStart = trimmed.index(after: spaceIdx)
                        continue
                    }
                }
            }

            return (prefix, afterStr)
        }
        return (trimmed, "")
    }

    private static func continuesBundleOrSupportDirectory(_ afterSpace: String) -> Bool {
        // Scan up to the next ` -` or ` /` boundary to see if this space lies inside a macOS bundle/framework/Support directory
        var boundary = afterSpace.endIndex
        if let flagRange = afterSpace.range(of: " -") {
            boundary = min(boundary, flagRange.lowerBound)
        }
        if let pathRange = afterSpace.range(of: " /") {
            boundary = min(boundary, pathRange.lowerBound)
        }
        let candidate = afterSpace[..<boundary].lowercased()
        let markers = [".app/", ".xpc/", ".appex/", ".framework/", ".bundle/", "/contents/", "support/"]
        return markers.contains { candidate.contains($0) }
    }

    private static func tokenizeArguments(_ rest: String) -> [String] {
        guard !rest.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?

        for ch in rest {
            if let q = activeQuote {
                if ch == q {
                    activeQuote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                activeQuote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func isStrictDecimalToken(_ token: String) -> Bool {
        guard let dot = token.firstIndex(of: "."),
              dot != token.startIndex,
              dot != token.index(before: token.endIndex) else {
            return false
        }
        let intPart = token[..<dot]
        let fracPart = token[token.index(after: dot)...]
        return intPart.allSatisfy(\.isNumber) && fracPart.allSatisfy(\.isNumber)
    }

    private static func extractPortFromEndpoint(_ endpoint: String) -> Int? {
        guard let colonIdx = endpoint.lastIndex(of: ":") else { return nil }
        let portSlice = endpoint[endpoint.index(after: colonIdx)...]
        guard !portSlice.isEmpty, portSlice.allSatisfy(\.isNumber) else { return nil }
        return Int(portSlice)
    }

    private static func runCommand(_ launchPath: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return "" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
