import AVFoundation
import Foundation
import OSLog
import SwiftUI

/// Speech rate presets surfaced in Settings. Values stay inside
/// `AVSpeechUtterance`'s bounds (min 0.0 … default ~0.5 … max 1.0); 0.4/0.5/0.6
/// keeps "slow" comprehensible for an elderly listener without sounding broken
/// and "fast" brisk without clipping syllables.
enum SpeechRate: String, CaseIterable {
    case slow, normal, fast

    var avRate: Float {
        switch self {
        case .slow:   return 0.4
        case .normal: return 0.5
        case .fast:   return 0.6
        }
    }

    var localizedNameKey: String {
        switch self {
        case .slow:   return "voice.settings.rate.slow"
        case .normal: return "voice.settings.rate.normal"
        case .fast:   return "voice.settings.rate.fast"
        }
    }

    var localizedName: String { L(localizedNameKey) }
}

/// A unit of speech the service can render. `segments` carry the primary
/// language; `fallbackSegments` (English) are spoken instead when the primary
/// is `pa` and no `pa-IN` voice is installed — a grandparent hearing English is
/// better than hearing nothing. The convenience builders produce both lists in
/// one pass so no call site constructs two utterances.
struct VoiceUtterance {
    let segments: [Segment]
    let language: String          // "en" or "pa" — resolves to en-US / pa-IN
    let fallbackSegments: [Segment]?

    struct Segment {
        let text: String
        let pauseAfterMs: UInt     // silence after this segment (between list items)

        init(_ text: String, pauseAfterMs: UInt = 0) {
            self.text = text
            self.pauseAfterMs = pauseAfterMs
        }
    }

    /// Spoken form of a phone number: each digit separated so the synthesizer
    /// reads "6 0 4 5 5 5 …" rather than "six hundred four million …". Strips
    /// every non-digit (spaces, dashes, parens, a leading +).
    static func spokenDigits(_ phone: String) -> String {
        phone.filter(\.isNumber).map(String.init).joined(separator: " ")
    }

    // MARK: - Builders

    /// "Lisinopril, 10 mg, at 8:00 AM." plus an optional food-rule sentence.
    /// `foodRule` is the raw value ("with" / "without" / anything else) so the
    /// builder can render the instruction in each language itself — a
    /// pre-localized string couldn't be re-rendered for the English fallback.
    static func dose(medication: String,
                     dose: String,
                     time: String,
                     foodRule: String?,
                     language: String) -> VoiceUtterance {
        func instruction(_ lang: String) -> String? {
            switch foodRule {
            case "with":    return L("voice.dose.foodrule.with", in: lang)
            case "without": return L("voice.dose.foodrule.without", in: lang)
            default:        return nil
            }
        }
        func build(_ lang: String) -> [Segment] {
            let hasInstruction = instruction(lang) != nil
            var segs = [Segment(L("voice.dose.template", in: lang, medication, dose, time),
                                pauseAfterMs: hasInstruction ? 250 : 0)]
            if let text = instruction(lang) {
                segs.append(Segment(L("voice.dose.instruction.suffix", in: lang, text)))
            }
            return segs
        }
        return VoiceUtterance(segments: build(language),
                              language: language,
                              fallbackSegments: language == "pa" ? build("en") : nil)
    }

    /// "Missed dose. Margaret missed Lisinopril at 8:00 AM." The caller passes
    /// the already-resolved title + body for the active language and, for `pa`,
    /// the English equivalents so the fallback can render.
    static func alert(title: String,
                      body: String,
                      language: String,
                      fallbackTitle: String? = nil,
                      fallbackBody: String? = nil) -> VoiceUtterance {
        let primary = [Segment(L("voice.alert.template", in: language, title, body))]
        var fallback: [Segment]?
        if language == "pa", let ft = fallbackTitle, let fb = fallbackBody {
            fallback = [Segment(L("voice.alert.template", in: "en", ft, fb))]
        }
        return VoiceUtterance(segments: primary, language: language, fallbackSegments: fallback)
    }

    /// The full emergency Medical ID, read top to bottom with a pause between
    /// list items. Reuses `EmergencyMedicalIDViewModel`'s parsed fields and its
    /// suppress-empty-sections rule — the readout and the visual screen can
    /// never disagree about which sections exist. Notes are intentionally
    /// excluded (per the Part 4c field list; freeform notes read poorly aloud).
    static func medicalID(_ viewModel: EmergencyMedicalIDViewModel,
                          personName: String,
                          dateOfBirthText: String?,
                          language: String) -> VoiceUtterance {
        func build(_ lang: String) -> [Segment] {
            var segs = [Segment(L("voice.medicalid.intro", in: lang, personName), pauseAfterMs: 300)]
            if let dob = dateOfBirthText, let age = viewModel.age() {
                // age passed as a string: "%@" expects an object, and we want
                // Western-Arabic numerals everywhere per the localization rules.
                segs.append(Segment(L("voice.medicalid.dob", in: lang, dob, String(age)), pauseAfterMs: 300))
            }
            if viewModel.showBloodType {
                segs.append(Segment(L("voice.medicalid.bloodtype", in: lang, viewModel.bloodType), pauseAfterMs: 300))
            }
            if viewModel.showAllergies {
                segs.append(Segment(L("voice.medicalid.allergies.intro", in: lang), pauseAfterMs: 200))
                for allergy in viewModel.allergies { segs.append(Segment(allergy, pauseAfterMs: 300)) }
            }
            if viewModel.showConditions {
                segs.append(Segment(L("voice.medicalid.conditions.intro", in: lang), pauseAfterMs: 200))
                for condition in viewModel.conditions { segs.append(Segment(condition, pauseAfterMs: 300)) }
            }
            if viewModel.showContacts {
                segs.append(Segment(L("voice.medicalid.contacts.intro", in: lang), pauseAfterMs: 200))
                for contact in viewModel.contacts {
                    segs.append(Segment(
                        L("voice.medicalid.contact.template", in: lang, contact.name, spokenDigits(contact.phone)),
                        pauseAfterMs: 300))
                }
            }
            return segs
        }
        return VoiceUtterance(segments: build(language),
                              language: language,
                              fallbackSegments: language == "pa" ? build("en") : nil)
    }

    /// Arbitrary already-localized text (notification bodies, the Settings test
    /// sample). No automatic translation: pass `fallbackText` to enable the
    /// English fallback (the test sample does); without it, a `pa` utterance is
    /// skipped when no `pa-IN` voice exists — matching the legacy notification
    /// behaviour.
    static func custom(_ text: String, language: String, fallbackText: String? = nil) -> VoiceUtterance {
        var fallback: [Segment]?
        if language == "pa", let fb = fallbackText { fallback = [Segment(fb)] }
        return VoiceUtterance(segments: [Segment(text)], language: language, fallbackSegments: fallback)
    }

    /// Spoken form of a drug interaction: "{severity} interaction between
    /// {drugA} and {drugB}. {description} {recommendation}". Pass
    /// `fallbackInteraction` (the English version) so a Punjabi utterance falls
    /// back to English speech when no pa-IN voice is installed.
    static func interaction(_ interaction: DrugInteraction,
                            language: String,
                            fallbackInteraction: DrugInteraction? = nil) -> VoiceUtterance {
        func spoken(_ i: DrugInteraction, _ lang: String) -> String {
            L("interactions.readaloud.template", in: lang,
              L(i.severity.localizedNameKey, in: lang) as NSString,
              i.drugA as NSString, i.drugB as NSString,
              i.description as NSString, i.recommendation as NSString)
        }
        var fallback: [Segment]?
        if language == "pa", let fb = fallbackInteraction {
            fallback = [Segment(spoken(fb, "en"))]
        }
        return VoiceUtterance(segments: [Segment(spoken(interaction, language))],
                              language: language, fallbackSegments: fallback)
    }
}

/// The full voice-readout service. Owns one `AVSpeechSynthesizer` for its
/// lifetime (per-call instances get deallocated mid-speech and cut off), keeps
/// an utterance queue so requests serialise rather than interrupt each other,
/// and falls back to English when a `pa-IN` voice is missing. Drives speaker
/// affordances via `isSpeaking`. Replaces the minimal `VoiceReadoutHelper`,
/// which now forwards here.
@MainActor
final class VoiceReadoutService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceReadoutService()

    static let enabledKey = "voice_readout_enabled"
    static let rateKey = "voice_readout_rate"
    private static let logger = Logger(subsystem: "com.medication.dosely", category: "voice")

    @Published private(set) var isSpeaking = false
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.enabledKey) } }
    @Published var rate: SpeechRate { didSet { defaults.set(rate.rawValue, forKey: Self.rateKey) } }

    private let synthesizer = AVSpeechSynthesizer()
    private let voiceAvailable: (String) -> Bool
    private let defaults: UserDefaults
    private let logSink: (String) -> Void
    private let configureAudioSession: () -> Void

    private struct Resolved { let segments: [VoiceUtterance.Segment]; let voiceCode: String }
    private var queue: [Resolved] = []
    private var current: Resolved?
    private var remainingSegments = 0

    /// Test seam: when set, segments are recorded here instead of spoken, and
    /// the test drives completion via `handleSegmentFinished()` rather than
    /// real (audio-less, unreliable in a headless runner) delegate callbacks.
    var onEmitForTesting: ((AVSpeechUtterance) -> Void)?

    /// Pending utterances behind the one currently speaking — for tests.
    var pendingCount: Int { queue.count }

    init(voiceAvailable: @escaping (String) -> Bool = { AVSpeechSynthesisVoice(language: $0) != nil },
         defaults: UserDefaults = .standard,
         configureAudioSession: @escaping () -> Void = VoiceReadoutService.activatePlaybackSession,
         log: ((String) -> Void)? = nil) {
        self.voiceAvailable = voiceAvailable
        self.defaults = defaults
        self.configureAudioSession = configureAudioSession
        self.logSink = log ?? { Self.logger.debug("\($0, privacy: .public)") }
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.rate = SpeechRate(rawValue: defaults.string(forKey: Self.rateKey) ?? "") ?? .normal
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Enqueue an utterance. A no-op when disabled. While something is already
    /// speaking, this queues behind it rather than interrupting.
    func speak(_ utterance: VoiceUtterance) {
        guard isEnabled else { return }
        guard let resolved = resolve(utterance) else { return }
        queue.append(resolved)
        logSink("[VOICE-DEBUG] queued utterance (\(resolved.segments.count) segment(s), \(resolved.voiceCode)); depth=\(queue.count)")
        if current == nil { startNext() }
    }

    /// Stop immediately and clear everything pending.
    func stop() {
        queue.removeAll()
        current = nil
        remainingSegments = 0
        isSpeaking = false
        if onEmitForTesting == nil { synthesizer.stopSpeaking(at: .immediate) }
    }

    // MARK: - Queue engine

    private func resolve(_ utterance: VoiceUtterance) -> Resolved? {
        if utterance.language == "pa", !voiceAvailable("pa-IN") {
            if let fallback = utterance.fallbackSegments {
                logSink("[VOICE-DEBUG] pa-IN voice not installed; falling back to en-US")
                return Resolved(segments: fallback, voiceCode: "en-US")
            }
            logSink("[VOICE-DEBUG] pa-IN voice not installed and no English fallback; skipping utterance")
            return nil
        }
        let code = utterance.language == "pa" ? "pa-IN" : "en-US"
        return Resolved(segments: utterance.segments, voiceCode: code)
    }

    private func startNext() {
        guard !queue.isEmpty else {
            current = nil
            isSpeaking = false
            return
        }
        let next = queue.removeFirst()
        current = next
        isSpeaking = true
        remainingSegments = next.segments.count
        logSink("[VOICE-DEBUG] advancing to next utterance; \(queue.count) still queued")
        guard remainingSegments > 0 else { handleSegmentFinished(); return }

        configureAudioSession()
        let voice = AVSpeechSynthesisVoice(language: next.voiceCode)
        for segment in next.segments {
            let av = AVSpeechUtterance(string: segment.text)
            av.voice = voice
            av.rate = rate.avRate
            av.postUtteranceDelay = TimeInterval(segment.pauseAfterMs) / 1000.0
            emit(av)
        }
    }

    private func emit(_ utterance: AVSpeechUtterance) {
        if let hook = onEmitForTesting { hook(utterance); return }
        synthesizer.speak(utterance)
    }

    /// One segment finished. When the current utterance's last segment is done,
    /// advance to the next queued one. Called by the synthesizer delegate in
    /// production and directly by tests.
    func handleSegmentFinished() {
        guard remainingSegments > 0 else { return }
        remainingSegments -= 1
        if remainingSegments == 0 {
            current = nil
            startNext()
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleSegmentFinished() }
    }

    // MARK: - Audio session

    /// `.playback` + `.mixWithOthers` is the right configuration for an
    /// accessibility readout: it plays even when the ringer switch is on silent
    /// (an elderly user often keeps the phone muted, and a med readout must not
    /// be one of the things silenced), and mixes with rather than kills any
    /// other audio. Reactivated on every utterance because an interruption can
    /// deactivate the session underneath us.
    static func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }
}

/// The active app language code ("en" / "pa"), matching the key
/// `LocalizationBundle` reads. Voice call sites pass this so the readout follows
/// the chosen UI language, not the system locale.
func currentAppLanguage() -> String {
    UserDefaults.standard.string(forKey: "app_language") ?? "en"
}

/// Shared "Read aloud" affordance used by dose cards, alerts, and the emergency
/// Medical ID. Tapping speaks the supplied utterance; tapping again (or tapping
/// a different one) stops it. The icon fills and pulses while *this* button's
/// utterance is the one playing — tracked with `isMine` so sibling buttons in a
/// list don't all pulse when any one speaks. Hidden entirely when voice readout
/// is disabled in Settings.
struct ReadAloudButton: View {
    enum Style { case icon, prominent }

    var style: Style = .icon
    let utterance: () -> VoiceUtterance

    @ObservedObject private var service = VoiceReadoutService.shared
    @State private var isMine = false

    private var isActive: Bool { isMine && service.isSpeaking }

    var body: some View {
        if service.isEnabled {
            Button(action: toggle) { label }
                .accessibilityLabel(Text("voice.readaloud.button.a11yLabel"))
                .accessibilityHint(Text("voice.readaloud.button.a11yHint"))
                .accessibilityValue(isActive ? Text("voice.readaloud.button.speaking") : Text(""))
                .onChange(of: service.isSpeaking) { speaking in
                    if !speaking { isMine = false }
                }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .icon:
            Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.title3)
                .foregroundColor(.dsPrimary)
                .scaleEffect(isActive ? 1.12 : 1.0)
                .animation(pulse, value: isActive)
                .frame(minWidth: DSSpacing.minTapTarget, minHeight: DSSpacing.minTapTarget)
                .contentShape(Rectangle())
        case .prominent:
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .scaleEffect(isActive ? 1.12 : 1.0)
                    .animation(pulse, value: isActive)
                Text("voice.readaloud.button.a11yLabel")
            }
            .dsBodyLarge()
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            .background(Color.dsPrimary)
            .cornerRadius(DSSpacing.rMd)
        }
    }

    private var pulse: Animation? {
        isActive ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default
    }

    private func toggle() {
        if isActive {
            service.stop()
            isMine = false
        } else {
            service.stop()
            service.speak(utterance())
            isMine = true
        }
    }
}
