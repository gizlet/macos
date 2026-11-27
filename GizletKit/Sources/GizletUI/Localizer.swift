import GizletCore
import SwiftUI

/// The interface language. Every string is written in both languages where it
/// is used, so switching takes effect at once, without a restart.
public struct Localizer: Equatable, Sendable {
    public var chinese: Bool

    public init(chinese: Bool) {
        self.chinese = chinese
    }

    /// The profile's choice, or the system's first preferred language.
    public static func resolve(_ language: ProfileSettings.Language, preferred: [String] = Locale.preferredLanguages) -> Localizer {
        switch language {
        case .english: Localizer(chinese: false)
        case .chinese: Localizer(chinese: true)
        case .system: Localizer(chinese: preferred.first?.hasPrefix("zh") == true)
        }
    }

    /// The language tag for package names and the apps it starts (`GIZLET_LANG`).
    public var tag: String { chinese ? "zh-CN" : "en" }
    public var locale: Locale { Locale(identifier: chinese ? "zh-Hans" : "en") }

    public func callAsFunction(_ english: String, _ chinese: String) -> String {
        self.chinese ? chinese : english
    }

    /// A profile's name; the first one, with none, is "Default" in the interface language.
    public func name(of profile: Profile) -> String {
        profile.name.isEmpty ? self("Default", "默认") : profile.name
    }

    public func bytes(_ count: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: Int64(clamping: count))
    }
}

private struct LocalizerKey: EnvironmentKey {
    static let defaultValue = Localizer(chinese: false)
}

extension EnvironmentValues {
    public var l: Localizer {
        get { self[LocalizerKey.self] }
        set { self[LocalizerKey.self] = newValue }
    }
}
