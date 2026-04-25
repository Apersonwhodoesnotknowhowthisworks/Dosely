import Foundation
import AVFoundation

/// Minimal voice readout helper. The full VoiceReadoutService lands in a
/// later accessibility prompt; this exists only to speak a localized
/// reminder string when the app is in the foreground.
///
/// If no voice is installed for the requested language, logs a
/// `[VOICE-DEBUG]` line and silently no-ops — never blocks the user.
enum VoiceReadoutHelper {
    private static let synthesizer = AVSpeechSynthesizer()

    /// Speaks `text` using the voice that matches the current app language.
    /// `pa` maps to `pa-IN` (the BCP-47 tag iOS recognises for Punjabi);
    /// any other language falls back to `en-US`.
    static func speak(_ text: String) {
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        let voiceCode = lang == "pa" ? "pa-IN" : "en-US"

        guard let voice = AVSpeechSynthesisVoice(language: voiceCode) else {
            print("[VOICE-DEBUG] No installed voice for \(voiceCode); skipping speak. Text=\"\(text)\"")
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
