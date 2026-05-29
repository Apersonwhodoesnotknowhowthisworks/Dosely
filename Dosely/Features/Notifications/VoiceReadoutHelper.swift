import Foundation

/// Thin compatibility shim. The real implementation is now
/// `VoiceReadoutService` (queue, language fallback, rate/enable controls,
/// audio session). This entry point survives only so the existing
/// foreground-notification call site keeps working; it forwards the localized
/// reminder body to the service as a `.custom` utterance in the active app
/// language. New code should call `VoiceReadoutService.shared` directly.
enum VoiceReadoutHelper {
    /// Speaks `text` (already localized) in the user's current app language.
    /// Safe to call from any thread — hops to the main actor for the
    /// `@MainActor` service.
    static func speak(_ text: String) {
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        Task { @MainActor in
            VoiceReadoutService.shared.speak(.custom(text, language: lang))
        }
    }
}
