import Combine
import Foundation

/// An `ObservableObject` wrapper around `VoiceToText` for SwiftUI.
///
///     @StateObject private var speech = VoiceToTextModel()
///
///     Text(speech.transcript)
///     Button(speech.isListening ? "Stop" : "Speak") { speech.toggle() }
public final class VoiceToTextModel: ObservableObject {
    /// Text recognized in the current or last session.
    @Published public private(set) var transcript: String = ""
    @Published public private(set) var state: VoiceToTextState = .idle
    /// Microphone level from 0 to 1 while listening.
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var error: VoiceToTextError?
    @Published public private(set) var authorizationStatus: VoiceToTextAuthorizationStatus
    /// The selected language, or `nil` when created with a custom locale. Change it with `setLanguage(_:)`.
    @Published public private(set) var language: VoiceToTextLanguage?

    public var isListening: Bool { state == .listening }

    public var options: VoiceToTextOptions
    public private(set) var recognizer: VoiceToText
    /// Used for languages Apple's Speech framework doesn't support, such as Nepali.
    public let transcriptionService: SpeechTranscriptionService?

    public init(locale: Locale = .current, options: VoiceToTextOptions = VoiceToTextOptions()) {
        self.recognizer = VoiceToText(locale: locale)
        self.options = options
        self.transcriptionService = nil
        self.authorizationStatus = recognizer.authorizationStatus
        bind(recognizer)
    }

    ///     @StateObject private var speech = VoiceToTextModel(
    ///         language: .nepali,
    ///         transcriptionService: GoogleSpeechService(apiKey: "…")
    ///     )
    public init(
        language: VoiceToTextLanguage,
        transcriptionService: SpeechTranscriptionService? = nil,
        options: VoiceToTextOptions = VoiceToTextOptions()
    ) {
        self.recognizer = VoiceToText(language: language, transcriptionService: transcriptionService)
        self.language = language
        self.options = options
        self.transcriptionService = transcriptionService
        self.authorizationStatus = recognizer.authorizationStatus
        bind(recognizer)
    }

    /// Switches language, cancelling any session in progress.
    public func setLanguage(_ language: VoiceToTextLanguage) {
        guard language != self.language else { return }
        recognizer.cancel()
        recognizer = VoiceToText(language: language, transcriptionService: transcriptionService)
        bind(recognizer)
        self.language = language
        authorizationStatus = recognizer.authorizationStatus
        state = .idle
        audioLevel = 0
        error = nil
    }

    /// Requests permission if needed, then starts listening.
    public func start() {
        error = nil
        authorizationStatus = recognizer.authorizationStatus
        guard authorizationStatus == .authorized else {
            let recognizer = self.recognizer
            recognizer.requestAuthorization { [weak self] status in
                guard let self = self, self.recognizer === recognizer else { return }
                self.authorizationStatus = status
                if status == .authorized {
                    self.beginListening()
                } else {
                    self.error = .notAuthorized(status)
                }
            }
            return
        }
        beginListening()
    }

    public func stop() {
        recognizer.stop()
    }

    public func toggle() {
        state == .idle ? start() : stop()
    }

    public func reset() {
        recognizer.cancel()
        transcript = ""
        error = nil
    }

    private func bind(_ recognizer: VoiceToText) {
        recognizer.onResult = { [weak self] in self?.transcript = $0.text }
        recognizer.onFinish = { [weak self] result in
            if let result = result { self?.transcript = result.text }
        }
        recognizer.onError = { [weak self] in self?.error = $0 }
        recognizer.onStateChange = { [weak self] state in
            self?.state = state
            if state != .listening { self?.audioLevel = 0 }
        }
        recognizer.onAudioLevel = { [weak self] in self?.audioLevel = $0 }
    }

    private func beginListening() {
        transcript = ""
        do {
            try recognizer.start(options: options)
        } catch let error as VoiceToTextError {
            self.error = error
        } catch {
            self.error = .recognitionFailed(error)
        }
    }
}
