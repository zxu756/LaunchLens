import AppKit
import Foundation
import LaunchLensCore
import SwiftUI

@main
struct LaunchLensApp: App {
    @StateObject private var monitor: LaunchLensMonitor
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            do {
                try MainActor.assumeIsolated {
                    try ScreenshotExporter.exportMarketingScreenshots(to: outURL)
                }
                print("Exported 2x Retina screenshots to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Screenshot export failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if let idx = args.firstIndex(of: "--cli") {
            let subcmd = (idx + 1 < args.count) ? args[idx + 1] : "list"
            Self.runHeadlessCLI(subcmd: subcmd)
            exit(0)
        }

        _monitor = StateObject(wrappedValue: LaunchLensMonitor())
    }

    var body: some Scene {
        Window("LaunchLens", id: "main") {
            MainDashboardView(monitor: monitor)
        }
        .defaultSize(width: 980, height: 730)

        MenuBarExtra {
            MenuBarPopoverView(
                monitor: monitor,
                onOpenDashboard: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .frame(width: 380, height: 422)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "snowflake.circle")
                Text(monitor.menuBarSummaryText)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static func runHeadlessCLI(subcmd: String) {
        let store = FreezeLedgerStore()
        let snap = LaunchScanner.scanLiveHost(ledgerStore: store)
        switch subcmd {
        case "orphans":
            let orphans = snap.orphanItems
            if orphans.isEmpty {
                print("No orphaned developer/AI daemons detected.")
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
                print("No frozen LaunchAgents in snapshot vault.")
                return
            }
            for rec in snap.frozenRecords {
                print("\(rec.label)  sha256:\(rec.sha256Hex.prefix(12))  \(LaunchLensMonitor.displayPath(rec.originalPlistPath))")
            }
        default:
            let nonApple = snap.items.filter { !$0.isAppleSystem }
            print("Total Non-Apple Background RSS: \(ByteFormatter.memory(snap.totalBackgroundRSSBytes)) (\(snap.runningNonAppleCount) running, \(snap.orphanItems.count) orphans)")
            for item in nonApple.prefix(20) {
                let state = item.isFrozen ? "FROZEN" : (item.pid.map { "PID \($0)" } ?? "IDLE")
                print("\(ByteFormatter.memory(item.rssBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(state.padding(toLength: 10, withPad: " ", startingAt: 0))  [\(item.domain.shortBadge)]  \(item.label)")
            }
        }
    }
}
