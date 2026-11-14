import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var monitor: LaunchLensMonitor
    @ObservedObject var localizer: AppLocalizer
    public var onOpenDashboard: () -> Void
    public var onQuit: () -> Void

    @MainActor
    public init(
        monitor: LaunchLensMonitor,
        localizer: AppLocalizer? = nil,
        onOpenDashboard: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.localizer = localizer ?? .shared
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LedgerTheme.cobalt)
                        Text("LaunchLens")
                            .font(.system(size: 13.5, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(LedgerTheme.ink)
                        if monitor.isStaticPreview {
                            Text(localizer.L("DEMO", "演示"))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(LedgerTheme.terracotta)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(LedgerTheme.terracotta.opacity(0.12)))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(LedgerTheme.terracotta.opacity(0.42), lineWidth: 1))
                        }
                    }
                    Spacer()
                    LanguageTogglePill(localizer: localizer, compact: true)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(localizer.L(
                        "\(monitor.snapshot.runningNonAppleCount) active · \(monitor.snapshot.orphanItems.count) orphan daemons",
                        "\(monitor.snapshot.runningNonAppleCount) 项活跃 · \(monitor.snapshot.orphanItems.count) 个孤儿进程"
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LedgerTheme.muted)
                    .fixedSize(horizontal: true, vertical: false)

                    Spacer()

                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(ByteFormatter.memory(monitor.snapshot.totalBackgroundRSSBytes))
                            .font(.system(size: 18, weight: .bold))
                            .tracking(-0.4)
                            .monospacedDigit()
                            .foregroundStyle(LedgerTheme.ink)
                        Text(localizer.L("resident RAM", "后台常驻"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(LedgerTheme.subtle)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(LedgerTheme.canvas)

            Rectangle().fill(LedgerTheme.hairline).frame(height: 1)

            if monitor.integrityReport.hasIssues {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LedgerTheme.terracotta)
                    Text(localizer.L("Interrupted ledger / orphan backup", "发现中断事务或孤儿备份"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LedgerTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    if monitor.integrityReport.corruptedLedgerError == nil {
                        Button(action: { monitor.requestRepairIntegrity() }) {
                            Text(localizer.L("Repair / Recover", "修复 / 恢复"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(LedgerTheme.terracotta))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6.5)
                .background(LedgerTheme.terracotta.opacity(0.10))
                Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)
            }

            // Top 5 Memory Consumers
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(localizer.L("Top memory consumers", "高内存占用后台进程"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerTheme.muted)
                    Spacer()
                    Text(localizer.L("RSS / Action", "内存 / 操作"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LedgerTheme.subtle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(LedgerTheme.tinted)

                Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)

                ForEach(monitor.topMemoryConsumers) { item in
                    let isOrphan = item.domain == .orphanDaemon
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isOrphan ? LedgerTheme.terracotta : LedgerTheme.cobalt)
                            .frame(width: 6.5, height: 6.5)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(LedgerTheme.ink)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.domain.localizedBadge(localizer))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(isOrphan ? LedgerTheme.terracotta : LedgerTheme.muted)
                                if !item.listeningPorts.isEmpty {
                                    Text(item.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(LedgerTheme.forest)
                                }
                            }
                        }

                        Spacer(minLength: 4)

                        Text(ByteFormatter.memory(item.rssBytes))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(isOrphan || item.rssBytes >= 1_073_741_824 ? LedgerTheme.terracotta : LedgerTheme.ink)
                            .fixedSize(horizontal: true, vertical: false)

                        quickActionButton(for: item)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
                    Text(localizer.L(
                        "\(monitor.snapshot.frozenRecords.count) frozen · \(latest.label)",
                        "已冻结 \(monitor.snapshot.frozenRecords.count) 项 · \(latest.label)"
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LedgerTheme.muted)
                    .lineLimit(1)
                    Spacer()
                    Button(action: { monitor.requestRestore(latest) }) {
                        Text(localizer.L("Restore", "恢复"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerTheme.forest)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8.5)
                .background(LedgerTheme.canvas)
                Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
            }

            Spacer(minLength: 0)

            // Footer Actions
            HStack(spacing: 8) {
                Button(action: onOpenDashboard) {
                    Text(localizer.L("Open ledger", "打开完整账本"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.ink))
                }
                .buttonStyle(.plain)

                Button(action: { monitor.refresh() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(localizer.L("Rescan", "重新扫描"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(LedgerTheme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.sheet))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text(localizer.L("Quit", "退出"))
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10.5)
            .background(LedgerTheme.canvas)
        }
        .background(LedgerTheme.sheet)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.locale, localizer.language.locale)
        .preferredColorScheme(.light)
        .sheet(item: $monitor.pendingConfirmation) { action in
            ActionConfirmationSheetView(monitor: monitor, localizer: localizer, action: action)
        }
    }

    @ViewBuilder
    private func quickActionButton(for item: LaunchItem) -> some View {
        if item.domain == .userAgent && !item.isAppleSystem {
            Button(action: { monitor.requestFreeze(item) }) {
                Text(localizer.L("Freeze", "冻结"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LedgerTheme.cobalt)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LedgerTheme.cobalt.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(LedgerTheme.cobalt.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else if item.domain == .orphanDaemon {
            Text(localizer.L("Read-only", "只读"))
                .font(.system(size: 10))
                .foregroundStyle(LedgerTheme.subtle)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
