import Foundation

enum LocalizedFormatters {
    /// The Locale matching the user's chosen UI language.
    static var currentLocale: Locale {
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        return Locale(identifier: lang.isEmpty ? "en" : lang)
    }

    /// A `DateFormatter` configured for the user's chosen language.
    /// Numbers are kept in Western Arabic (1, 2, 3) intentionally — older
    /// Punjabi-Canadian readers in BC are accustomed to them and Gurmukhi
    /// numerals add cognitive load. Document update: see CLAUDE.md.
    static func dateFormatter(format: String) -> DateFormatter {
        let f = DateFormatter()
        // Construct a locale that keeps the chosen language's day/month
        // names but forces Western Arabic numerals via the @numbers=latn
        // BCP-47 extension. Older Punjabi-Canadian readers in BC are used to
        // 1, 2, 3 — Gurmukhi numerals add cognitive load (see CLAUDE.md).
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        let identifier = lang.isEmpty ? "en" : lang
        f.locale = Locale(identifier: "\(identifier)@numbers=latn")
        f.dateFormat = format
        return f
    }

    /// `h:mm a` time formatter scoped to the active locale (AM / PM strings
    /// localize via the locale's calendar symbols).
    static var timeFormatter: DateFormatter {
        dateFormatter(format: "h:mm a")
    }

    /// `EEEE, MMMM d` for the Today subtitle.
    static var fullDateFormatter: DateFormatter {
        dateFormatter(format: "EEEE, MMMM d")
    }

    /// `MMM d` for the History week range labels.
    static var monthDayFormatter: DateFormatter {
        dateFormatter(format: "MMM d")
    }

    /// Returns a localized "morning / afternoon / evening / night" word for
    /// the given hour. English returns an empty string — AM/PM already
    /// disambiguates and Latin readers don't need it.
    static func timeOfDayWord(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        guard lang == "pa" else { return "" }
        switch hour {
        case 0..<12:  return "ਸਵੇਰੇ"      // morning
        case 12..<17: return "ਦੁਪਹਿਰ"     // afternoon
        case 17..<20: return "ਸ਼ਾਮ"        // evening
        default:      return "ਰਾਤ"        // night
        }
    }
}
