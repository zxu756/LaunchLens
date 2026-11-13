import AppKit
import Combine
import Foundation
import SwiftUI

public enum LaunchFilterTab: String, CaseIterable, Identifiable, Sendable {
    case all = "All services"
    case userAgents = "User agents"
    case orphans = "Orphan daemons"
    case globalAndSystem = "Global & system"
    case frozenVault = "Frozen vault"

    public var id: String { rawValue }

    @MainActor
    public func localizedTitle(_ localizer: AppLocalizer) -> String {
        switch self {
        case .all: return localizer.L("All services", "全部服务")
        case .userAgents: return localizer.L("User agents", "用户代理")
        case .orphans: return localizer.L("Orphan daemons", "孤儿进程")
        case .globalAndSystem: return localizer.L("Global & system", "全局与系统")
        case .frozenVault: return localizer.L("Frozen vault", "冻结保险库")
        }
    }
}

public enum LaunchStatusBanner: Equatable, Sendable {
    case frozenWithReclaim(label: String, reclaimed: String, shaPrefix: String)
    case frozenSaved(label: String, shaPrefix: String)
    case restored(label: String)
    case missingSnapshot(label: String)
    case orphanStopped(label: String)
    case orphanSignalFailed(pid: Int)
    case freezeError(FreezeError)
    case custom(en: String, zh: String)

    @MainActor
    public func localizedText(_ localizer: AppLocalizer) -> String {
        switch self {
        case let .frozenWithReclaim(label, reclaimed, shaPrefix):
            return localizer.L(
                "Frozen \(label) — \(reclaimed) reclaimed, SHA-256 \(shaPrefix) verified.",
                "已冻结 \(label) — 已释放 \(reclaimed) 内存，SHA-256 (\(shaPrefix)) 校验通过。"
            )
        case let .frozenSaved(label, shaPrefix):
            return localizer.L(
                "Frozen \(label) — SHA-256 verified snapshot saved (\(shaPrefix)).",
                "已冻结 \(label) — SHA-256 校验快照已归档 (\(shaPrefix))。"
            )
        case let .restored(label):
            return localizer.L(
                "Restored \(label) back to LaunchAgents and bootstrapped.",
                "已将 \(label) 恢复至 LaunchAgents 并重新引导加载。"
            )
        case let .missingSnapshot(label):
            return localizer.L(
                "No snapshot record found for \(label).",
                "未在快照保险库中找到 \(label) 的备份记录。"
            )
        case let .orphanStopped(label):
            return localizer.L(
                "Sent SIGTERM to orphan process \(label).",
                "已向孤儿守护进程 \(label) 发送 SIGTERM 终止信号。"
            )
        case let .orphanSignalFailed(pid):
            return localizer.L(
                "Could not signal PID \(pid); process may have already exited.",
                "无法向 PID \(pid) 发送信号，该进程可能已自行退出。"
            )
        case let .freezeError(err):
            return err.localizedMessage(localizer)
        case let .custom(en, zh):
            return localizer.L(en, zh)
        }
    }
}

@MainActor
public final class LaunchLensMonitor: ObservableObject {
    @Published public var snapshot: LaunchSnapshot
    @Published public var selectedFilter: LaunchFilterTab = .all
    @Published public var searchQuery: String = ""
    @Published public var showAppleSystem: Bool = false
    @Published public var statusBanner: LaunchStatusBanner?
    @Published public var statusMessage: String?
    @Published public var statusIsError: Bool = false

    public let isStaticPreview: Bool
    private let ledgerStore: FreezeLedgerStore
    private var refreshTimer: Timer?

    public init(
        snapshot: LaunchSnapshot? = nil,
        ledgerStore: FreezeLedgerStore = FreezeLedgerStore(),
        isStaticPreview: Bool = false,
        autoRefreshSeconds: TimeInterval? = 10.0
    ) {
        self.ledgerStore = ledgerStore
        self.isStaticPreview = isStaticPreview
        if let snapshot {
            self.snapshot = snapshot
        } else {
            self.snapshot = LaunchScanner.scanLiveHost(ledgerStore: ledgerStore)
        }

        if !isStaticPreview, let interval = autoRefreshSeconds, interval > 0 {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    public func refresh() {
        guard !isStaticPreview else { return }
        snapshot = LaunchScanner.scanLiveHost(ledgerStore: ledgerStore)
    }

    public func localizedStatusText(_ localizer: AppLocalizer) -> String? {
        if let statusBanner {
            return statusBanner.localizedText(localizer)
        }
        return statusMessage
    }

    public var filteredItems: [LaunchItem] {
        snapshot.items.filter { item in
            if !showAppleSystem && item.isAppleSystem {
                return false
            }
            switch selectedFilter {
            case .all:
                break
            case .userAgents:
                if item.domain != .userAgent { return false }
            case .orphans:
                if item.domain != .orphanDaemon { return false }
            case .globalAndSystem:
                if item.domain != .globalAgent && item.domain != .systemDaemon { return false }
            case .frozenVault:
                if !item.isFrozen { return false }
            }

            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return true }
            let portMatches = item.listeningPorts.contains { String($0).contains(trimmed) }
            return item.label.lowercased().contains(trimmed)
                || item.programCommand.lowercased().contains(trimmed)
                || (item.plistPath?.lowercased().contains(trimmed) ?? false)
                || portMatches
        }
    }

    public var menuBarSummaryText: String {
        ByteFormatter.memory(snapshot.totalBackgroundRSSBytes)
    }

    public var topMemoryConsumers: [LaunchItem] {
        Array(
            snapshot.items
                .filter { !$0.isAppleSystem && $0.rssBytes > 0 }
                .sorted { $0.rssBytes > $1.rssBytes }
                .prefix(5)
        )
    }

    public func freeze(_ item: LaunchItem) {
        do {
            let rec = try ledgerStore.freeze(item: item)
            let prefix = String(rec.sha256Hex.prefix(10))
            statusIsError = false
            statusBanner = .frozenSaved(label: rec.label, shaPrefix: prefix)
            statusMessage = statusBanner?.localizedText(.shared)
            refresh()
        } catch let freezeErr as FreezeError {
            statusIsError = true
            statusBanner = .freezeError(freezeErr)
            statusMessage = freezeErr.errorDescription
        } catch {
            statusIsError = true
            statusBanner = .custom(en: error.localizedDescription, zh: error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    public func restore(_ record: FreezeSnapshotRecord) {
        do {
            try ledgerStore.restore(recordID: record.id)
            statusIsError = false
            statusBanner = .restored(label: record.label)
            statusMessage = statusBanner?.localizedText(.shared)
            refresh()
        } catch let freezeErr as FreezeError {
            statusIsError = true
            statusBanner = .freezeError(freezeErr)
            statusMessage = freezeErr.errorDescription
        } catch {
            statusIsError = true
            statusBanner = .custom(en: error.localizedDescription, zh: error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    public func restoreByLabel(_ label: String) {
        guard let record = snapshot.frozenRecords.first(where: { $0.label == label }) else {
            statusIsError = true
            statusBanner = .missingSnapshot(label: label)
            statusMessage = statusBanner?.localizedText(.shared)
            return
        }
        restore(record)
    }

    public func terminateOrphan(_ item: LaunchItem) {
        guard item.domain == .orphanDaemon, let pid = item.pid else { return }
        if ledgerStore.terminateOrphan(pid: pid) {
            statusIsError = false
            statusBanner = .orphanStopped(label: item.label)
            statusMessage = statusBanner?.localizedText(.shared)
            refresh()
        } else {
            statusIsError = true
            statusBanner = .orphanSignalFailed(pid: pid)
            statusMessage = statusBanner?.localizedText(.shared)
        }
    }

    public static func displayPath(_ raw: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, raw.hasPrefix(home) {
            return "~" + raw.dropFirst(home.count)
        }
        return raw
    }

    // MARK: - Deterministic Marketing & Test Preview

    public static func preview() -> LaunchLensMonitor {
        let now = Date(timeIntervalSince1970: 1_794_556_800)
        let frozenRecord = FreezeSnapshotRecord(
            id: "snap-01",
            label: "com.updater.telemetry-helper",
            originalPlistPath: "~/Library/LaunchAgents/com.updater.telemetry-helper.plist",
            snapshotFilePath: "~/Library/Application Support/LaunchLens/Snapshots/com.updater.telemetry-helper-snap-01.plist",
            sha256Hex: "9f4c82b1e07a3d56c4189a02e7b11f88c04d6321a8e5b9704c2d193f80a65e12",
            frozenAt: now.addingTimeInterval(-7200),
            rssBytesAtFreeze: 432_013_312
        )

        let items: [LaunchItem] = [
            LaunchItem(
                id: "user::ai.local.whisper-voice-agent",
                label: "ai.local.whisper-voice-agent",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/ai.local.whisper-voice-agent.plist",
                programCommand: "/opt/homebrew/bin/whisper-server --model large-v3-turbo --port 8787",
                pid: 31402,
                rssBytes: 5_175_435_264, // 4.82 GB
                cpuPercent: 6.4,
                listeningPorts: [8787],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "user::io.ollama.runner",
                label: "io.ollama.runner",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/io.ollama.runner.plist",
                programCommand: "/opt/homebrew/opt/ollama/bin/ollama serve",
                pid: 19844,
                rssBytes: 2_834_678_415, // 2.64 GB
                cpuPercent: 1.8,
                listeningPorts: [11434],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "orphan::48210",
                label: "node / mcp-server-playwright (PID 48210)",
                domain: .orphanDaemon,
                plistPath: nil,
                programCommand: "node /opt/homebrew/lib/node_modules/@playwright/mcp/cli.js --port 9222",
                pid: 48210,
                rssBytes: 935_329_792, // 892 MB
                cpuPercent: 3.1,
                listeningPorts: [9222]
            ),
            LaunchItem(
                id: "system::com.docker.vmnetd",
                label: "com.docker.vmnetd",
                domain: .systemDaemon,
                plistPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist",
                programCommand: "/Library/PrivilegedHelperTools/com.docker.vmnetd",
                pid: 612,
                rssBytes: 679_477_248, // 648 MB
                cpuPercent: 0.5,
                listeningPorts: [],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "orphan::51094",
                label: "uvx / scholar-mcp (PID 51094)",
                domain: .orphanDaemon,
                plistPath: nil,
                programCommand: "python3 -m scholar_mcp.server --transport stdio",
                pid: 51094,
                rssBytes: 333_447_168, // 318 MB
                cpuPercent: 0.4,
                listeningPorts: []
            ),
            LaunchItem(
                id: "user::homebrew.mxcl.postgresql@16",
                label: "homebrew.mxcl.postgresql@16",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist",
                programCommand: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16",
                pid: 1409,
                rssBytes: 255_852_544, // 244 MB
                cpuPercent: 0.2,
                listeningPorts: [5432],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "global::org.pqrs.karabiner.agent",
                label: "org.pqrs.karabiner.agent",
                domain: .globalAgent,
                plistPath: "/Library/LaunchAgents/org.pqrs.karabiner.agent.plist",
                programCommand: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_grabber",
                pid: 988,
                rssBytes: 96_468_992, // 92 MB
                cpuPercent: 0.3,
                listeningPorts: [],
                runAtLoad: true,
                keepAlive: true
            ),
            LaunchItem(
                id: "frozen::com.updater.telemetry-helper",
                label: "com.updater.telemetry-helper",
                domain: .userAgent,
                plistPath: "~/Library/LaunchAgents/com.updater.telemetry-helper.plist",
                programCommand: "Frozen snapshot (com.updater.telemetry-helper.plist)",
                pid: nil,
                rssBytes: 0,
                cpuPercent: 0.0,
                listeningPorts: [],
                runAtLoad: false,
                keepAlive: false,
                isFrozen: true
            )
        ]

        let snap = LaunchSnapshot(capturedAt: now, items: items, frozenRecords: [frozenRecord])
        let monitor = LaunchLensMonitor(snapshot: snap, isStaticPreview: true, autoRefreshSeconds: nil)
        monitor.statusBanner = .frozenWithReclaim(
            label: "com.updater.telemetry-helper",
            reclaimed: "412 MB",
            shaPrefix: "9f4c82b1e0"
        )
        monitor.statusMessage = monitor.statusBanner?.localizedText(.shared)
        return monitor
    }
}

public enum ScreenshotExporter {
    @MainActor
    public static func exportMarketingScreenshots(
        to directory: URL,
        language: AppLanguage = .en
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = LaunchLensMonitor.preview()
        let localizer = AppLocalizer(fixedLanguage: language)
        let suffix = (language == .zhHans) ? "-zh" : ""

        let mainView = MainDashboardView(monitor: monitor, localizer: localizer)
            .environment(\.locale, language.locale)
            .frame(width: 1115, height: 735)
            .environment(\.colorScheme, .light)

        try renderPNG(view: mainView, to: directory.appendingPathComponent("screenshot-main\(suffix).png"))

        let popoverView = MenuBarPopoverView(
            monitor: monitor,
            localizer: localizer,
            onOpenDashboard: {},
            onQuit: {}
        )
        .environment(\.locale, language.locale)
        .frame(width: 420, height: 438)
        .padding(14)
        .background(Color(red: 0.925, green: 0.918, blue: 0.890))
        .environment(\.colorScheme, .light)

        try renderPNG(view: popoverView, to: directory.appendingPathComponent("screenshot-menubar\(suffix).png"))
    }

    @MainActor
    public static func renderPNG<V: View>(view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = true
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "LaunchLens.ScreenshotExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to rasterize SwiftUI view to 2x PNG"
            ])
        }
        try png.write(to: url, options: .atomic)
    }
}
