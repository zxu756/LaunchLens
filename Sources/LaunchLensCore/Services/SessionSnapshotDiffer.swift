import Foundation

public enum SnapshotServiceChangeReason: String, Codable, CaseIterable, Equatable, Sendable {
    case plistPathChanged
    case plistContentChanged
    case programChanged
    case scheduleChanged
}

public struct SnapshotServiceModification: Codable, Equatable, Sendable {
    public var before: SnapshotServiceEntry
    public var after: SnapshotServiceEntry
    public var reasons: [SnapshotServiceChangeReason]

    public init(
        before: SnapshotServiceEntry,
        after: SnapshotServiceEntry,
        reasons: [SnapshotServiceChangeReason]
    ) {
        self.before = before
        self.after = after
        self.reasons = reasons
    }

    public static func isDeterministicBefore(_ lhs: SnapshotServiceModification, _ rhs: SnapshotServiceModification) -> Bool {
        if SnapshotServiceEntry.isDeterministicBefore(lhs.after, rhs.after) {
            return true
        }
        if SnapshotServiceEntry.isDeterministicBefore(rhs.after, lhs.after) {
            return false
        }
        return lhs.before.plistPath < rhs.before.plistPath
    }
}

public struct SnapshotServiceDiffSection: Codable, Equatable, Sendable {
    public var added: [SnapshotServiceEntry]
    public var removed: [SnapshotServiceEntry]
    public var modified: [SnapshotServiceModification]

    public init(
        added: [SnapshotServiceEntry] = [],
        removed: [SnapshotServiceEntry] = [],
        modified: [SnapshotServiceModification] = []
    ) {
        self.added = added.sorted(by: SnapshotServiceEntry.isDeterministicBefore)
        self.removed = removed.sorted(by: SnapshotServiceEntry.isDeterministicBefore)
        self.modified = modified.sorted(by: SnapshotServiceModification.isDeterministicBefore)
    }
}

public struct SnapshotDiffSection<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var added: [Item]
    public var removed: [Item]

    public init(added: [Item] = [], removed: [Item] = []) {
        self.added = added
        self.removed = removed
    }
}

public struct SessionSnapshotDiffSummary: Codable, Equatable, Sendable {
    public var servicesAdded: Int
    public var servicesRemoved: Int
    public var servicesModified: Int
    public var listenersAdded: Int
    public var listenersRemoved: Int
    public var orphansAdded: Int
    public var orphansRemoved: Int

    public init(
        servicesAdded: Int = 0,
        servicesRemoved: Int = 0,
        servicesModified: Int = 0,
        listenersAdded: Int = 0,
        listenersRemoved: Int = 0,
        orphansAdded: Int = 0,
        orphansRemoved: Int = 0
    ) {
        self.servicesAdded = servicesAdded
        self.servicesRemoved = servicesRemoved
        self.servicesModified = servicesModified
        self.listenersAdded = listenersAdded
        self.listenersRemoved = listenersRemoved
        self.orphansAdded = orphansAdded
        self.orphansRemoved = orphansRemoved
    }
}

public struct SessionSnapshotDiff: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var beforeCapturedAt: Date
    public var afterCapturedAt: Date
    public var hasChanges: Bool
    public var hasAdditions: Bool
    public var hasModifications: Bool
    public var summary: SessionSnapshotDiffSummary
    public var services: SnapshotServiceDiffSection
    public var listeners: SnapshotDiffSection<SnapshotListenerEntry>
    public var orphans: SnapshotDiffSection<SnapshotOrphanEntry>

    public init(
        schemaVersion: Int = SessionSnapshot.currentSchemaVersion,
        beforeCapturedAt: Date,
        afterCapturedAt: Date,
        services: SnapshotServiceDiffSection,
        listeners: SnapshotDiffSection<SnapshotListenerEntry>,
        orphans: SnapshotDiffSection<SnapshotOrphanEntry>
    ) {
        self.schemaVersion = schemaVersion
        self.beforeCapturedAt = beforeCapturedAt
        self.afterCapturedAt = afterCapturedAt
        self.services = SnapshotServiceDiffSection(
            added: services.added,
            removed: services.removed,
            modified: services.modified
        )
        self.listeners = SnapshotDiffSection(
            added: listeners.added.sorted(by: SnapshotListenerEntry.isDeterministicBefore),
            removed: listeners.removed.sorted(by: SnapshotListenerEntry.isDeterministicBefore)
        )
        self.orphans = SnapshotDiffSection(
            added: orphans.added.sorted(by: SnapshotOrphanEntry.isDeterministicBefore),
            removed: orphans.removed.sorted(by: SnapshotOrphanEntry.isDeterministicBefore)
        )
        self.summary = SessionSnapshotDiffSummary(
            servicesAdded: self.services.added.count,
            servicesRemoved: self.services.removed.count,
            servicesModified: self.services.modified.count,
            listenersAdded: self.listeners.added.count,
            listenersRemoved: self.listeners.removed.count,
            orphansAdded: self.orphans.added.count,
            orphansRemoved: self.orphans.removed.count
        )
        self.hasAdditions = !self.services.added.isEmpty || !self.listeners.added.isEmpty || !self.orphans.added.isEmpty
        self.hasModifications = !self.services.modified.isEmpty
        self.hasChanges = self.hasAdditions
            || self.hasModifications
            || !self.services.removed.isEmpty
            || !self.listeners.removed.isEmpty
            || !self.orphans.removed.isEmpty
    }
}

public enum SessionSnapshotDiffer {

    /// Pure offline comparison between two `SessionSnapshot` values (never accesses host OS state).
    public static func diff(before: SessionSnapshot, after: SessionSnapshot) -> SessionSnapshotDiff {
        let servicesSection = diffServices(before: before.services, after: after.services)
        let listenersSection = diffKeyedItems(
            before: before.listeners,
            after: after.listeners,
            keyOf: \.identityKey,
            sortBy: SnapshotListenerEntry.isDeterministicBefore
        )
        let orphansSection = diffKeyedItems(
            before: before.orphans,
            after: after.orphans,
            keyOf: \.identityKey,
            sortBy: SnapshotOrphanEntry.isDeterministicBefore
        )

        return SessionSnapshotDiff(
            beforeCapturedAt: before.capturedAt,
            afterCapturedAt: after.capturedAt,
            services: servicesSection,
            listeners: listenersSection,
            orphans: orphansSection
        )
    }

    public static func encodePrettyJSON(_ diff: SessionSnapshotDiff) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(diff)
    }

    // MARK: - Category Diffing

    private static func serviceIdentityKey(_ entry: SnapshotServiceEntry) -> String {
        let canonicalPlist = SnapshotPathCanonicalizer.canonicalizePath(entry.plistPath)
        return "\(entry.domainScope.rawValue)::\(entry.label)::\(canonicalPlist)"
    }

    private static func serviceSlotKey(_ entry: SnapshotServiceEntry) -> String {
        "\(entry.domainScope.rawValue)::\(entry.label)"
    }

    private static func diffServices(
        before: [SnapshotServiceEntry],
        after: [SnapshotServiceEntry]
    ) -> SnapshotServiceDiffSection {
        let normalizedBefore = before.map { normalizeService($0) }.sorted(by: SnapshotServiceEntry.isDeterministicBefore)
        let normalizedAfter = after.map { normalizeService($0) }.sorted(by: SnapshotServiceEntry.isDeterministicBefore)

        var beforeByIdentity: [String: [SnapshotServiceEntry]] = [:]
        for item in normalizedBefore {
            beforeByIdentity[serviceIdentityKey(item), default: []].append(item)
        }
        var afterByIdentity: [String: [SnapshotServiceEntry]] = [:]
        for item in normalizedAfter {
            afterByIdentity[serviceIdentityKey(item), default: []].append(item)
        }

        let allIdentityKeys = Set(beforeByIdentity.keys).union(afterByIdentity.keys).sorted()
        var unmatchedBefore: [SnapshotServiceEntry] = []
        var unmatchedAfter: [SnapshotServiceEntry] = []
        var modified: [SnapshotServiceModification] = []

        // Pass 1: Exact `(domainScope, label, canonicalPlistPath)` matches (PID/exitStatus ignored).
        for key in allIdentityKeys {
            let bList = beforeByIdentity[key] ?? []
            let aList = afterByIdentity[key] ?? []
            let pairCount = min(bList.count, aList.count)
            for idx in 0..<pairCount {
                let reasons = modificationReasons(before: bList[idx], after: aList[idx])
                if !reasons.isEmpty {
                    modified.append(SnapshotServiceModification(before: bList[idx], after: aList[idx], reasons: reasons))
                }
            }
            if bList.count > pairCount {
                unmatchedBefore.append(contentsOf: bList[pairCount...])
            }
            if aList.count > pairCount {
                unmatchedAfter.append(contentsOf: aList[pairCount...])
            }
        }

        // Pass 2: Same `(domainScope, label)` whose `plistPath` changed -> report as `modified` rather than -1/+1.
        var beforeBySlot: [String: [SnapshotServiceEntry]] = [:]
        for item in unmatchedBefore {
            beforeBySlot[serviceSlotKey(item), default: []].append(item)
        }
        var afterBySlot: [String: [SnapshotServiceEntry]] = [:]
        for item in unmatchedAfter {
            afterBySlot[serviceSlotKey(item), default: []].append(item)
        }

        var added: [SnapshotServiceEntry] = []
        var removed: [SnapshotServiceEntry] = []
        let allSlots = Set(beforeBySlot.keys).union(afterBySlot.keys).sorted()

        for slot in allSlots {
            let bList = (beforeBySlot[slot] ?? []).sorted(by: SnapshotServiceEntry.isDeterministicBefore)
            let aList = (afterBySlot[slot] ?? []).sorted(by: SnapshotServiceEntry.isDeterministicBefore)
            let pairCount = min(bList.count, aList.count)
            for idx in 0..<pairCount {
                let reasons = modificationReasons(before: bList[idx], after: aList[idx])
                modified.append(
                    SnapshotServiceModification(
                        before: bList[idx],
                        after: aList[idx],
                        reasons: reasons.isEmpty ? [.plistPathChanged] : reasons
                    )
                )
            }
            if bList.count > pairCount {
                removed.append(contentsOf: bList[pairCount...])
            }
            if aList.count > pairCount {
                added.append(contentsOf: aList[pairCount...])
            }
        }

        return SnapshotServiceDiffSection(added: added, removed: removed, modified: modified)
    }

    private static func normalizeService(_ entry: SnapshotServiceEntry) -> SnapshotServiceEntry {
        var copy = entry
        copy.plistPath = SnapshotPathCanonicalizer.canonicalizePath(entry.plistPath)
        return copy
    }

    private static func modificationReasons(
        before: SnapshotServiceEntry,
        after: SnapshotServiceEntry
    ) -> [SnapshotServiceChangeReason] {
        var reasons: [SnapshotServiceChangeReason] = []
        if before.plistPath != after.plistPath {
            reasons.append(.plistPathChanged)
        }
        if before.plistSHA256 != after.plistSHA256 {
            reasons.append(.plistContentChanged)
        }
        if before.programCommand != after.programCommand {
            reasons.append(.programChanged)
        }
        if before.runAtLoad != after.runAtLoad || before.keepAlive != after.keepAlive {
            reasons.append(.scheduleChanged)
        }
        return reasons
    }

    private static func diffKeyedItems<Item: Codable & Equatable & Sendable>(
        before: [Item],
        after: [Item],
        keyOf: (Item) -> String,
        sortBy: (Item, Item) -> Bool
    ) -> SnapshotDiffSection<Item> {
        let sortedBefore = before.sorted(by: sortBy)
        let sortedAfter = after.sorted(by: sortBy)

        var beforeGroups: [String: [Item]] = [:]
        for item in sortedBefore {
            beforeGroups[keyOf(item), default: []].append(item)
        }
        var afterGroups: [String: [Item]] = [:]
        for item in sortedAfter {
            afterGroups[keyOf(item), default: []].append(item)
        }

        var added: [Item] = []
        var removed: [Item] = []
        let allKeys = Set(beforeGroups.keys).union(afterGroups.keys).sorted()

        for key in allKeys {
            let bList = beforeGroups[key] ?? []
            let aList = afterGroups[key] ?? []
            let common = min(bList.count, aList.count)
            if bList.count > common {
                removed.append(contentsOf: bList[common...])
            }
            if aList.count > common {
                added.append(contentsOf: aList[common...])
            }
        }

        return SnapshotDiffSection(
            added: added.sorted(by: sortBy),
            removed: removed.sorted(by: sortBy)
        )
    }
}
