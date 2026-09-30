import Foundation

/// The languages `VoiceToText` can transcribe.
///
/// English uses Apple's Speech framework. Nepali is not supported by Apple, so its
/// audio is recorded and sent to a `SpeechTranscriptionService` instead.
public enum VoiceToTextLanguage: String, CaseIterable, Identifiable {
    case english
    case nepali

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en-US")
        case .nepali: return Locale(identifier: "ne-NP")
        }
    }

    /// The BCP-47 language code, such as `ne-NP`, used by transcription APIs.
    public var languageCode: String {
        switch self {
        case .english: return "en-US"
        case .nepali: return "ne-NP"
        }
    }

    /// The language's name, written in that language.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .nepali: return "नेपाली"
        }
    }

    /// `true` when Apple's Speech framework transcribes this language on the device or
    /// Apple's servers; `false` when a `SpeechTranscriptionService` is required.
    public var usesSpeechFramework: Bool {
        switch self {
        case .english: return true
        case .nepali: return false
        }
    }
}
