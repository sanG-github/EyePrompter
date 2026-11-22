import SwiftUI

@main
struct EyePrompterApp: App {
    @StateObject private var store = ScriptStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Color.prompterYellow)
                .onOpenURL { store.handleOpen($0) } // AirDrop / "Open in EyePrompter"
        }
    }
}

/// Strings are picked when views are built, so a language change rebuilds the whole tree.
struct RootView: View {
    @AppStorage(Prefs.appLanguage) private var language = AppLanguage.system.rawValue

    var body: some View {
        ScriptListView()
            .id(language)
            .environment(\.locale, Locale(identifier: AppLanguage.current.localeIdentifier))
    }
}

/// User preferences shared by the prompter and its settings sheet.
enum Prefs {
    static let fontSize = "fontSize"            // pt
    static let visibleLines = "visibleLines"    // lines shown in the prompter band
    static let columnWidth = "columnWidth"      // fraction of screen width
    static let localeID = "localeID"           // speech recognition locale
    static let appLanguage = "appLanguage"     // AppLanguage raw value
    static let eyeContact = "eyeContact"
    static let eyeStrength = "eyeStrength"
    static let autoWPM = "autoWPM"
    static let centerText = "centerText"
    static let camResolution = "camResolution"  // "1080p" | "4K"
    static let camFPS = "camFPS"                // 30 | 60
    static let camExposure = "camExposure"      // EV
    static let camZoom = "camZoom"
    static let autoRewind = "autoRewind"        // follow the voice back when re-reading
    static let camMirror = "camMirror"         // record mirrored (as previewed)
    static let narrowColumn = "narrowColumn"  // "ít liếc mắt": ~3 words per line under the lens
}

extension Color {
    static let prompterYellow = Color(red: 1.0, green: 0.84, blue: 0.04)
}
