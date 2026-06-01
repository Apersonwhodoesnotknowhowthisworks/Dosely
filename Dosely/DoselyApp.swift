import SwiftUI
import FirebaseCore

@main
struct DoselyApp: App {
    @UIApplicationDelegateAdaptor(NotificationsAppDelegate.self) private var appDelegate

    @AppStorage("app_language") private var language: String = ""
    @AppStorage("language_picked") private var languagePicked: Bool = false
    @AppStorage("force_light_mode") private var forceLightMode: Bool = false
    @AppStorage("force_high_contrast") private var forceHighContrast: Bool = false
    @AppStorage("force_larger_text") private var forceLargerText: Bool = false

    init() {
        FirebaseApp.configure()
        LocalizationBundle.install()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !languagePicked {
                    LanguagePickerView { picked in
                        language = picked
                        languagePicked = true
                    }
                } else {
                    AuthGate()
                }
            }
            .environment(\.locale, Locale(identifier: language.isEmpty ? "en" : language))
            // "Larger text" raises the floor to .accessibility1; .xSmall... is a
            // no-op floor when off. Reactive — no rebuild needed. Never caps a
            // larger system setting (a PartialRangeFrom only sets a lower bound).
            .dynamicTypeSize(forceLargerText ? AccessibilityScaling.floor... : DynamicTypeSize.xSmall...)
            // Folding force_high_contrast into the id forces a full rebuild so the
            // 4-cell DSColors re-resolve immediately when the in-app toggle flips
            // (same mechanism as the language switch). iOS "Increase Contrast" is a
            // real trait and re-resolves on its own without this.
            .id("\(language)|\(forceHighContrast)")
            .preferredColorScheme(forceLightMode ? .light : nil)
        }
    }
}
