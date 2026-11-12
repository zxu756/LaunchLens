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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LedgerTheme.cobalt)
                        Text("LaunchLens")
                            .font(.system(size: 13.5, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(LedgerTheme.ink)
                    }
                    Text("\(monitor.snapshot.runningNonAppleCount) active · \(monitor.snapshot.orphanItems.count) orphan daemons")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteFormatter.memory(monitor.snapshot.totalBackgroundRSSBytes))
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.4)
                        .monospacedDigit()
                        .foregroundStyle(LedgerTheme.ink)
                    Text("resident RAM")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LedgerTheme.subtle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(LedgerTheme.canvas)

            Rectangle().fill(LedgerTheme.hairline).frame(height: 1)

            // Top 5 Memory Consumers
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Top memory consumers")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerTheme.muted)
                    Spacer()
                    Text("RSS / Action")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LedgerTheme.subtle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(LedgerTheme.tinted)

                Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)

                ForEach(monitor.topMemoryConsumers) { item in
                    let isOrphan = item.domain == .orphanDaemon
                    HStack(spacing: 9) {
                        Circle()
                            .fill(isOrphan ? LedgerTheme.terracotta : LedgerTheme.cobalt)
                            .frame(width: 6.5, height: 6.5)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerTheme.ink)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.domain.shortBadge)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(isOrphan ? LedgerTheme.terracotta : LedgerTheme.muted)
                                if !item.listeningPorts.isEmpty {
                                    Text(item.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(LedgerTheme.forest)
                                }
                            }
                        }

                        Spacer()

                        Text(ByteFormatter.memory(item.rssBytes))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(isOrphan || item.rssBytes >= 1_073_741_824 ? LedgerTheme.terracotta : LedgerTheme.ink)

                        quickActionButton(for: item)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8.5)
                    .background(LedgerTheme.sheet)

                    Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)
                }
            }

            // Frozen Snapshot Summary
            if let latest = monitor.snapshot.frozenRecords.first {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerTheme.cobalt)
                    Text("\(monitor.snapshot.frozenRecords.count) frozen · \(latest.label)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Button(action: { monitor.restore(latest) }) {
                        Text("Restore")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerTheme.forest)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(LedgerTheme.canvas)
                Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
            }

            Spacer(minLength: 0)

            // Footer Actions
            HStack(spacing: 8) {
                Button(action: onOpenDashboard) {
                    Text("Open ledger")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.ink))
                }
                .buttonStyle(.plain)

                Button(action: { monitor.refresh() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Rescan")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(LedgerTheme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.sheet))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(LedgerTheme.canvas)
        }
        .background(LedgerTheme.sheet)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func quickActionButton(for item: LaunchItem) -> some View {
        if item.domain == .userAgent && !item.isAppleSystem {
            Button(action: { monitor.freeze(item) }) {
                Text("Freeze")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LedgerTheme.cobalt)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LedgerTheme.cobalt.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(LedgerTheme.cobalt.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else if item.domain == .orphanDaemon {
            Button(action: { monitor.terminateOrphan(item) }) {
                Text("Stop")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LedgerTheme.terracotta)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LedgerTheme.terracotta.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(LedgerTheme.terracotta.opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}
