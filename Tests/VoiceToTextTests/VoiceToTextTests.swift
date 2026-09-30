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
            .interrupted,
            .transcriptionServiceRequired(.nepali),
            .transcriptionFailed(URLError(.notConnectedToInternet))
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

    func testLanguages() {
        XCTAssertEqual(VoiceToTextLanguage.allCases, [.english, .nepali])
        XCTAssertEqual(VoiceToTextLanguage.english.locale.identifier, "en-US")
        XCTAssertEqual(VoiceToTextLanguage.nepali.languageCode, "ne-NP")
        XCTAssertTrue(VoiceToTextLanguage.english.usesSpeechFramework)
        XCTAssertFalse(VoiceToTextLanguage.nepali.usesSpeechFramework)
    }

    func testNepaliWithoutServiceThrows() throws {
        let voiceToText = VoiceToText(language: .nepali)
        XCTAssertFalse(voiceToText.isAvailable)
        guard voiceToText.authorizationStatus == .authorized else {
            throw XCTSkip("Microphone permission not granted")
        }
        XCTAssertThrowsError(try voiceToText.start()) { error in
            guard case VoiceToTextError.transcriptionServiceRequired(.nepali) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNepaliUsesService() {
        let voiceToText = VoiceToText(language: .nepali, transcriptionService: MockService(text: ""))
        XCTAssertTrue(voiceToText.isAvailable)
        XCTAssertFalse(voiceToText.supportsOnDeviceRecognition)
        XCTAssertEqual(voiceToText.locale.identifier, "ne-NP")
    }

    func testModelSwitchesLanguage() {
        let model = VoiceToTextModel(language: .english, transcriptionService: MockService(text: ""))
        XCTAssertEqual(model.recognizer.language, .english)
        model.setLanguage(.nepali)
        XCTAssertEqual(model.language, .nepali)
        XCTAssertEqual(model.recognizer.language, .nepali)
        XCTAssertEqual(model.state, .idle)
    }

    func testWavHeader() {
        let audio = VoiceToTextAudio(pcmData: Data(count: 32_000), sampleRate: 16_000)
        XCTAssertEqual(audio.duration, 1)
        let wav = audio.wavData
        XCTAssertEqual(wav.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
    }

    func testRecorderResamplesTo16kHzMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let recorder = try XCTUnwrap(AudioRecorder(inputFormat: format))
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            let data = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<4800 { data[i] = 0.5 * sin(Float(i) * 0.05) }
            recorder.append(buffer)
        }
        // One second at 48 kHz becomes about one second at 16 kHz.
        XCTAssertEqual(recorder.audio.sampleRate, 16_000)
        XCTAssertEqual(recorder.audio.duration, 1, accuracy: 0.05)
    }

    func testGoogleRequest() throws {
        let service = GoogleSpeechService(apiKey: "KEY")
        let audio = VoiceToTextAudio(pcmData: Data([1, 2, 3, 4]), sampleRate: 16_000)
        let request = try service.makeRequest(audio: audio, language: .nepali)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://speech.googleapis.com/v1/speech:recognize?key=KEY")
        let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let config = try XCTUnwrap(body["config"] as? [String: Any])
        XCTAssertEqual(config["languageCode"] as? String, "ne-NP")
        XCTAssertEqual(config["sampleRateHertz"] as? Int, 16_000)
        XCTAssertEqual(config["encoding"] as? String, "LINEAR16")
        XCTAssertEqual((body["audio"] as? [String: Any])?["content"] as? String, "AQIDBA==")
    }

    func testGoogleResponseParsing() throws {
        let json = #"{"results":[{"alternatives":[{"transcript":"नमस्ते","confidence":0.9}]},{"alternatives":[{"transcript":" संसार"}]}]}"#
        XCTAssertEqual(try GoogleSpeechService.transcript(from: Data(json.utf8)), "नमस्ते संसार")
        XCTAssertEqual(try GoogleSpeechService.transcript(from: Data("{}".utf8)), "")
    }

    private struct MockService: SpeechTranscriptionService {
        let text: String
        func transcribe(_ audio: VoiceToTextAudio, language: VoiceToTextLanguage) async throws -> String { text }
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
