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
    public var runAtLoad: Bool
    public var keepAlive: Bool

    public init(
        label: String,
        plistPath: String,
        domain: ServiceDomain,
        programCommand: String,
        runAtLoad: Bool,
        keepAlive: Bool
    ) {
        self.label = label
        self.plistPath = plistPath
        self.domain = domain
        self.programCommand = programCommand
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
    }
}

public enum LaunchScanner {

    private static let orphanRuntimeHints: [String] = [
        "node", "npx", "python", "uv", "uvx", "codex", "claude",
        "opencode", "vibe", "deno", "bun", "ollama", "llama-server",
        "mcp", "playwright", "chromium", "java"
    ]

    // MARK: - Deterministic Output Parsers

    public static func parseLaunchctlList(_ output: String) -> [String: LaunchctlEntry] {
        var map: [String: LaunchctlEntry] = [:]
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("PID") { return }
            let cols = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard cols.count >= 3 else { return }
            let pid = cols[0] == "-" ? nil : Int(cols[0])
            let status = cols[1] == "-" ? nil : Int(cols[1])
            let label = cols.dropFirst(2).joined(separator: " ")
            map[label] = LaunchctlEntry(pid: pid, lastExitStatus: status, label: label)
        }
        return map
    }

    /// Parses `ps -axo pid,ppid,uid,rss,pcpu,args`
    public static func parsePSOutput(_ output: String) -> [Int: ProcessRow] {
        var rows: [Int: ProcessRow] = [:]
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("PID") { return }
            let parts = trimmed.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 6,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let uid = Int(parts[2]),
                  let rssKB = Int64(parts[3]) else { return }
            let cpu = Double(parts[4]) ?? 0.0
            let cmd = String(parts[5])
            rows[pid] = ProcessRow(pid: pid, ppid: ppid, uid: uid, rssKB: rssKB, cpuPercent: cpu, command: cmd)
        }
        return rows
    }

    /// Parses `lsof -iTCP -sTCP:LISTEN -P -n -F pn`
    public static func parseLsofPorts(_ output: String) -> [Int: [Int]] {
        var result: [Int: Set<Int>] = [:]
        var currentPID: Int?
        output.enumerateLines { line, _ in
            guard let prefix = line.first else { return }
            let body = String(line.dropFirst())
            if prefix == "p", let pid = Int(body) {
                currentPID = pid
            } else if prefix == "n", let pid = currentPID {
                if let colonIdx = body.lastIndex(of: ":"),
                   let port = Int(body[body.index(after: colonIdx)...]) {
                    result[pid, default: []].insert(port)
                }
            }
        }
        return result.mapValues { Array($0).sorted() }
    }

    public static func readPlistMetadata(at url: URL, domain: ServiceDomain) -> PlistMetadata? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any] else { return nil }

        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program: String = {
            if let args = dict["ProgramArguments"] as? [String], !args.isEmpty {
                return args.joined(separator: " ")
            }
            if let prog = dict["Program"] as? String {
                return prog
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
            runAtLoad: runAtLoad,
            keepAlive: keepAlive
        )
    }

    // MARK: - Full Correlation & Orphan Detection

    public static func correlate(
        plists: [PlistMetadata],
        launchctlMap: [String: LaunchctlEntry],
        processes: [Int: ProcessRow],
        listeningPorts: [Int: [Int]],
        frozenRecords: [FreezeSnapshotRecord],
        currentUID: Int
    ) -> [LaunchItem] {
        var items: [LaunchItem] = []
        var claimedPIDs: Set<Int> = []
        let frozenSet = Set(frozenRecords.map(\.label))

        for meta in plists {
            let lctl = launchctlMap[meta.label]
            let pid = lctl?.pid
            if let pid { claimedPIDs.insert(pid) }
            let proc = pid.flatMap { processes[$0] }
            let rssBytes = (proc?.rssKB ?? 0) * 1024
            let cpu = proc?.cpuPercent ?? 0.0
            let ports = pid.flatMap { listeningPorts[$0] } ?? []
            let isApple = meta.label.lowercased().hasPrefix("com.apple.")

            items.append(
                LaunchItem(
                    id: "\(meta.domain.rawValue)::\(meta.label)",
                    label: meta.label,
                    domain: meta.domain,
                    plistPath: meta.plistPath,
                    programCommand: meta.programCommand,
                    pid: pid,
                    rssBytes: rssBytes,
                    cpuPercent: cpu,
                    listeningPorts: ports,
                    runAtLoad: meta.runAtLoad,
                    keepAlive: meta.keepAlive,
                    lastExitStatus: lctl?.lastExitStatus,
                    isAppleSystem: isApple,
                    isFrozen: frozenSet.contains(meta.label)
                )
            )
        }

        // Surface already-frozen items whose .plist was moved into the snapshot vault
        let seenLabels = Set(items.map(\.label))
        for rec in frozenRecords where !seenLabels.contains(rec.label) {
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

        // Also claim any PID explicitly listed in launchctl (including Apple XPC / UI apps)
        for entry in launchctlMap.values {
            if let pid = entry.pid {
                claimedPIDs.insert(pid)
            }
        }

        // Detect orphaned developer / AI agent daemons (PPID == 1, owned by current user, not backed by launchd or .app UI)
        for proc in processes.values {
            guard proc.uid == currentUID,
                  proc.ppid == 1,
                  !claimedPIDs.contains(proc.pid) else { continue }

            let lower = proc.command.lowercased()
            if lower.contains("/system/library/") || lower.contains("/usr/libexec/") || lower.contains(".app/contents/") {
                continue
            }
            let matchesDevOrAgent = orphanRuntimeHints.contains { hint in
                lower.contains("/\(hint)") || lower.hasPrefix("\(hint) ") || lower.contains(" \(hint) ")
            }
            guard matchesDevOrAgent else { continue }

            let ports = listeningPorts[proc.pid] ?? []
            let shortName = deriveOrphanLabel(from: proc.command, pid: proc.pid)
            items.append(
                LaunchItem(
                    id: "orphan::\(proc.pid)",
                    label: shortName,
                    domain: .orphanDaemon,
                    plistPath: nil,
                    programCommand: proc.command,
                    pid: proc.pid,
                    rssBytes: proc.rssKB * 1024,
                    cpuPercent: proc.cpuPercent,
                    listeningPorts: ports,
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

    public static func scanLiveHost(ledgerStore: FreezeLedgerStore) -> LaunchSnapshot {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let directories: [(URL, ServiceDomain)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon)
        ]

        var plists: [PlistMetadata] = []
        for (dir, domain) in directories {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in urls where url.pathExtension == "plist" {
                if let meta = readPlistMetadata(at: url, domain: domain) {
                    plists.append(meta)
                }
            }
        }

        let lctlOut = runCommand("/bin/launchctl", ["list"])
        let psOut = runCommand("/bin/ps", ["-axo", "pid,ppid,uid,rss,pcpu,args"])
        let lsofOut = runCommand("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pn"])

        let records = ledgerStore.loadRecords()
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

    private static func deriveOrphanLabel(from command: String, pid: Int) -> String {
        let head = command.components(separatedBy: " --").first ?? command
        let normalized = head.replacingOccurrences(of: "Application Support", with: "Application_Support")
        let tokens = normalized.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return "orphan-\(pid)" }
        let exe = URL(fileURLWithPath: first).lastPathComponent
        if let second = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            let argBase = URL(fileURLWithPath: second).lastPathComponent
            return "\(exe) / \(argBase) (PID \(pid))"
        }
        return "\(exe) (PID \(pid))"
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
