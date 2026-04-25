import SwiftUI
import FirebaseCore

@main
struct DoselyApp: App {
    @UIApplicationDelegateAdaptor(NotificationsAppDelegate.self) private var appDelegate

    @AppStorage("app_language") private var language: String = ""
    @AppStorage("language_picked") private var languagePicked: Bool = false

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
            .id(language)   // forces a full SwiftUI rebuild when the user switches languages
        }
    }
}
