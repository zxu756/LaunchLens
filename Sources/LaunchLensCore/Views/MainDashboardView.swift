import SwiftUI

public enum LedgerTheme {
    // Studio Alabaster & Cryo-Cobalt Light Precision Palette
    public static let canvas = Color(red: 0.965, green: 0.961, blue: 0.945)     // #F6F5F1 warm studio alabaster
    public static let sheet = Color(red: 1.000, green: 1.000, blue: 1.000)      // #FFFFFF pure elevated ledger sheet
    public static let well = Color(red: 0.925, green: 0.918, blue: 0.890)       // #ECEAE3 recessed control & bar well
    public static let tinted = Color(red: 0.949, green: 0.945, blue: 0.925)     // #F2F1EC subtle table header band
    public static let hairline = Color(red: 0.859, green: 0.847, blue: 0.808)   // #DBD8CE crisp structural hairline
    public static let rowRule = Color(red: 0.918, green: 0.910, blue: 0.882)    // #EAE8E1 subtle row separator

    public static let ink = Color(red: 0.094, green: 0.090, blue: 0.082)        // #181715 deep obsidian ink
    public static let muted = Color(red: 0.396, green: 0.376, blue: 0.345)      // #656058 secondary graphite
    public static let subtle = Color(red: 0.545, green: 0.522, blue: 0.482)     // #8B857B tertiary metadata

    public static let cobalt = Color(red: 0.118, green: 0.337, blue: 0.627)     // #1E56A0 cryo snapshot & user agent
    public static let terracotta = Color(red: 0.761, green: 0.255, blue: 0.114) // #C2411D orphan alert & high RSS
    public static let forest = Color(red: 0.098, green: 0.447, blue: 0.306)     // #19724E active daemon & TCP port
    public static let plum = Color(red: 0.392, green: 0.263, blue: 0.608)       // #64439B global agent
}

public struct ActionConfirmationSheetView: View {
    @ObservedObject var monitor: LaunchLensMonitor
    @ObservedObject var localizer: AppLocalizer
    let action: PendingConfirmationAction

    public var body: some View {
        let details = monitor.confirmationDetails(for: action, localizer: localizer)
        let isConflict: Bool = {
            if case .resolveRestoreConflict = action { return true }
            return false
        }()

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: isConflict ? "exclamationmark.triangle.fill" : "terminal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isConflict ? LedgerTheme.terracotta : LedgerTheme.cobalt)
                Text(details.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LedgerTheme.ink)
                Spacer()
            }

            Text(details.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(LedgerTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(localizer.L("Exact command to execute", "即将执行的命令"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerTheme.muted)
                Text(details.exactCommand)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LedgerTheme.ink)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.well))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Text(details.sourcePathLabel + ":")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerTheme.muted)
                        .frame(width: 126, alignment: .leading)
                    Text(details.sourcePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerTheme.ink)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(details.targetPathLabel + ":")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerTheme.muted)
                        .frame(width: 126, alignment: .leading)
                    Text(details.targetPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerTheme.ink)
                        .textSelection(.enabled)
                }
            }

            if let diff = details.diffSummary {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localizer.L("Detected file difference", "两份文件的差异摘要"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerTheme.terracotta)
                    Text(diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerTheme.ink)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LedgerTheme.terracotta.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(LedgerTheme.terracotta.opacity(0.32), lineWidth: 1))
                }
            }

            HStack(spacing: 10) {
                Button(action: { monitor.cancelPendingConfirmation() }) {
                    Text(details.cancelTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LedgerTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.sheet))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                if isConflict {
                    Button(action: { monitor.resolveConflictKeepExisting() }) {
                        Text(localizer.L("Keep Existing & Clear Record", "保留现有文件并清理记录"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LedgerTheme.cobalt)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LedgerTheme.cobalt.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LedgerTheme.cobalt.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { monitor.confirmPendingAction() }) {
                    Text(details.confirmTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isConflict ? LedgerTheme.terracotta : LedgerTheme.cobalt)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 560)
        .background(LedgerTheme.canvas)
        .foregroundStyle(LedgerTheme.ink)
        .environment(\.locale, localizer.language.locale)
        .preferredColorScheme(.light)
    }
}

public struct MainDashboardView: View {
    @ObservedObject var monitor: LaunchLensMonitor
    @ObservedObject var localizer: AppLocalizer

    @MainActor
    public init(monitor: LaunchLensMonitor, localizer: AppLocalizer? = nil) {
        self.monitor = monitor
        self.localizer = localizer ?? .shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            mastheadBar
            Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
            metricAndAllocationBand
            Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
            filterBarSection
            Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
            ledgerTableHeader
            Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
            ledgerRowsSection
            if !monitor.snapshot.frozenRecords.isEmpty {
                Rectangle().fill(LedgerTheme.hairline).frame(height: 1)
                frozenVaultDrawer
            }
        }
        .background(LedgerTheme.canvas)
        .foregroundStyle(LedgerTheme.ink)
        .environment(\.locale, localizer.language.locale)
        .preferredColorScheme(.light)
        .sheet(item: $monitor.pendingConfirmation) { action in
            ActionConfirmationSheetView(monitor: monitor, localizer: localizer, action: action)
        }
    }

    // MARK: - Top Masthead

    private var mastheadBar: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LedgerTheme.cobalt)
                    .frame(width: 28, height: 28)
                Image(systemName: "snowflake")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("LaunchLens")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(LedgerTheme.ink)

                if monitor.isStaticPreview {
                    Text(localizer.L("DEMO PREVIEW", "演示数据 DEMO"))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(LedgerTheme.terracotta)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(LedgerTheme.terracotta.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(LedgerTheme.terracotta.opacity(0.42), lineWidth: 1)
                        )
                }

                Text(localizer.L(
                    "User LaunchAgents, orphan daemons & SHA-256 reversible freeze ledger",
                    "用户级 LaunchAgents、孤儿守护进程与 SHA-256 可逆冻结账本"
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(LedgerTheme.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 12)

            LanguageTogglePill(localizer: localizer)

            Button(action: { monitor.refresh() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(localizer.L("Rescan host", "重新扫描"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(LedgerTheme.ink)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LedgerTheme.sheet)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(LedgerTheme.canvas)
    }

    // MARK: - 4-Column Precision Ledger Strip + Memory Spectrum

    private var metricAndAllocationBand: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                ledgerMetricCell(
                    value: ByteFormatter.memory(monitor.snapshot.totalBackgroundRSSBytes),
                    label: localizer.L("Background resident RAM", "后台常驻内存 (RSS)"),
                    detail: localizer.L("Service process trees + orphans", "服务进程树与孤儿进程"),
                    accent: LedgerTheme.ink
                )
                verticalRule
                ledgerMetricCell(
                    value: "\(monitor.snapshot.runningNonAppleCount)",
                    label: localizer.L("Active background services", "活跃后台服务"),
                    detail: localizer.L(
                        "\(monitor.snapshot.frozenRecords.count) frozen in snapshot vault",
                        "快照保险库已冻结 \(monitor.snapshot.frozenRecords.count) 项"
                    ),
                    accent: LedgerTheme.cobalt
                )
                verticalRule
                ledgerMetricCell(
                    value: ByteFormatter.memory(monitor.snapshot.orphanRSSBytes),
                    label: localizer.L("Orphan daemon memory", "孤儿守护进程内存"),
                    detail: monitor.snapshot.orphanItems.isEmpty
                        ? localizer.L("Zero PPID=1 orphan daemons", "0 个 PPID=1 脱离终端进程")
                        : localizer.L(
                            "\(monitor.snapshot.orphanItems.count) detached PPID=1 (read-only)",
                            "\(monitor.snapshot.orphanItems.count) 个脱离终端进程（只读）"
                        ),
                    accent: monitor.snapshot.orphanItems.isEmpty ? LedgerTheme.ink : LedgerTheme.terracotta
                )
                verticalRule
                ledgerMetricCell(
                    value: "\(monitor.snapshot.totalListeningPortCount)",
                    label: localizer.L("Bound local TCP ports", "已监听本地 TCP 端口"),
                    detail: localizer.L("Live lsof TCP socket scan", "实时 lsof 监听套接字扫描"),
                    accent: LedgerTheme.forest
                )
            }

            memoryAllocationStrip
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(LedgerTheme.sheet)
    }

    private var verticalRule: some View {
        Rectangle()
            .fill(LedgerTheme.rowRule)
            .frame(width: 1, height: 46)
            .padding(.horizontal, 18)
    }

    private func ledgerMetricCell(value: String, label: String, detail: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(accent)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerTheme.ink.opacity(0.88))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LedgerTheme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var memoryAllocationStrip: some View {
        let total = max(1, Double(monitor.snapshot.totalBackgroundRSSBytes))
        let top4 = Array(monitor.topMemoryConsumers.prefix(4))
        let topSum = top4.map(\.rssBytes).reduce(0, +)
        let remainder = max(0, monitor.snapshot.totalBackgroundRSSBytes - topSum)
        let palette: [Color] = [
            LedgerTheme.cobalt,
            Color(red: 0.220, green: 0.478, blue: 0.745),
            LedgerTheme.plum,
            LedgerTheme.forest
        ]

        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                let fullW = max(1, geo.size.width)
                HStack(spacing: 2) {
                    ForEach(Array(top4.enumerated()), id: \.element.id) { idx, item in
                        let fraction = CGFloat(Double(item.rssBytes) / total)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(item.domain == .orphanDaemon ? LedgerTheme.terracotta : palette[idx % palette.count])
                            .frame(width: max(6, fullW * fraction - 2))
                    }
                    if remainder > 0 {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(LedgerTheme.well)
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 16) {
                ForEach(Array(top4.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.domain == .orphanDaemon ? LedgerTheme.terracotta : palette[idx % palette.count])
                            .frame(width: 6, height: 6)
                        Text(shortLegendName(item.label))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LedgerTheme.ink.opacity(0.86))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(ByteFormatter.memory(item.rssBytes))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LedgerTheme.muted)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if remainder > 0 {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(LedgerTheme.subtle.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(localizer.L(
                            "Other \(ByteFormatter.memory(remainder))",
                            "其他 \(ByteFormatter.memory(remainder))"
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerTheme.muted)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Spacer()
            }
        }
    }

    private func shortLegendName(_ label: String) -> String {
        if let pidRange = label.range(of: " (PID ", options: .backwards) {
            return String(label[..<pidRange.lowerBound])
        }
        return label
    }

    // MARK: - Segmented Well Filter & Search Bar

    private var filterBarSection: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(LaunchFilterTab.allCases) { tab in
                    let active = monitor.selectedFilter == tab
                    Button(action: { monitor.selectedFilter = tab }) {
                        HStack(spacing: 5) {
                            Text(tab.localizedTitle(localizer))
                                .font(.system(size: 12, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? LedgerTheme.ink : LedgerTheme.muted)
                            Text(verbatim: "\(countForTab(tab))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(active ? LedgerTheme.cobalt : LedgerTheme.subtle)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? LedgerTheme.sheet : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(active ? LedgerTheme.hairline : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LedgerTheme.well)
            )
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            Button(action: { monitor.showAppleSystem.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: monitor.showAppleSystem ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(monitor.showAppleSystem ? LedgerTheme.cobalt : LedgerTheme.subtle)
                    Text(localizer.L("Apple services", "显示 Apple 服务"))
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.muted)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            let placeholder = localizer.L("Filter label, command, or port", "筛选服务标识、命令或端口")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerTheme.subtle)
                if monitor.isStaticPreview {
                    Text(monitor.searchQuery.isEmpty ? placeholder : monitor.searchQuery)
                        .font(.system(size: 12))
                        .foregroundStyle(monitor.searchQuery.isEmpty ? LedgerTheme.subtle : LedgerTheme.ink)
                        .frame(width: 184, alignment: .leading)
                } else {
                    TextField(placeholder, text: $monitor.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.ink)
                        .frame(width: 184)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LedgerTheme.sheet)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
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
            Text(localizer.L("Service label & launch command", "服务标识与启动命令"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(localizer.L("Domain", "所属域"))
                .frame(width: 112, alignment: .leading)
            Text(localizer.L("PID / TCP ports", "PID / 监听端口"))
                .frame(width: 112, alignment: .leading)
            Text(localizer.L("Resident memory", "常驻内存 (RSS)"))
                .frame(width: 140, alignment: .trailing)
            Text(localizer.L("Control", "操作"))
                .frame(width: 98, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(LedgerTheme.muted)
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .background(LedgerTheme.tinted)
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
            .background(LedgerTheme.sheet)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ledgerRowsListContent(maxRSS: maxRSS)
                }
            }
            .frame(maxHeight: .infinity)
            .background(LedgerTheme.sheet)
        }
    }

    @ViewBuilder
    private func ledgerRowsListContent(maxRSS: Int64) -> some View {
        if let integrityMsg = monitor.localizedIntegrityBannerText(localizer) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LedgerTheme.terracotta)
                Text(integrityMsg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerTheme.ink)
                Spacer()
                if monitor.integrityReport.corruptedLedgerError == nil {
                    Button(action: { monitor.requestRepairIntegrity() }) {
                        Text(localizer.L("Repair / Recover", "修复 / 恢复"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LedgerTheme.terracotta))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8.5)
            .background(LedgerTheme.terracotta.opacity(0.10))
            Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)
        }

        if let banner = monitor.localizedStatusText(localizer) {
            HStack(spacing: 8) {
                Image(systemName: monitor.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(monitor.statusIsError ? LedgerTheme.terracotta : LedgerTheme.cobalt)
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(
                (monitor.statusIsError ? LedgerTheme.terracotta : LedgerTheme.cobalt).opacity(0.08)
            )
            Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)
        }

        if monitor.filteredItems.isEmpty {
            VStack(spacing: 6) {
                Text(localizer.L("No matching background services", "未找到匹配的后台服务"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LedgerTheme.ink)
                Text(localizer.L(
                    "Adjust the active filter segment or clear the search query to inspect all services.",
                    "请切换上方筛选标签或清空搜索关键词以查看全部服务。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(LedgerTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            ForEach(monitor.filteredItems) { item in
                ledgerRow(item, maxRSS: maxRSS)
                Rectangle().fill(LedgerTheme.rowRule).frame(height: 1)
            }
        }
    }

    private func ledgerRow(_ item: LaunchItem, maxRSS: Int64) -> some View {
        let ratio = CGFloat(Double(item.rssBytes) / Double(maxRSS))
        let isOrphan = item.domain == .orphanDaemon
        let isHeavy = item.rssBytes >= 1_073_741_824

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(
                            item.isFrozen
                                ? LedgerTheme.cobalt
                                : (isOrphan ? LedgerTheme.terracotta : (item.isRunning ? LedgerTheme.forest : LedgerTheme.subtle.opacity(0.45)))
                        )
                        .frame(width: 7, height: 7)
                    Text(item.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.isFrozen ? LedgerTheme.muted : LedgerTheme.ink)
                        .lineLimit(1)
                    if item.keepAlive {
                        Text(localizer.L("KeepAlive", "常驻保活"))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(LedgerTheme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(RoundedRectangle(cornerRadius: 4).fill(LedgerTheme.well))
                    }
                }
                Text(LaunchLensMonitor.displayPath(item.localizedProgramCommand(localizer)))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LedgerTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Unboxed Editorial Domain Indicator
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(item.isFrozen ? LedgerTheme.cobalt : item.domain.color)
                    .frame(width: 3, height: 12)
                Text(item.isFrozen
                     ? localizer.L("Frozen plist", "已冻结配置")
                     : item.domain.localizedBadge(localizer))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(item.isFrozen ? LedgerTheme.cobalt : item.domain.color)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 112, alignment: .leading)

            // PID & Listening Ports
            VStack(alignment: .leading, spacing: 2) {
                if let pid = item.pid {
                    Text(verbatim: "PID \(pid)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(LedgerTheme.ink)
                } else {
                    Text(item.isFrozen
                         ? localizer.L("Unloaded", "已卸载")
                         : localizer.L("Idle", "空闲"))
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerTheme.subtle)
                }
                if !item.listeningPorts.isEmpty {
                    Text(item.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LedgerTheme.forest)
                        .lineLimit(1)
                }
            }
            .frame(width: 112, alignment: .leading)

            // RSS Memory + Inline Proportional Bar
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if item.cpuPercent >= 0.5 {
                        Text(String(format: "%.1f%%", item.cpuPercent))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LedgerTheme.subtle)
                    }
                    Text(item.isFrozen ? "0 MB" : ByteFormatter.memory(item.rssBytes))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(isOrphan || isHeavy ? LedgerTheme.terracotta : LedgerTheme.ink)
                }
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LedgerTheme.well)
                        .frame(width: 114, height: 4)
                    if item.rssBytes > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isOrphan ? LedgerTheme.terracotta : LedgerTheme.cobalt)
                            .frame(width: max(4, 114 * ratio), height: 4)
                    }
                }
            }
            .frame(width: 140, alignment: .trailing)

            // Action Column (Orphan Daemons are strictly Read-only in M0 per L5)
            HStack {
                Spacer()
                actionControl(for: item)
            }
            .frame(width: 98, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8.5)
        .background(item.isFrozen ? LedgerTheme.canvas.opacity(0.75) : LedgerTheme.sheet)
    }

    @ViewBuilder
    private func actionControl(for item: LaunchItem) -> some View {
        if item.isFrozen {
            Button(action: { monitor.requestRestoreByLabel(item.label) }) {
                Text(localizer.L("Restore", "恢复"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerTheme.forest)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LedgerTheme.forest.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LedgerTheme.forest.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else if item.domain == .userAgent && !item.isAppleSystem {
            Button(action: { monitor.requestFreeze(item) }) {
                HStack(spacing: 4) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 10, weight: .semibold))
                    Text(localizer.L("Freeze", "冻结"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(LedgerTheme.cobalt)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LedgerTheme.cobalt.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LedgerTheme.cobalt.opacity(0.32), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        } else {
            Text(localizer.L("Read-only", "只读保护"))
                .font(.system(size: 11))
                .foregroundStyle(LedgerTheme.subtle)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Reversible Snapshot Vault Footer

    private var frozenVaultDrawer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(LedgerTheme.cobalt)
            Text(localizer.L(
                "Snapshot vault (\(monitor.snapshot.frozenRecords.count))",
                "快照保险库 (\(monitor.snapshot.frozenRecords.count))"
            ))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LedgerTheme.ink)
            .fixedSize(horizontal: true, vertical: false)

            if let latest = monitor.snapshot.frozenRecords.first {
                Text(localizer.L(
                    "\(latest.label) · \(ByteFormatter.memory(latest.rssBytesAtFreeze)) reclaimed · sha256:\(String(latest.sha256Hex.prefix(10)))",
                    "\(latest.label) · 已释放 \(ByteFormatter.memory(latest.rssBytesAtFreeze)) · sha256:\(String(latest.sha256Hex.prefix(10)))"
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LedgerTheme.muted)
                .lineLimit(1)

                Spacer()

                Button(action: { monitor.requestRestore(latest) }) {
                    Text(localizer.L("Restore latest", "恢复最近快照"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LedgerTheme.sheet))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(LedgerTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(LedgerTheme.canvas)
    }
}
