import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var monitor: LaunchLensMonitor
    public var onOpenDashboard: () -> Void
    public var onQuit: () -> Void

    public init(
        monitor: LaunchLensMonitor,
        onOpenDashboard: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LaunchLens")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerTheme.chalk)
                    Text("\(monitor.snapshot.runningNonAppleCount) running, \(monitor.snapshot.orphanItems.count) orphans")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerTheme.mist)
                }
                Spacer()
                Text(ByteFormatter.memory(monitor.snapshot.totalBackgroundRSSBytes))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(LedgerTheme.glacier)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(LedgerTheme.surface)

            Divider().overlay(LedgerTheme.hairline)

            // Top 5 Memory Consumers
            VStack(alignment: .leading, spacing: 0) {
                Text("Top resident memory consumers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerTheme.mist)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ForEach(monitor.topMemoryConsumers) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.domain == .orphanDaemon ? LedgerTheme.amber : LedgerTheme.glacier)
                            .frame(width: 6, height: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LedgerTheme.chalk)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.domain.shortBadge)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LedgerTheme.mist)
                                if !item.listeningPorts.isEmpty {
                                    Text(item.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(LedgerTheme.emerald)
                                }
                            }
                        }

                        Spacer()

                        Text(ByteFormatter.memory(item.rssBytes))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(item.rssBytes >= 1_073_741_824 ? LedgerTheme.amber : LedgerTheme.chalk)

                        quickActionButton(for: item)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    Divider().overlay(LedgerTheme.hairline.opacity(0.6))
                }
            }

            // Frozen Snapshot Summary
            if let latest = monitor.snapshot.frozenRecords.first {
                HStack(spacing: 8) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerTheme.glacier)
                    Text("\(monitor.snapshot.frozenRecords.count) frozen (\(latest.label))")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerTheme.mist)
                        .lineLimit(1)
                    Spacer()
                    Button(action: { monitor.restore(latest) }) {
                        Text("Restore")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerTheme.emerald)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(LedgerTheme.surface.opacity(0.55))
                Divider().overlay(LedgerTheme.hairline)
            }

            Spacer(minLength: 0)

            // Footer Actions
            HStack(spacing: 8) {
                Button(action: onOpenDashboard) {
                    Text("Open ledger")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LedgerTheme.chalk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(LedgerTheme.elevated))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: { monitor.refresh() }) {
                    Text("Rescan")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.mist)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.mist)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(LedgerTheme.surface)
        }
        .background(LedgerTheme.canvas)
    }

    @ViewBuilder
    private func quickActionButton(for item: LaunchItem) -> some View {
        if item.domain == .userAgent && !item.isAppleSystem {
            Button(action: { monitor.freeze(item) }) {
                Text("Freeze")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LedgerTheme.glacier)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(LedgerTheme.glacier.opacity(0.15)))
            }
            .buttonStyle(.plain)
        } else if item.domain == .orphanDaemon {
            Button(action: { monitor.terminateOrphan(item) }) {
                Text("Stop")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LedgerTheme.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(LedgerTheme.amber.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
    }
}
