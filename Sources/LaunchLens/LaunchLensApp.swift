import AppKit
import Foundation
import LaunchLensCore
import SwiftUI

@main
struct LaunchLensApp: App {
    @StateObject private var monitor: LaunchLensMonitor
    @StateObject private var localizer: AppLocalizer
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let exportLang = AppLocalizer.resolveCLILanguage(from: args) ?? .en
            do {
                try MainActor.assumeIsolated {
                    try ScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
                }
                print("Exported 2x Retina screenshots (\(exportLang.rawValue)) to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Screenshot export failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if let idx = args.firstIndex(of: "--cli") {
            let subcmd = (idx + 1 < args.count && !args[idx + 1].hasPrefix("--")) ? args[idx + 1] : "list"
            MainActor.assumeIsolated {
                Self.runHeadlessCLI(subcmd: subcmd, localizer: AppLocalizer.shared)
            }
            exit(0)
        }

        _monitor = StateObject(wrappedValue: LaunchLensMonitor())
        _localizer = StateObject(wrappedValue: AppLocalizer.shared)
    }

    var body: some Scene {
        Window(localizer.L("LaunchLens — Background RAM & Freeze Ledger", "LaunchLens — 后台常驻内存与冻结账本"), id: "main") {
            MainDashboardView(monitor: monitor, localizer: localizer)
        }
        .defaultSize(width: 1115, height: 735)
        .commands {
            CommandMenu(localizer.L("Language", "语言")) {
                Button("切换语言 / Toggle Language") {
                    localizer.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        localizer.language = lang
                    } label: {
                        HStack {
                            Text("\(lang.displayName) (\(lang.badge))")
                            if localizer.language == lang {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarPopoverView(
                monitor: monitor,
                localizer: localizer,
                onOpenDashboard: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .frame(width: 420, height: 438)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "snowflake.circle")
                Text(monitor.menuBarSummaryText)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private static func runHeadlessCLI(subcmd: String, localizer: AppLocalizer) {
        let store = FreezeLedgerStore()
        let snap = LaunchScanner.scanLiveHost(ledgerStore: store)
        switch subcmd {
        case "orphans":
            let orphans = snap.orphanItems
            if orphans.isEmpty {
                print(localizer.L("No orphaned developer/AI daemons detected.", "未检测到脱离终端的开发/AI 孤儿守护进程。"))
                return
            }
            for item in orphans {
                let ports = item.listeningPorts.map { ":\($0)" }.joined(separator: ",")
                let mem = ByteFormatter.memory(item.rssBytes).padding(toLength: 10, withPad: " ", startingAt: 0)
                let pidCol = "PID \(item.pid ?? 0)".padding(toLength: 11, withPad: " ", startingAt: 0)
                print("\(mem)  \(pidCol)  \(item.label)  \(ports)")
            }
        case "frozen":
            if snap.frozenRecords.isEmpty {
                print(localizer.L("No frozen LaunchAgents in snapshot vault.", "快照保险库中暂无已冻结的 LaunchAgents。"))
                return
            }
            for rec in snap.frozenRecords {
                print("\(rec.label)  sha256:\(rec.sha256Hex.prefix(12))  \(LaunchLensMonitor.displayPath(rec.originalPlistPath))")
            }
        default:
            let nonApple = snap.items.filter { !$0.isAppleSystem }
            print(localizer.L(
                "Total Non-Apple Background RSS: \(ByteFormatter.memory(snap.totalBackgroundRSSBytes)) (\(snap.runningNonAppleCount) running, \(snap.orphanItems.count) orphans)",
                "非 Apple 后台常驻内存总计：\(ByteFormatter.memory(snap.totalBackgroundRSSBytes))（\(snap.runningNonAppleCount) 项运行中，\(snap.orphanItems.count) 个孤儿进程）"
            ))
            for item in nonApple.prefix(20) {
                let state = item.isFrozen
                    ? localizer.L("FROZEN", "已冻结")
                    : (item.pid.map { "PID \($0)" } ?? localizer.L("IDLE", "空闲"))
                print("\(ByteFormatter.memory(item.rssBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(state.padding(toLength: 10, withPad: " ", startingAt: 0))  [\(item.domain.localizedBadge(localizer))]  \(item.label)")
            }
        }
    }
}
