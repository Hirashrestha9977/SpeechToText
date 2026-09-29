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

    public var isListening: Bool { state == .listening }

    public var options: VoiceToTextOptions
    public let recognizer: VoiceToText

    public init(locale: Locale = .current, options: VoiceToTextOptions = VoiceToTextOptions()) {
        self.recognizer = VoiceToText(locale: locale)
        self.options = options
        self.authorizationStatus = VoiceToText.authorizationStatus

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

    /// Requests permission if needed, then starts listening.
    public func start() {
        error = nil
        guard authorizationStatus == .authorized else {
            VoiceToText.requestAuthorization { [weak self] status in
                guard let self = self else { return }
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
