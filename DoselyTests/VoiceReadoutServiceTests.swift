import AVFoundation
import XCTest
@testable import Dosely

/// Behaviour of the queue engine in `VoiceReadoutService`. The real
/// `AVSpeechSynthesizer` produces no audio (and fires no reliable delegate
/// callbacks) in a headless runner, so these tests inject `onEmitForTesting`
/// to capture what *would* be spoken and drive completion by calling
/// `handleSegmentFinished()` directly — the same method the synthesizer
/// delegate calls in production.
@MainActor
final class VoiceReadoutServiceTests: XCTestCase {

    private final class Capture {
        var spoken: [AVSpeechUtterance] = []
        var logs: [String] = []
    }

    private func makeService(
        voiceAvailable: @escaping (String) -> Bool = { _ in true }
    ) -> (VoiceReadoutService, Capture) {
        let capture = Capture()
        let defaults = UserDefaults(suiteName: "voice-tests-\(UUID().uuidString)")!
        let service = VoiceReadoutService(
            voiceAvailable: voiceAvailable,
            defaults: defaults,
            configureAudioSession: {},               // no real audio session under test
            log: { capture.logs.append($0) }
        )
        service.onEmitForTesting = { capture.spoken.append($0) }
        return (service, capture)
    }

    func test_speakWhenDisabled_isNoOp() {
        let (service, capture) = makeService()
        service.isEnabled = false

        service.speak(.custom("hello", language: "en"))

        XCTAssertEqual(capture.spoken.count, 0, "disabled service must not emit speech")
        XCTAssertEqual(service.pendingCount, 0, "disabled service must not queue")
        XCTAssertFalse(service.isSpeaking)
    }

    func test_queueSerialisesUtterances() {
        let (service, capture) = makeService()

        service.speak(.custom("first", language: "en"))
        service.speak(.custom("second", language: "en"))

        // Only the first utterance is speaking; the second waits in the queue.
        XCTAssertEqual(capture.spoken.map(\.speechString), ["first"])
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertTrue(service.isSpeaking)

        // First finishes → the second advances, not before.
        service.handleSegmentFinished()
        XCTAssertEqual(capture.spoken.map(\.speechString), ["first", "second"])
        XCTAssertEqual(service.pendingCount, 0)

        // Second finishes → idle.
        service.handleSegmentFinished()
        XCTAssertFalse(service.isSpeaking)
    }

    func test_paFallsBackToEnglishWhenVoiceMissing() {
        // pa-IN absent, en-US present — the dose readout must speak English, not
        // go silent, and log the fallback.
        let (service, capture) = makeService(voiceAvailable: { $0 != "pa-IN" })

        service.speak(.dose(medication: "Lisinopril", dose: "10 mg",
                            time: "8:00 AM", foodRule: "with", language: "pa"))

        guard let first = capture.spoken.first else { return XCTFail("fallback spoke nothing") }
        XCTAssertEqual(first.voice?.language, "en-US", "fallback must use the English voice")
        XCTAssertTrue(first.speechString.contains("at 8:00 AM"),
                      "fallback must speak the English template, not the Punjabi one")
        XCTAssertTrue(capture.logs.contains { $0.contains("falling back to en-US") },
                      "[VOICE-DEBUG] fallback line must fire")
    }

    func test_paWithoutFallbackIsSkipped() {
        // A custom utterance has no English equivalent; with no pa-IN voice it is
        // skipped (and logged), preserving the legacy notification behaviour.
        let (service, capture) = makeService(voiceAvailable: { $0 != "pa-IN" })

        service.speak(.custom("ਸਤ ਸ੍ਰੀ ਅਕਾਲ", language: "pa"))

        XCTAssertEqual(capture.spoken.count, 0)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertTrue(capture.logs.contains { $0.contains("no English fallback") })
    }

    func test_stopClearsQueue() {
        let (service, _) = makeService()
        service.speak(.custom("a", language: "en"))
        service.speak(.custom("b", language: "en"))
        service.speak(.custom("c", language: "en"))
        XCTAssertEqual(service.pendingCount, 2)   // "a" speaking, "b"/"c" queued
        XCTAssertTrue(service.isSpeaking)

        service.stop()

        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(service.isSpeaking)
    }

    func test_enabledAndRatePersistToDefaults() {
        let defaults = UserDefaults(suiteName: "voice-persist-\(UUID().uuidString)")!
        let first = VoiceReadoutService(voiceAvailable: { _ in true }, defaults: defaults,
                                        configureAudioSession: {}, log: { _ in })
        first.isEnabled = false
        first.rate = .fast

        // A fresh service reading the same store restores the choices —
        // the @AppStorage-equivalent persistence the Settings controls rely on.
        let second = VoiceReadoutService(voiceAvailable: { _ in true }, defaults: defaults,
                                         configureAudioSession: {}, log: { _ in })
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(second.rate, .fast)
    }
}
