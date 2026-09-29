import AVFoundation
import Speech
import XCTest
@testable import VoiceToText

final class VoiceToTextTests: XCTestCase {

    func testDefaultOptions() {
        let options = VoiceToTextOptions()
        XCTAssertTrue(options.reportsPartialResults)
        XCTAssertFalse(options.requiresOnDeviceRecognition)
        XCTAssertEqual(options.silenceTimeout, 2.0)
        XCTAssertEqual(options.maximumDuration, 60)
        XCTAssertTrue(options.managesAudioSession)
    }

    func testAuthorizationCombination() {
        XCTAssertEqual(VoiceToText.combine(speech: .authorized, microphone: .granted), .authorized)
        XCTAssertEqual(VoiceToText.combine(speech: .authorized, microphone: .denied), .microphoneDenied)
        XCTAssertEqual(VoiceToText.combine(speech: .authorized, microphone: .undetermined), .notDetermined)
        XCTAssertEqual(VoiceToText.combine(speech: .denied, microphone: .granted), .speechRecognitionDenied)
        XCTAssertEqual(VoiceToText.combine(speech: .restricted, microphone: .granted), .restricted)
        XCTAssertEqual(VoiceToText.combine(speech: .notDetermined, microphone: .granted), .notDetermined)
    }

    func testStartWithoutPermissionThrows() throws {
        guard VoiceToText.authorizationStatus != .authorized else {
            throw XCTSkip("Permission already granted on this device")
        }
        let voiceToText = VoiceToText(locale: Locale(identifier: "en-US"))
        XCTAssertThrowsError(try voiceToText.start()) { error in
            guard case VoiceToTextError.notAuthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(voiceToText.state, .idle)
    }

    func testStopAndCancelWhenIdleAreNoOps() {
        let voiceToText = VoiceToText(locale: Locale(identifier: "en-US"))
        voiceToText.stop()
        voiceToText.cancel()
        XCTAssertEqual(voiceToText.state, .idle)
        XCTAssertNil(voiceToText.latestResult)
    }

    func testAudioLevelOfSilenceIsZero() throws {
        let buffer = try makeBuffer { _ in 0 }
        XCTAssertEqual(VoiceToText.normalizedLevel(of: buffer), 0)
    }

    func testAudioLevelOfFullScaleIsOne() throws {
        let buffer = try makeBuffer { _ in 1 }
        XCTAssertEqual(VoiceToText.normalizedLevel(of: buffer), 1, accuracy: 0.001)
    }

    func testAudioLevelIsBetweenZeroAndOne() throws {
        let buffer = try makeBuffer { i in 0.05 * sin(Float(i) * 0.1) }
        let level = VoiceToText.normalizedLevel(of: buffer)
        XCTAssertGreaterThan(level, 0)
        XCTAssertLessThan(level, 1)
    }

    func testNoSpeechErrorDetection() {
        XCTAssertTrue(VoiceToText.isNoSpeechError(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        XCTAssertFalse(VoiceToText.isNoSpeechError(NSError(domain: "kAFAssistantErrorDomain", code: 203)))
        XCTAssertFalse(VoiceToText.isNoSpeechError(NSError(domain: NSCocoaErrorDomain, code: 1110)))
    }

    func testErrorsHaveDescriptions() {
        let errors: [VoiceToTextError] = [
            .notAuthorized(.microphoneDenied),
            .unsupportedLocale(Locale(identifier: "xx-XX")),
            .recognizerUnavailable,
            .onDeviceRecognitionUnsupported,
            .alreadyListening,
            .noAudioInput,
            .interrupted
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testModelStartsIdle() {
        let model = VoiceToTextModel(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.transcript, "")
        XCTAssertFalse(model.isListening)
    }

    private func makeBuffer(sample: (Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<1024 { data[i] = sample(i) }
        return buffer
    }
}
