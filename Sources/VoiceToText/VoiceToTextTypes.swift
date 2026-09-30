import Foundation
import Speech

// MARK: - Result

/// A transcription produced from the user's speech.
public struct VoiceToTextResult: Equatable {
    /// A single recognized word or phrase with timing information.
    public struct Segment: Equatable {
        public let text: String
        /// Offset from the start of the audio, in seconds.
        public let timestamp: TimeInterval
        public let duration: TimeInterval
        /// Confidence between 0 and 1. It is 0 for partial (non-final) results.
        public let confidence: Float

        public init(text: String, timestamp: TimeInterval, duration: TimeInterval, confidence: Float) {
            self.text = text
            self.timestamp = timestamp
            self.duration = duration
            self.confidence = confidence
        }
    }

    /// The best transcription of everything heard so far.
    public let text: String
    /// `true` when the recognizer will not revise this result any further.
    public let isFinal: Bool
    public let segments: [Segment]
    /// Other possible transcriptions, most likely first (excludes `text`).
    public let alternatives: [String]

    public init(text: String, isFinal: Bool, segments: [Segment] = [], alternatives: [String] = []) {
        self.text = text
        self.isFinal = isFinal
        self.segments = segments
        self.alternatives = alternatives
    }

    init(_ result: SFSpeechRecognitionResult) {
        let best = result.bestTranscription
        self.text = best.formattedString
        self.isFinal = result.isFinal
        self.segments = best.segments.map {
            Segment(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration, confidence: $0.confidence)
        }
        self.alternatives = result.transcriptions
            .map(\.formattedString)
            .filter { $0 != best.formattedString }
    }
}

// MARK: - Options

/// Settings for a listening session.
public struct VoiceToTextOptions {
    /// Deliver results while the user is still speaking. Default `true`.
    public var reportsPartialResults: Bool = true
    /// Keep audio on the device. Fails with `.onDeviceRecognitionUnsupported`
    /// if the locale has no on-device model. Default `false`.
    public var requiresOnDeviceRecognition: Bool = false
    /// Add punctuation automatically (iOS 16+; ignored on earlier versions). Default `true`.
    public var addsPunctuation: Bool = true
    /// Words or phrases likely to be spoken, such as names or product terms.
    public var contextualStrings: [String] = []
    /// The kind of speech expected, which helps accuracy.
    public var taskHint: SFSpeechRecognitionTaskHint = .dictation
    /// Stop automatically after this many seconds with no new words. `nil` disables it.
    public var silenceTimeout: TimeInterval? = 2.0
    /// Stop automatically after this many seconds in total. `nil` disables it.
    /// Apple limits server-based recognition to about one minute per request.
    public var maximumDuration: TimeInterval? = 60
    /// Configure and activate the shared `AVAudioSession` automatically. Default `true`.
    /// Set to `false` if your app manages the audio session itself.
    public var managesAudioSession: Bool = true

    public init() {}
}

// MARK: - State

public enum VoiceToTextState: Equatable {
    /// Not recording.
    case idle
    /// Recording from the microphone and transcribing.
    case listening
    /// Recording stopped; waiting for the recognizer's final result.
    case finishing
}

// MARK: - Authorization

public enum VoiceToTextAuthorizationStatus: Equatable {
    /// Both speech recognition and microphone access are granted.
    case authorized
    /// The user has not been asked yet.
    case notDetermined
    /// The user denied speech recognition.
    case speechRecognitionDenied
    /// The user denied microphone access.
    case microphoneDenied
    /// Speech recognition is restricted on this device (for example by Screen Time).
    case restricted
}

// MARK: - Errors

public enum VoiceToTextError: Error, LocalizedError {
    case notAuthorized(VoiceToTextAuthorizationStatus)
    case unsupportedLocale(Locale)
    case recognizerUnavailable
    case onDeviceRecognitionUnsupported
    case alreadyListening
    case noAudioInput
    case audioSessionFailed(Error)
    case audioEngineFailed(Error)
    case recognitionFailed(Error)
    case interrupted
    /// The language needs a `SpeechTranscriptionService` but none was provided.
    case transcriptionServiceRequired(VoiceToTextLanguage)
    /// The `SpeechTranscriptionService` failed, for example because of a network error.
    case transcriptionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized(let status):
            switch status {
            case .microphoneDenied: return "Microphone access was denied. Enable it in Settings."
            case .speechRecognitionDenied: return "Speech recognition was denied. Enable it in Settings."
            case .restricted: return "Speech recognition is restricted on this device."
            case .notDetermined: return "Permission has not been requested. Call requestAuthorization first."
            case .authorized: return "Not authorized."
            }
        case .unsupportedLocale(let locale):
            return "Speech recognition does not support the locale \(locale.identifier)."
        case .recognizerUnavailable:
            return "Speech recognition is currently unavailable. Check the network connection."
        case .onDeviceRecognitionUnsupported:
            return "On-device speech recognition is not supported for this language on this device."
        case .alreadyListening:
            return "Already listening."
        case .noAudioInput:
            return "No microphone input is available."
        case .audioSessionFailed(let error):
            return "Could not configure the audio session: \(error.localizedDescription)"
        case .audioEngineFailed(let error):
            return "Could not start recording: \(error.localizedDescription)"
        case .recognitionFailed(let error):
            return "Speech recognition failed: \(error.localizedDescription)"
        case .interrupted:
            return "Recording was interrupted."
        case .transcriptionServiceRequired(let language):
            return "\(language.displayName) needs a transcription service. Pass one when creating VoiceToText."
        case .transcriptionFailed(let error):
            return "Could not convert speech to text: \(error.localizedDescription)"
        }
    }
}
