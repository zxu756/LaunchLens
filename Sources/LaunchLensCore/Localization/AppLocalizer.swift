import Combine
import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public static func parseCLI(_ raw: String) -> AppLanguage? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-") || normalized.hasPrefix("zh_") {
            return .zhHans
        }
        if normalized == "en" || normalized.hasPrefix("en-") || normalized.hasPrefix("en_") {
            return .en
        }
        return nil
    }
}

public protocol PreferenceStoring: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStoring {}

@MainActor
public final class AppLocalizer: ObservableObject {
    nonisolated public static let defaultPreferenceKey = "local.xu.LaunchLens.language"
    public static let shared = AppLocalizer()

    @Published public var language: AppLanguage {
        didSet {
            guard persistChanges else { return }
            preferenceStore.set(language.rawValue, forKey: preferenceKey)
        }
    }

    public let preferenceKey: String
    private let preferenceStore: any PreferenceStoring
    private var persistChanges: Bool

    public convenience init(
        arguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults = .standard,
        preferenceKey: String = AppLocalizer.defaultPreferenceKey,
        preferredLanguages: [String] = Locale.preferredLanguages,
        persistCLI: Bool = false
    ) {
        self.init(
            arguments: arguments,
            preferenceStore: userDefaults,
            preferenceKey: preferenceKey,
            preferredLanguages: preferredLanguages,
            persistCLI: persistCLI
        )
    }

    public init(
        arguments: [String] = CommandLine.arguments,
        preferenceStore: any PreferenceStoring,
        preferenceKey: String = AppLocalizer.defaultPreferenceKey,
        preferredLanguages: [String] = Locale.preferredLanguages,
        persistCLI: Bool = false
    ) {
        self.preferenceStore = preferenceStore
        self.preferenceKey = preferenceKey
        self.persistChanges = true

        if let cliLang = Self.resolveCLILanguage(from: arguments) {
            self.persistChanges = persistCLI
            self.language = cliLang
            self.persistChanges = true
        } else if let saved = preferenceStore.string(forKey: preferenceKey),
                  let parsed = AppLanguage(rawValue: saved) ?? AppLanguage.parseCLI(saved) {
            self.language = parsed
        } else if let firstPreferred = preferredLanguages.first,
                  firstPreferred.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zh") {
            self.language = .zhHans
        } else {
            self.language = .en
        }
    }

    public init(fixedLanguage: AppLanguage) {
        self.preferenceStore = UserDefaults.standard
        self.preferenceKey = Self.defaultPreferenceKey
        self.persistChanges = false
        self.language = fixedLanguage
    }

    public var isChinese: Bool {
        language == .zhHans
    }

    public func L(_ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public func toggle() {
        language = (language == .zhHans) ? .en : .zhHans
    }

    public static func resolveCLILanguage(from arguments: [String]) -> AppLanguage? {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--lang", idx + 1 < arguments.count {
                if let resolved = AppLanguage.parseCLI(arguments[idx + 1]) {
                    return resolved
                }
            } else if arg.hasPrefix("--lang=") {
                let value = String(arg.dropFirst("--lang=".count))
                if let resolved = AppLanguage.parseCLI(value) {
                    return resolved
                }
            }
        }
        return nil
    }

    public var snapshotVocabulary: SnapshotCLIVocabulary {
        SnapshotCLIVocabulary(language: language)
    }
}

public struct SnapshotCLIVocabulary: Sendable {
    public let snapshotSavedPrefix: String
    public let servicesHeader: String
    public let listenersHeader: String
    public let orphansHeader: String
    public let addedWord: String
    public let removedWord: String
    public let modifiedWord: String
    public let domainUser: String
    public let domainGlobal: String
    public let domainSystem: String
    public let plistField: String
    public let programField: String
    public let bindField: String
    public let orphanTag: String
    public let startedField: String
    public let reasonPlistContent: String
    public let reasonProgram: String
    public let reasonSchedule: String

    public init(language: AppLanguage) {
        switch language {
        case .en:
            self.snapshotSavedPrefix = "Snapshot saved to"
            self.servicesHeader = "Services"
            self.listenersHeader = "Listening Ports"
            self.orphansHeader = "Orphan Processes"
            self.addedWord = "added"
            self.removedWord = "removed"
            self.modifiedWord = "modified"
            self.domainUser = "user"
            self.domainGlobal = "global"
            self.domainSystem = "system"
            self.plistField = "plist"
            self.programField = "program"
            self.bindField = "bind"
            self.orphanTag = "orphan"
            self.startedField = "started"
            self.reasonPlistContent = "plist"
            self.reasonProgram = "program"
            self.reasonSchedule = "schedule"
        case .zhHans:
            self.snapshotSavedPrefix = "已保存快照至"
            self.servicesHeader = "后台服务"
            self.listenersHeader = "监听端口"
            self.orphansHeader = "孤儿进程"
            self.addedWord = "新增"
            self.removedWord = "删除"
            self.modifiedWord = "修改"
            self.domainUser = "用户"
            self.domainGlobal = "全局"
            self.domainSystem = "系统"
            self.plistField = "plist"
            self.programField = "程序"
            self.bindField = "绑定"
            self.orphanTag = "孤儿"
            self.startedField = "启动"
            self.reasonPlistContent = "配置内容"
            self.reasonProgram = "程序"
            self.reasonSchedule = "启动策略"
        }
    }

    public func domainName(_ domain: SnapshotServiceDomain) -> String {
        switch domain {
        case .user: return domainUser
        case .global: return domainGlobal
        case .system: return domainSystem
        }
    }

    public func reasonName(_ reason: SnapshotServiceChangeReason) -> String {
        switch reason {
        case .plistContentChanged: return reasonPlistContent
        case .programChanged: return reasonProgram
        case .scheduleChanged: return reasonSchedule
        }
    }
}

public struct LanguageTogglePill: View {
    @ObservedObject public var localizer: AppLocalizer
    public var compact: Bool

    @MainActor
    public init(localizer: AppLocalizer? = nil, compact: Bool = false) {
        self.localizer = localizer ?? .shared
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(AppLanguage.allCases) { lang in
                let active = localizer.language == lang
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 1.0)) {
                        localizer.language = lang
                    }
                } label: {
                    Text(lang.badge)
                        .font(.system(size: compact ? 11 : 11.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? LedgerTheme.cobalt : LedgerTheme.muted)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, compact ? 3.5 : 5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? LedgerTheme.sheet : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    active ? LedgerTheme.cobalt.opacity(0.38) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LedgerTheme.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(LedgerTheme.hairline, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help(localizer.L("Toggle language (⇧⌘L)", "切换语言 (⇧⌘L)"))
    }
}
