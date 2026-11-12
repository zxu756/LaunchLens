import SwiftUI

enum LedgerTheme {
    static let canvas = Color(red: 0.047, green: 0.067, blue: 0.090)      // #0C1117
    static let surface = Color(red: 0.075, green: 0.106, blue: 0.141)     // #131B24
    static let elevated = Color(red: 0.102, green: 0.141, blue: 0.188)    // #1A2430
    static let hairline = Color(red: 0.137, green: 0.188, blue: 0.251)    // #233040
    static let chalk = Color(red: 0.933, green: 0.957, blue: 0.980)       // #EEF4FA
    static let mist = Color(red: 0.549, green: 0.627, blue: 0.710)        // #8CA0B5
    static let glacier = Color(red: 0.220, green: 0.741, blue: 0.973)     // #38BDF8
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)       // #F59E0B
    static let emerald = Color(red: 0.196, green: 0.827, blue: 0.596)     // #32D398
}

public struct MainDashboardView: View {
    @ObservedObject var monitor: LaunchLensMonitor

    public init(monitor: LaunchLensMonitor) {
        self.monitor = monitor
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().overlay(LedgerTheme.hairline)
            filterBarSection
            Divider().overlay(LedgerTheme.hairline)
            ledgerTableHeader
            Divider().overlay(LedgerTheme.hairline)
            ledgerRowsSection
            if !monitor.snapshot.frozenRecords.isEmpty {
                Divider().overlay(LedgerTheme.hairline)
                frozenVaultDrawer
            }
        }
        .background(LedgerTheme.canvas)
        .foregroundStyle(LedgerTheme.chalk)
    }

    // MARK: - Header & Signature Unified Memory Allocation Strip

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LedgerTheme.glacier.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(LedgerTheme.glacier.opacity(0.45), lineWidth: 1)
                            )
                            .frame(width: 28, height: 28)
                        Image(systemName: "snowflake.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LedgerTheme.glacier)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LaunchLens")
                            .font(.system(size: 17, weight: .semibold, design: .default))
                            .foregroundStyle(LedgerTheme.chalk)
                        Text("Persistent LaunchAgents, orphan daemons, and reversible plist snapshots")
                            .font(.system(size: 12))
                            .foregroundStyle(LedgerTheme.mist)
                    }
                }

                Spacer()

                HStack(spacing: 18) {
                    metricPair(
                        value: ByteFormatter.memory(monitor.snapshot.totalBackgroundRSSBytes),
                        label: "Background RSS",
                        accent: LedgerTheme.chalk
                    )
                    metricPair(
                        value: "\(monitor.snapshot.runningNonAppleCount)",
                        label: "Running services",
                        accent: LedgerTheme.glacier
                    )
                    metricPair(
                        value: ByteFormatter.memory(monitor.snapshot.orphanRSSBytes),
                        label: "\(monitor.snapshot.orphanItems.count) orphan daemons",
                        accent: monitor.snapshot.orphanItems.isEmpty ? LedgerTheme.mist : LedgerTheme.amber
                    )
                    metricPair(
                        value: "\(monitor.snapshot.totalListeningPortCount)",
                        label: "Listening ports",
                        accent: LedgerTheme.emerald
                    )

                    Button(action: { monitor.refresh() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Rescan")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(LedgerTheme.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            memoryAllocationStrip
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(LedgerTheme.surface)
    }

    private func metricPair(value: String, label: String, accent: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(LedgerTheme.mist)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var memoryAllocationStrip: some View {
        let total = max(1, Double(monitor.snapshot.totalBackgroundRSSBytes))
        let top4 = Array(monitor.topMemoryConsumers.prefix(4))
        let topSum = top4.map(\.rssBytes).reduce(0, +)
        let remainder = max(0, monitor.snapshot.totalBackgroundRSSBytes - topSum)
        let palette: [Color] = [
            LedgerTheme.glacier,
            Color(red: 0.38, green: 0.56, blue: 0.98),
            LedgerTheme.amber,
            Color(red: 0.66, green: 0.55, blue: 0.98)
        ]

        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                let fullW = max(1, geo.size.width)
                HStack(spacing: 2) {
                    ForEach(Array(top4.enumerated()), id: \.element.id) { idx, item in
                        let fraction = CGFloat(Double(item.rssBytes) / total)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(item.domain == .orphanDaemon ? LedgerTheme.amber : palette[idx % palette.count])
                            .frame(width: max(6, fullW * fraction - 2))
                    }
                    if remainder > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LedgerTheme.hairline)
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 16) {
                ForEach(Array(top4.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.domain == .orphanDaemon ? LedgerTheme.amber : palette[idx % palette.count])
                            .frame(width: 7, height: 7)
                        Text(shortLegendName(item.label))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LedgerTheme.chalk.opacity(0.9))
                            .lineLimit(1)
                        Text(ByteFormatter.memory(item.rssBytes))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LedgerTheme.mist)
                    }
                }
                if remainder > 0 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(LedgerTheme.hairline)
                            .frame(width: 7, height: 7)
                        Text("Other services \(ByteFormatter.memory(remainder))")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerTheme.mist)
                    }
                }
                Spacer()
            }
        }
    }

    private func shortLegendName(_ label: String) -> String {
        if label.count <= 26 { return label }
        return String(label.prefix(24)) + "…"
    }

    // MARK: - Filter & Search Bar

    private var filterBarSection: some View {
        HStack(spacing: 8) {
            ForEach(LaunchFilterTab.allCases) { tab in
                let active = monitor.selectedFilter == tab
                Button(action: { monitor.selectedFilter = tab }) {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                        Text(verbatim: "\(countForTab(tab))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(active ? LedgerTheme.glacier : LedgerTheme.mist)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(active ? LedgerTheme.glacier.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(active ? LedgerTheme.glacier.opacity(0.45) : LedgerTheme.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button(action: { monitor.showAppleSystem.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: monitor.showAppleSystem ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(monitor.showAppleSystem ? LedgerTheme.glacier : LedgerTheme.mist)
                    Text("Apple services")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.mist)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerTheme.mist)
                if monitor.isStaticPreview {
                    Text(monitor.searchQuery.isEmpty ? "Filter label, command, or port" : monitor.searchQuery)
                        .font(.system(size: 12))
                        .foregroundStyle(monitor.searchQuery.isEmpty ? LedgerTheme.mist.opacity(0.75) : LedgerTheme.chalk)
                        .frame(width: 165, alignment: .leading)
                } else {
                    TextField("Filter label, command, or port", text: $monitor.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.chalk)
                        .frame(width: 165)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LedgerTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(LedgerTheme.canvas)
    }

    private func countForTab(_ tab: LaunchFilterTab) -> Int {
        let base = monitor.snapshot.items.filter { monitor.showAppleSystem || !$0.isAppleSystem }
        switch tab {
        case .all: return base.count
        case .userAgents: return base.filter { $0.domain == .userAgent }.count
        case .orphans: return base.filter { $0.domain == .orphanDaemon }.count
        case .globalAndSystem: return base.filter { $0.domain == .globalAgent || $0.domain == .systemDaemon }.count
        case .frozenVault: return base.filter(\.isFrozen).count
        }
    }

    // MARK: - Ledger Table

    private var ledgerTableHeader: some View {
        HStack(spacing: 12) {
            Text("Service & command")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Domain")
                .frame(width: 112, alignment: .leading)
            Text("PID / Ports")
                .frame(width: 126, alignment: .leading)
            Text("Resident memory")
                .frame(width: 150, alignment: .trailing)
            Text("Action")
                .frame(width: 112, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(LedgerTheme.mist)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(LedgerTheme.surface.opacity(0.65))
    }

    @ViewBuilder
    private var ledgerRowsSection: some View {
        let maxRSS = max(1, monitor.filteredItems.map(\.rssBytes).max() ?? 1)
        if monitor.isStaticPreview {
            VStack(spacing: 0) {
                ledgerRowsListContent(maxRSS: maxRSS)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ledgerRowsListContent(maxRSS: maxRSS)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func ledgerRowsListContent(maxRSS: Int64) -> some View {
        if let banner = monitor.statusMessage {
            HStack(spacing: 8) {
                Image(systemName: monitor.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(monitor.statusIsError ? LedgerTheme.amber : LedgerTheme.glacier)
                Text(banner)
                    .font(.system(size: 12))
                    .foregroundStyle(LedgerTheme.chalk)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                (monitor.statusIsError ? LedgerTheme.amber : LedgerTheme.glacier).opacity(0.10)
            )
            Divider().overlay(LedgerTheme.hairline)
        }

        if monitor.filteredItems.isEmpty {
            VStack(spacing: 6) {
                Text("No matching background services")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LedgerTheme.chalk)
                Text("Adjust the active filter pill or clear the search query to see all services.")
                    .font(.system(size: 12))
                    .foregroundStyle(LedgerTheme.mist)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            ForEach(monitor.filteredItems) { item in
                ledgerRow(item, maxRSS: maxRSS)
                Divider().overlay(LedgerTheme.hairline.opacity(0.65))
            }
        }
    }

    private func ledgerRow(_ item: LaunchItem, maxRSS: Int64) -> some View {
        let ratio = CGFloat(Double(item.rssBytes) / Double(maxRSS))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(item.isFrozen ? LedgerTheme.glacier : (item.isRunning ? LedgerTheme.emerald : LedgerTheme.mist.opacity(0.4)))
                        .frame(width: 7, height: 7)
                    Text(item.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.isFrozen ? LedgerTheme.mist : LedgerTheme.chalk)
                        .lineLimit(1)
                    if item.keepAlive {
                        Text("KeepAlive")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LedgerTheme.mist)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(LedgerTheme.elevated))
                    }
                }
                Text(LaunchLensMonitor.displayPath(item.programCommand))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LedgerTheme.mist)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Domain Pill
            HStack(spacing: 5) {
                Text(item.isFrozen ? "Frozen snapshot" : item.domain.shortBadge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.isFrozen ? LedgerTheme.glacier : item.domain.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill((item.isFrozen ? LedgerTheme.glacier : item.domain.color).opacity(0.14))
                    )
            }
            .frame(width: 112, alignment: .leading)

            // PID & Listening Ports
            VStack(alignment: .leading, spacing: 2) {
                if let pid = item.pid {
                    Text(verbatim: "PID \(pid)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LedgerTheme.chalk)
                } else {
                    Text(item.isFrozen ? "Unloaded" : "Idle")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.mist)
                }
                if !item.listeningPorts.isEmpty {
                    Text(item.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LedgerTheme.emerald)
                        .lineLimit(1)
                }
            }
            .frame(width: 126, alignment: .leading)

            // RSS Memory + Inline Proportional Bar
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if item.cpuPercent >= 0.5 {
                        Text(String(format: "%.1f%% CPU", item.cpuPercent))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LedgerTheme.mist)
                    }
                    Text(item.isFrozen ? "0 MB" : ByteFormatter.memory(item.rssBytes))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.rssBytes >= 1_073_741_824 ? LedgerTheme.amber : LedgerTheme.chalk)
                }
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LedgerTheme.elevated)
                        .frame(width: 118, height: 4)
                    if item.rssBytes > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.domain == .orphanDaemon || item.rssBytes >= 1_073_741_824 ? LedgerTheme.amber : LedgerTheme.glacier)
                            .frame(width: max(4, 118 * ratio), height: 4)
                    }
                }
            }
            .frame(width: 150, alignment: .trailing)

            // Action Column
            HStack {
                Spacer()
                actionControl(for: item)
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(item.isFrozen ? LedgerTheme.surface.opacity(0.4) : Color.clear)
    }

    @ViewBuilder
    private func actionControl(for item: LaunchItem) -> some View {
        if item.isFrozen {
            Button(action: { monitor.restoreByLabel(item.label) }) {
                Text("Restore")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerTheme.emerald)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LedgerTheme.emerald.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(LedgerTheme.emerald.opacity(0.45), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else if item.domain == .userAgent && !item.isAppleSystem {
            Button(action: { monitor.freeze(item) }) {
                HStack(spacing: 4) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Freeze")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(LedgerTheme.glacier)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LedgerTheme.glacier.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(LedgerTheme.glacier.opacity(0.42), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        } else if item.domain == .orphanDaemon {
            Button(action: { monitor.terminateOrphan(item) }) {
                Text("Stop PID")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerTheme.amber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LedgerTheme.amber.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(LedgerTheme.amber.opacity(0.42), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else {
            Text("Read-only")
                .font(.system(size: 11))
                .foregroundStyle(LedgerTheme.mist.opacity(0.75))
        }
    }

    // MARK: - Reversible Snapshot Vault Footer

    private var frozenVaultDrawer: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13))
                .foregroundStyle(LedgerTheme.glacier)
            Text("Snapshot vault (\(monitor.snapshot.frozenRecords.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerTheme.chalk)

            if let latest = monitor.snapshot.frozenRecords.first {
                Text("\(latest.label) (\(ByteFormatter.memory(latest.rssBytesAtFreeze)) saved, sha256:\(String(latest.sha256Hex.prefix(10))))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LedgerTheme.mist)
                    .lineLimit(1)

                Spacer()

                Button(action: { monitor.restore(latest) }) {
                    Text("Restore latest")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerTheme.chalk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(LedgerTheme.elevated))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(LedgerTheme.surface)
    }
}
