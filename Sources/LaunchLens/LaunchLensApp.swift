import AppKit
import Foundation
import LaunchLensCore
import SwiftUI

@main
enum LaunchLensEntrypoint {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--export-screenshots") {
            let code = MainActor.assumeIsolated {
                CLIRunner.runExportScreenshots(arguments: args)
            }
            Foundation.exit(code)
        }

        if CLIRunner.shouldRouteToCLI(arguments: args) {
            let code = MainActor.assumeIsolated {
                CLIRunner.run(arguments: args)
            }
            Foundation.exit(code)
        }

        LaunchLensGUIApp.main()
    }
}

struct LaunchLensGUIApp: App {
    @StateObject private var monitor: LaunchLensMonitor
    @StateObject private var localizer: AppLocalizer
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments
        if args.contains("--demo") {
            _monitor = StateObject(wrappedValue: LaunchLensMonitor.preview())
        } else {
            _monitor = StateObject(wrappedValue: LaunchLensMonitor())
        }
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
}
