import Foundation
import ObjectiveC

/// Bundle subclass that intercepts `localizedString(forKey:value:table:)` and
/// looks up keys in the `.lproj` chosen by `UserDefaults.standard.string(forKey: "app_language")`.
/// Falls through to the system bundle for any key the override can't find.
private class LocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String,
                                  value: String?,
                                  table tableName: String?) -> String {
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? ""
        guard !lang.isEmpty,
              let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

enum LocalizationBundle {
    /// Install the runtime language override on `Bundle.main`. Idempotent.
    /// Call once at app launch; subsequent `Text("key")` / `NSLocalizedString`
    /// lookups will route through the chosen `.lproj`.
    static func install() {
        guard !installed else { return }
        installed = true
        object_setClass(Bundle.main, LocalizedBundle.self)
    }

    private static var installed = false
}

/// Localize a key using the active app language. Use this when you need a
/// `String` for interpolation; for static `Text` views, prefer `Text("key")`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = NSLocalizedString(key, comment: "")
    if args.isEmpty { return template }
    return String(format: template, arguments: args)
}

/// Localize a key in a SPECIFIC language's `.lproj`, independent of the active
/// app language. The voice-readout builders need this: when the chosen language
/// is `pa` they render BOTH the Punjabi segments and an English fallback set in
/// one pass, so the service can speak English if no `pa-IN` voice is installed
/// without the call site constructing two utterances. Falls back to the active
/// language if the requested `.lproj` can't be loaded.
func L(_ key: String, in language: String, _ args: CVarArg...) -> String {
    let template: String
    if let path = Bundle.main.path(forResource: language, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        template = bundle.localizedString(forKey: key, value: nil, table: nil)
    } else {
        template = NSLocalizedString(key, comment: "")
    }
    if args.isEmpty { return template }
    return String(format: template, arguments: args)
}
