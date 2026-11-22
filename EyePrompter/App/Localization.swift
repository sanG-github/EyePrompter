import Foundation

/// The app's UI language. "system" follows the device (or the per-app language
/// chosen in iOS Settings › EyePrompter › Language); otherwise the in-app choice wins.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, vi, en

    var id: String { rawValue }

    /// Name shown in the language menu, always in its own language.
    var menuName: String {
        switch self {
        case .system: return tr("Theo máy", "Device language")
        case .vi: return "Tiếng Việt"
        case .en: return "English"
        }
    }

    static var setting: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: Prefs.appLanguage) ?? "") ?? .system
    }

    /// The language actually used (never `.system`).
    static var current: AppLanguage {
        switch setting {
        case .vi: return .vi
        case .en: return .en
        case .system:
            let first = Locale.preferredLanguages.first ?? "vi"
            return first.hasPrefix("vi") ? .vi : .en
        }
    }

    /// Speech-recognition locale to start with when the user hasn't picked one.
    var defaultSpeechLocale: String { self == .en ? "en-US" : "vi-VN" }
    var localeIdentifier: String { self == .en ? "en" : "vi" }
}

/// Picks the Vietnamese or English text for the current UI language.
/// Strings live next to their use so both languages are reviewed together.
func tr(_ vi: String, _ en: String) -> String {
    AppLanguage.current == .en ? en : vi
}
