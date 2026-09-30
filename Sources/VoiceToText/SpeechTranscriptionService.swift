import AVFoundation
import Foundation

// MARK: - Audio

/// Audio recorded from the microphone, ready to upload to a transcription API.
public struct VoiceToTextAudio: Equatable {
    /// Mono, 16-bit signed little-endian PCM samples (`LINEAR16`).
    public let pcmData: Data
    /// Samples per second of `pcmData`.
    public let sampleRate: Int

    public init(pcmData: Data, sampleRate: Int) {
        self.pcmData = pcmData
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        Double(pcmData.count / 2) / Double(sampleRate)
    }

    /// `pcmData` wrapped in a WAV header, for APIs that expect an audio file.
    public var wavData: Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteRate = UInt32(sampleRate * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcmData.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))          // fmt chunk size
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(UInt32(sampleRate))
        append(byteRate)
        append(UInt16(2))           // block align
        append(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }
}

// MARK: - Service

/// Converts recorded speech to text with a remote API. Used for languages Apple's
/// Speech framework doesn't support, such as Nepali.
///
/// Implement this to use any provider; `GoogleSpeechService` is included.
public protocol SpeechTranscriptionService {
    /// Returns the text spoken in `audio`, or an empty string if nothing was recognized.
    func transcribe(_ audio: VoiceToTextAudio, language: VoiceToTextLanguage) async throws -> String
}

/// An error response from a transcription API.
public struct SpeechTranscriptionServiceError: Error, LocalizedError, Equatable {
    public let statusCode: Int
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? {
        "The transcription service returned an error (\(statusCode)): \(message)"
    }
}

// MARK: - Google Cloud Speech-to-Text

/// Transcribes speech with Google Cloud Speech-to-Text (`speech:recognize`), which supports Nepali.
///
/// Create an API key in the Google Cloud console with the Speech-to-Text API enabled.
/// A key shipped inside an app can be extracted, so restrict it to your app's bundle ID,
/// or implement `SpeechTranscriptionService` against your own backend instead.
///
/// The synchronous API accepts up to about one minute of audio, which matches the
/// default `VoiceToTextOptions.maximumDuration`.
public struct GoogleSpeechService: SpeechTranscriptionService {
    public let apiKey: String
    public var session: URLSession
    public var endpoint: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://speech.googleapis.com/v1/speech:recognize")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    public func transcribe(_ audio: VoiceToTextAudio, language: VoiceToTextLanguage) async throws -> String {
        let request = try makeRequest(audio: audio, language: language)
        let (data, response) = try await load(request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw SpeechTranscriptionServiceError(
                statusCode: statusCode,
                message: message ?? String(decoding: data, as: UTF8.self)
            )
        }
        return try Self.transcript(from: data)
    }

    func makeRequest(audio: VoiceToTextAudio, language: VoiceToTextLanguage) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bundleID = Bundle.main.bundleIdentifier {
            // Lets a key restricted to iOS apps accept the request.
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        request.httpBody = try JSONEncoder().encode(RecognizeRequest(
            config: .init(
                encoding: "LINEAR16",
                sampleRateHertz: audio.sampleRate,
                languageCode: language.languageCode,
                enableAutomaticPunctuation: true
            ),
            audio: .init(content: audio.pcmData.base64EncodedString())
        ))
        return request
    }

    static func transcript(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(RecognizeResponse.self, from: data)
        // Long audio comes back as several consecutive results.
        return (response.results ?? [])
            .compactMap { $0.alternatives?.first?.transcript }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // `URLSession.data(for:)` requires iOS 15.
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        final class TaskBox {
            var task: URLSessionDataTask?
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: error ?? URLError(.badServerResponse))
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private struct RecognizeRequest: Encodable {
        struct Config: Encodable {
            let encoding: String
            let sampleRateHertz: Int
            let languageCode: String
            let enableAutomaticPunctuation: Bool
        }
        struct Audio: Encodable {
            let content: String
        }
        let config: Config
        let audio: Audio
    }

    private struct RecognizeResponse: Decodable {
        struct Result: Decodable {
            struct Alternative: Decodable {
                let transcript: String?
            }
            let alternatives: [Alternative]?
        }
        let results: [Result]?
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable {
            let message: String
        }
        let error: Body
    }
}

// MARK: - Recording

/// Collects microphone buffers as 16 kHz mono 16-bit PCM. `append` is called from
/// the audio thread; `audio` from the main thread.
final class AudioRecorder {
    static let sampleRate = 16_000

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var pcmData = Data()

    init?(inputFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    var audio: VoiceToTextAudio {
        lock.lock()
        defer { lock.unlock() }
        return VoiceToTextAudio(pcmData: pcmData, sampleRate: Self.sampleRate)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                // Keep the converter's state so the next buffer continues seamlessly.
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }

        let data = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        lock.lock()
        pcmData.append(data)
        lock.unlock()
    }
}
