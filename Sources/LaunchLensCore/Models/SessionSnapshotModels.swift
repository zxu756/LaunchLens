import Foundation

public struct SnapshotHostInfo: Codable, Equatable, Sendable {
    public var hostname: String
    public var osVersion: String
    public var architecture: String
    public var uid: Int

    public init(
        hostname: String,
        osVersion: String,
        architecture: String,
        uid: Int
    ) {
        self.hostname = hostname
        self.osVersion = osVersion
        self.architecture = architecture
        self.uid = uid
    }

    public static func current(uid: Int = Int(getuid())) -> SnapshotHostInfo {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return SnapshotHostInfo(
            hostname: ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: arch,
            uid: uid
        )
    }
}

public enum SnapshotServiceDomain: String, Codable, CaseIterable, Equatable, Sendable {
    case user = "user"
    case global = "global"
    case system = "system"

    public init?(serviceDomain: ServiceDomain) {
        switch serviceDomain {
        case .userAgent:
            self = .user
        case .globalAgent:
            self = .global
        case .systemDaemon:
            self = .system
        case .orphanDaemon:
            return nil
        }
    }

    public var sortOrder: Int {
        switch self {
        case .user: return 0
        case .global: return 1
        case .system: return 2
        }
    }
}

public struct SnapshotServiceEntry: Codable, Equatable, Sendable {
    public var domainScope: SnapshotServiceDomain
    public var label: String
    public var plistPath: String
    public var isExternalPlist: Bool
    public var plistSHA256: String?
    public var programCommand: String
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var pid: Int?
    public var lastExitStatus: Int?

    public init(
        domainScope: SnapshotServiceDomain,
        label: String,
        plistPath: String,
        isExternalPlist: Bool = false,
        plistSHA256: String? = nil,
        programCommand: String,
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        pid: Int? = nil,
        lastExitStatus: Int? = nil
    ) {
        self.domainScope = domainScope
        self.label = label
        self.plistPath = SnapshotPathCanonicalizer.canonicalizePath(plistPath)
        self.isExternalPlist = isExternalPlist
        self.plistSHA256 = plistSHA256
        self.programCommand = programCommand
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    public var identityKey: String {
        "\(domainScope.rawValue)::\(label)::\(plistPath)"
    }

    public static func isDeterministicBefore(_ lhs: SnapshotServiceEntry, _ rhs: SnapshotServiceEntry) -> Bool {
        if lhs.domainScope.sortOrder != rhs.domainScope.sortOrder {
            return lhs.domainScope.sortOrder < rhs.domainScope.sortOrder
        }
        if lhs.label != rhs.label {
            return lhs.label < rhs.label
        }
        return lhs.plistPath < rhs.plistPath
    }
}

public struct SnapshotListenerEntry: Codable, Equatable, Sendable {
    public var port: Int
    public var protocols: [String]
    public var bindAddresses: [String]
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var lstart: String
    public var etimeSeconds: Int
    public var executable: String
    public var invocationIdentity: String
    public var programCommand: String
    public var serviceLabel: String?
    public var isOrphan: Bool

    public init(
        port: Int,
        protocols: [String],
        bindAddresses: [String],
        pid: Int,
        ppid: Int,
        uid: Int,
        lstart: String,
        etimeSeconds: Int = 0,
        executable: String,
        invocationIdentity: String,
        programCommand: String,
        serviceLabel: String? = nil,
        isOrphan: Bool
    ) {
        self.port = port
        self.protocols = Array(Set(protocols)).sorted()
        self.bindAddresses = Array(Set(bindAddresses)).sorted()
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.lstart = lstart
        self.etimeSeconds = max(0, etimeSeconds)
        self.executable = SnapshotPathCanonicalizer.canonicalizePath(executable)
        self.invocationIdentity = invocationIdentity
        self.programCommand = programCommand
        self.serviceLabel = serviceLabel
        self.isOrphan = isOrphan
    }

    public var identityKey: String {
        "\(port)::\(invocationIdentity)"
    }

    public static func isDeterministicBefore(_ lhs: SnapshotListenerEntry, _ rhs: SnapshotListenerEntry) -> Bool {
        if lhs.port != rhs.port {
            return lhs.port < rhs.port
        }
        if lhs.invocationIdentity != rhs.invocationIdentity {
            return lhs.invocationIdentity < rhs.invocationIdentity
        }
        return lhs.pid < rhs.pid
    }
}

public struct SnapshotOrphanEntry: Codable, Equatable, Sendable {
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var lstart: String
    public var etimeSeconds: Int
    public var executable: String
    public var invocationIdentity: String
    public var programCommand: String
    public var rssBytes: Int64

    public init(
        pid: Int,
        ppid: Int = 1,
        uid: Int,
        lstart: String,
        etimeSeconds: Int = 0,
        executable: String,
        invocationIdentity: String,
        programCommand: String,
        rssBytes: Int64 = 0
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.lstart = lstart
        self.etimeSeconds = max(0, etimeSeconds)
        self.executable = SnapshotPathCanonicalizer.canonicalizePath(executable)
        self.invocationIdentity = invocationIdentity
        self.programCommand = programCommand
        self.rssBytes = max(0, rssBytes)
    }

    public var identityKey: String {
        "pid=\(pid)|lstart=\(lstart)|exe=\(executable)"
    }

    public static func isDeterministicBefore(_ lhs: SnapshotOrphanEntry, _ rhs: SnapshotOrphanEntry) -> Bool {
        if lhs.pid != rhs.pid {
            return lhs.pid < rhs.pid
        }
        if lhs.lstart != rhs.lstart {
            return lhs.lstart < rhs.lstart
        }
        return lhs.executable < rhs.executable
    }
}

public enum SnapshotValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(found, expected):
            return "Unsupported SessionSnapshot schemaVersion \(found) (expected \(expected))."
        }
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var capturedAt: Date
    public var host: SnapshotHostInfo
    public var services: [SnapshotServiceEntry]
    public var listeners: [SnapshotListenerEntry]
    public var orphans: [SnapshotOrphanEntry]

    public init(
        schemaVersion: Int = SessionSnapshot.currentSchemaVersion,
        capturedAt: Date,
        host: SnapshotHostInfo,
        services: [SnapshotServiceEntry],
        listeners: [SnapshotListenerEntry],
        orphans: [SnapshotOrphanEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.host = host
        self.services = services.sorted(by: SnapshotServiceEntry.isDeterministicBefore)
        self.listeners = listeners.sorted(by: SnapshotListenerEntry.isDeterministicBefore)
        self.orphans = orphans.sorted(by: SnapshotOrphanEntry.isDeterministicBefore)
    }

    public static func encodePrettyJSON(_ snapshot: SessionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public static func decodeAndValidate(from data: Data) throws -> SessionSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionSnapshot.self, from: data)
        guard decoded.schemaVersion == SessionSnapshot.currentSchemaVersion else {
            throw SnapshotValidationError.unsupportedSchemaVersion(
                decoded.schemaVersion,
                expected: SessionSnapshot.currentSchemaVersion
            )
        }
        return decoded
    }
}

// MARK: - Canonical Path Normalization

internal enum SnapshotPathCanonicalizer {
    static func canonicalizePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !unquoted.isEmpty else { return "" }

        let expanded: String
        if unquoted == "~" || unquoted.hasPrefix("~/") {
            expanded = (unquoted as NSString).expandingTildeInPath
        } else {
            expanded = unquoted
        }

        // Preserve bare command names (e.g. "node", "python3") without prepending CWD.
        guard expanded.hasPrefix("/") else {
            return expanded
        }

        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let resolved = resolveLongestExistingAncestorSymlinks(standardized)
        return normalizeStandardMacOSRootSymlinks(resolved)
    }

    static func canonicalizePlistPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.lowercased().hasSuffix(".plist") else {
            return nil
        }
        return canonicalizePath(trimmed)
    }

    private static func resolveLongestExistingAncestorSymlinks(_ standardizedPath: String) -> String {
        let fm = FileManager.default
        var probe = standardizedPath
        var trailingComponents: [String] = []

        while probe != "/" && !probe.isEmpty {
            if fm.fileExists(atPath: probe) {
                let resolvedBase = resolveRealpath(probe) ?? URL(fileURLWithPath: probe).resolvingSymlinksInPath().path
                if trailingComponents.isEmpty {
                    return resolvedBase
                }
                var url = URL(fileURLWithPath: resolvedBase)
                for comp in trailingComponents.reversed() {
                    url.appendPathComponent(comp)
                }
                return url.standardizedFileURL.path
            }
            let url = URL(fileURLWithPath: probe)
            let last = url.lastPathComponent
            if last.isEmpty || last == "/" {
                break
            }
            trailingComponents.append(last)
            probe = url.deletingLastPathComponent().path
        }
        return standardizedPath
    }

    private static func resolveRealpath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func normalizeStandardMacOSRootSymlinks(_ path: String) -> String {
        if path == "/var" { return "/private/var" }
        if path.hasPrefix("/var/") { return "/private" + path }
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private" + path }
        if path == "/etc" { return "/private/etc" }
        if path.hasPrefix("/etc/") { return "/private" + path }
        return path
    }
}

// MARK: - Sensitive Command Argument Redaction (M2 Item 4)

public enum CommandArgumentRedactor {
    private static let exactSensitiveSegments: Set<String> = [
        "token", "tokens",
        "key", "keys",
        "secret", "secrets",
        "password", "passwords", "passwd", "passphrase", "pwd",
        "auth", "authorization", "bearer",
        "apikey", "apisecret", "authtoken", "accesstoken", "refreshtoken", "idtoken",
        "clientsecret", "privatekey", "secretkey", "accesskey",
        "credential", "credentials"
    ]

    private static let compoundSensitiveSuffixes: [String] = [
        "token", "secret", "password", "passwd", "passphrase",
        "apikey", "authkey", "privatekey", "secretkey", "accesskey"
    ]

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "x-auth-token",
        "cookie",
        "set-cookie"
    ]

    private static let httpAuthSchemes: Set<String> = [
        "bearer", "basic", "token", "digest", "negotiate", "aws4-hmac-sha256"
    ]

    private struct TokenSpan {
        var range: Range<String.Index>
        var raw: String
    }

    public static func redactCommandLine(_ command: String) -> String {
        guard !command.isEmpty else { return command }
        return redactSegment(command, depth: 0)
    }

    public static func redactArgumentTokens(_ tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return [] }
        return redactTokensList(tokens)
    }

    private static func redactTokensList(_ tokens: [String]) -> [String] {
        var out = tokens
        var idx = 0
        while idx < out.count {
            let tok = out[idx]
            if tok.hasPrefix("-"), tok != "--", !tok.contains("=") {
                if isSensitiveKeyName(tok) {
                    if idx + 1 < out.count, !out[idx + 1].hasPrefix("--") {
                        out[idx + 1] = "***"
                        idx += 2
                        continue
                    }
                }
            }
            out[idx] = redactDiscreteElement(tok)
            idx += 1
        }
        return out
    }

    private static func redactDiscreteElement(_ element: String) -> String {
        guard !element.isEmpty else { return element }
        if let headerRedacted = redactSensitiveHeaderLine(element) {
            return headerRedacted
        }
        if let eqIdx = element.firstIndex(of: "=") {
            let lhs = String(element[..<eqIdx])
            if (lhs.hasPrefix("-") && isSensitiveKeyName(lhs))
                || (isEnvironmentVariableIdentifier(lhs) && isSensitiveKeyName(lhs)) {
                return "\(lhs)=***"
            }
        }
        return redactCommandLine(element)
    }

    private static func redactSegment(_ text: String, depth: Int) -> String {
        guard depth <= 2 else { return text }
        let spans = scanTokenSpans(in: text)
        guard !spans.isEmpty else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var idx = 0

        while idx < spans.count {
            let span = spans[idx]
            let raw = span.raw

            // 1. Entire token is quoted (e.g. "Authorization: Bearer xxx" or "python3 --token=abc")
            if let (quoteChar, inner) = unwrapOuterQuotes(raw) {
                if let redactedHeader = redactSensitiveHeaderLine(inner) {
                    replacements.append((span.range, "\(quoteChar)\(redactedHeader)\(quoteChar)"))
                    idx += 1
                    continue
                }
                let innerRedacted = redactSegment(inner, depth: depth + 1)
                if innerRedacted != inner {
                    replacements.append((span.range, "\(quoteChar)\(innerRedacted)\(quoteChar)"))
                }
                idx += 1
                continue
            }

            // 2. Unquoted HTTP Authorization / API-key header tokens (as seen in `ps` output after shell quote stripping)
            if let colonIdx = raw.firstIndex(of: ":") {
                let headerPrefix = String(raw[..<colonIdx]).lowercased()
                if sensitiveHeaderNames.contains(headerPrefix) {
                    let headerWithColon = String(raw[...colonIdx])
                    let afterColon = String(raw[raw.index(after: colonIdx)...])
                    if afterColon.isEmpty {
                        if idx + 1 < spans.count {
                            let nextRaw = stripOuterQuotes(spans[idx + 1].raw)
                            if httpAuthSchemes.contains(nextRaw.lowercased()),
                               idx + 2 < spans.count,
                               !spans[idx + 2].raw.hasPrefix("--") {
                                let combined = span.range.lowerBound..<spans[idx + 2].range.upperBound
                                replacements.append((combined, "\(headerWithColon) ***"))
                                idx += 3
                                continue
                            } else if !spans[idx + 1].raw.hasPrefix("--") {
                                let combined = span.range.lowerBound..<spans[idx + 1].range.upperBound
                                replacements.append((combined, "\(headerWithColon) ***"))
                                idx += 2
                                continue
                            }
                        }
                        replacements.append((span.range, "\(headerWithColon) ***"))
                        idx += 1
                        continue
                    } else {
                        let unquotedAfter = stripOuterQuotes(afterColon)
                        if httpAuthSchemes.contains(unquotedAfter.lowercased()),
                           idx + 1 < spans.count,
                           !spans[idx + 1].raw.hasPrefix("--") {
                            let combined = span.range.lowerBound..<spans[idx + 1].range.upperBound
                            replacements.append((combined, "\(headerWithColon) ***"))
                            idx += 2
                            continue
                        }
                        replacements.append((span.range, "\(headerWithColon) ***"))
                        idx += 1
                        continue
                    }
                }
            }

            // 3. Flag or ENV assignment containing `=` (e.g. --token=abc, API_KEY=xyz, --header="Authorization: Basic ...")
            if let eqIdx = raw.firstIndex(of: "=") {
                let lhs = String(raw[..<eqIdx])
                let rhs = String(raw[raw.index(after: eqIdx)...])
                if lhs.hasPrefix("-") {
                    if isSensitiveKeyName(lhs) {
                        replacements.append((span.range, "\(lhs)=***"))
                        idx += 1
                        continue
                    }
                    // Non-sensitive flag whose assigned value may contain a header or nested secret (e.g. --header="Authorization: ...")
                    let redactedRHS = redactAssignedValue(rhs, depth: depth + 1)
                    if redactedRHS != rhs {
                        replacements.append((span.range, "\(lhs)=\(redactedRHS)"))
                        idx += 1
                        continue
                    }
                } else if isEnvironmentVariableIdentifier(lhs) && isSensitiveKeyName(lhs) {
                    replacements.append((span.range, "\(lhs)=***"))
                    idx += 1
                    continue
                }
            }

            // 4. Space-separated sensitive flag `--token <val>` / `-password <val>`
            if raw.hasPrefix("-"), raw != "--", !raw.contains("="), isSensitiveKeyName(raw) {
                if idx + 1 < spans.count, !spans[idx + 1].raw.hasPrefix("--") {
                    replacements.append((spans[idx + 1].range, "***"))
                    idx += 2
                    continue
                }
            }

            // 5. URL userinfo credentials `scheme://user:password@host`
            if raw.contains("://") && raw.contains("@"), let scrubbedURL = redactURLUserinfo(raw), scrubbedURL != raw {
                replacements.append((span.range, scrubbedURL))
                idx += 1
                continue
            }

            idx += 1
        }

        guard !replacements.isEmpty else { return text }
        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func redactAssignedValue(_ rhs: String, depth: Int) -> String {
        if let (quoteChar, inner) = unwrapOuterQuotes(rhs) {
            if let headerRedacted = redactSensitiveHeaderLine(inner) {
                return "\(quoteChar)\(headerRedacted)\(quoteChar)"
            }
            let innerRedacted = redactSegment(inner, depth: depth)
            return "\(quoteChar)\(innerRedacted)\(quoteChar)"
        }
        if let headerRedacted = redactSensitiveHeaderLine(rhs) {
            return headerRedacted
        }
        if rhs.contains("://") && rhs.contains("@"), let scrubbed = redactURLUserinfo(rhs) {
            return scrubbed
        }
        return rhs
    }

    private static func redactSensitiveHeaderLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
        guard sensitiveHeaderNames.contains(name) else { return nil }
        let originalPrefix = String(trimmed[...colonIdx])
        return "\(originalPrefix) ***"
    }

    private static func redactURLUserinfo(_ raw: String) -> String? {
        guard let schemeRange = raw.range(of: "://") else { return nil }
        let afterScheme = raw[schemeRange.upperBound...]
        let hostEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authority = afterScheme[..<hostEnd]
        guard let atIdx = authority.lastIndex(of: "@"),
              let colonIdx = authority[..<atIdx].firstIndex(of: ":") else {
            return nil
        }
        var out = raw
        let secretRange = authority.index(after: colonIdx)..<atIdx
        out.replaceSubrange(secretRange, with: "***")
        return out
    }

    internal static func isSensitiveKeyName(_ rawKey: String) -> Bool {
        var stripped = Substring(rawKey).drop(while: { $0 == "-" })
        // Support JVM-style `-Dapi.key=xxx` / `-Ddb.password=xxx`
        if stripped.hasPrefix("D"),
           stripped.count > 2,
           !stripped.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
            let withoutD = stripped.dropFirst()
            if checkNormalizedKeySegments(withoutD) {
                return true
            }
        }
        return checkNormalizedKeySegments(stripped)
    }

    private static func checkNormalizedKeySegments(_ keySlice: Substring) -> Bool {
        // Never treat 1- or 2-character short flags (-p, -k, -t, -s, -a) as sensitive names.
        guard keySlice.count >= 3 else { return false }
        let lower = keySlice.lowercased()
        let segments = lower.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
        guard !segments.isEmpty else { return false }

        for seg in segments {
            if exactSensitiveSegments.contains(seg) {
                return true
            }
            for suffix in compoundSensitiveSuffixes where seg.count > suffix.count && seg.hasSuffix(suffix) {
                return true
            }
        }
        return false
    }

    private static func isEnvironmentVariableIdentifier(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter || first == "_" else {
            return false
        }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func unwrapOuterQuotes(_ raw: String) -> (Character, String)? {
        guard raw.count >= 2, let first = raw.first, let last = raw.last,
              (first == "\"" || first == "'"), first == last else {
            return nil
        }
        let start = raw.index(after: raw.startIndex)
        let end = raw.index(before: raw.endIndex)
        return (first, String(raw[start..<end]))
    }

    private static func stripOuterQuotes(_ raw: String) -> String {
        if let (_, inner) = unwrapOuterQuotes(raw) {
            return inner
        }
        return raw
    }

    private static func scanTokenSpans(in text: String) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var idx = text.startIndex
        var tokenStart: String.Index?
        var activeQuote: Character?
        var escaped = false

        while idx < text.endIndex {
            let ch = text[idx]
            if let q = activeQuote {
                if escaped {
                    escaped = false
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else if ch == q {
                    activeQuote = nil
                }
                idx = text.index(after: idx)
                continue
            }

            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                if let start = tokenStart {
                    spans.append(TokenSpan(range: start..<idx, raw: String(text[start..<idx])))
                    tokenStart = nil
                }
            } else {
                if tokenStart == nil {
                    tokenStart = idx
                }
                if ch == "\"" || ch == "'" {
                    activeQuote = ch
                }
            }
            idx = text.index(after: idx)
        }

        if let start = tokenStart {
            spans.append(TokenSpan(range: start..<text.endIndex, raw: String(text[start..<text.endIndex])))
        }
        return spans
    }
}
