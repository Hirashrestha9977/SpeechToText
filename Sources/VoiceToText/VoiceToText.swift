import AVFoundation
import Foundation
import Speech

/// Receives events from a `VoiceToText` recognizer. All methods are optional
/// and are called on the main thread.
public protocol VoiceToTextDelegate: AnyObject {
    /// New or revised text while the user is speaking.
    func voiceToText(_ voiceToText: VoiceToText, didUpdate result: VoiceToTextResult)
    /// The session ended. `result` is `nil` if nothing was recognized.
    func voiceToText(_ voiceToText: VoiceToText, didFinishWith result: VoiceToTextResult?)
    func voiceToText(_ voiceToText: VoiceToText, didFailWith error: VoiceToTextError)
    func voiceToText(_ voiceToText: VoiceToText, didChange state: VoiceToTextState)
    /// Microphone input level from 0 (silent) to 1 (loud), useful for animating a meter.
    func voiceToText(_ voiceToText: VoiceToText, didUpdateAudioLevel level: Float)
}

public extension VoiceToTextDelegate {
    func voiceToText(_ voiceToText: VoiceToText, didUpdate result: VoiceToTextResult) {}
    func voiceToText(_ voiceToText: VoiceToText, didFinishWith result: VoiceToTextResult?) {}
    func voiceToText(_ voiceToText: VoiceToText, didFailWith error: VoiceToTextError) {}
    func voiceToText(_ voiceToText: VoiceToText, didChange state: VoiceToTextState) {}
    func voiceToText(_ voiceToText: VoiceToText, didUpdateAudioLevel level: Float) {}
}

/// Listens to the microphone and converts speech to text.
///
/// Use it from the main thread. Events are delivered on the main thread through
/// the `delegate`, the `on…` closures, or `transcriptions()`, whichever you prefer.
///
/// The host app's Info.plist must contain `NSMicrophoneUsageDescription` and
/// `NSSpeechRecognitionUsageDescription`, or iOS terminates the app on first use.
public final class VoiceToText {

    // MARK: Public properties

    public weak var delegate: VoiceToTextDelegate?

    public var onResult: ((VoiceToTextResult) -> Void)?
    public var onFinish: ((VoiceToTextResult?) -> Void)?
    public var onError: ((VoiceToTextError) -> Void)?
    public var onStateChange: ((VoiceToTextState) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?

    public let locale: Locale
    public private(set) var state: VoiceToTextState = .idle
    /// The most recent result of the current or last session.
    public private(set) var latestResult: VoiceToTextResult?

    public var isListening: Bool { state == .listening }

    /// Whether the recognizer can be used right now (it may need a network connection).
    public var isAvailable: Bool { speechRecognizer?.isAvailable ?? false }

    /// Whether this locale can be transcribed without sending audio to Apple's servers.
    public var supportsOnDeviceRecognition: Bool {
        speechRecognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: Private properties

    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var options = VoiceToTextOptions()
    /// Incremented each session so late callbacks from an old task are ignored.
    private var sessionID = 0
    private var silenceTimer: Timer?
    private var maximumDurationTimer: Timer?
    private var finishingTimer: Timer?
    private var streamContinuation: AsyncThrowingStream<VoiceToTextResult, Error>.Continuation?
    private var observers: [NSObjectProtocol] = []

    // MARK: Init

    /// - Parameter locale: The language to recognize. Defaults to the device's language.
    public init(locale: Locale = .current) {
        self.locale = locale
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.speechRecognizer?.defaultTaskHint = .dictation
        observeAudioSession()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        task?.cancel()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    /// Every locale the device can transcribe.
    public static var supportedLocales: Set<Locale> {
        SFSpeechRecognizer.supportedLocales()
    }

    // MARK: Authorization

    /// The combined speech recognition and microphone permission status.
    public static var authorizationStatus: VoiceToTextAuthorizationStatus {
        combine(speech: SFSpeechRecognizer.authorizationStatus(), microphone: microphonePermission)
    }

    /// Asks the user for speech recognition and microphone permission if needed.
    /// The completion handler is called on the main thread.
    public static func requestAuthorization(completion: @escaping (VoiceToTextAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    completion(combine(speech: speechStatus, microphone: microphonePermission))
                }
                return
            }
            requestMicrophonePermission { _ in
                DispatchQueue.main.async {
                    completion(combine(speech: speechStatus, microphone: microphonePermission))
                }
            }
        }
    }

    /// Asks the user for speech recognition and microphone permission if needed.
    public static func requestAuthorization() async -> VoiceToTextAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    // MARK: Listening

    /// Starts recording and transcribing. Stops on its own after the silence timeout
    /// or maximum duration in `options`, or when you call `stop()`.
    public func start(options: VoiceToTextOptions = VoiceToTextOptions()) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .idle else { throw VoiceToTextError.alreadyListening }

        let status = Self.authorizationStatus
        guard status == .authorized else { throw VoiceToTextError.notAuthorized(status) }
        guard let recognizer = speechRecognizer else { throw VoiceToTextError.unsupportedLocale(locale) }
        guard recognizer.isAvailable else { throw VoiceToTextError.recognizerUnavailable }
        if options.requiresOnDeviceRecognition && !recognizer.supportsOnDeviceRecognition {
            throw VoiceToTextError.onDeviceRecognitionUnsupported
        }

        self.options = options
        sessionID += 1
        latestResult = nil

        if options.managesAudioSession {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                throw VoiceToTextError.audioSessionFailed(error)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = options.reportsPartialResults
        request.requiresOnDeviceRecognition = options.requiresOnDeviceRecognition
        request.contextualStrings = options.contextualStrings
        request.taskHint = options.taskHint
        if #available(iOS 16, *) {
            request.addsPunctuation = options.addsPunctuation
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudioSession()
            throw VoiceToTextError.noAudioInput
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            let level = Self.normalizedLevel(of: buffer)
            DispatchQueue.main.async { self?.emitAudioLevel(level) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            deactivateAudioSession()
            throw VoiceToTextError.audioEngineFailed(error)
        }

        let session = sessionID
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(result: result, error: error, session: session)
            }
        }

        setState(.listening)
        resetSilenceTimer()
        if let maximumDuration = options.maximumDuration {
            maximumDurationTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
                self?.stop()
            }
        }
    }

    /// Stops recording. The final result is delivered shortly afterwards through
    /// `onFinish` / `didFinishWith`.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .listening else { return }

        stopAudio()
        request?.endAudio()
        setState(.finishing)

        // Don't wait forever if the recognizer never delivers a final result.
        finishingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.task?.cancel()
            self.finish(with: self.latestResult)
        }
    }

    /// Stops immediately and discards any pending result. No finish or error event is sent.
    public func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .idle else { return }
        task?.cancel()
        teardown()
        streamContinuation?.finish()
        streamContinuation = nil
        setState(.idle)
    }

    /// Starts listening and returns the results as an async stream. The stream
    /// finishes when the session ends and throws `VoiceToTextError` on failure.
    /// Cancelling the enclosing task cancels the recognition.
    ///
    ///     for try await result in voiceToText.transcriptions() {
    ///         label.text = result.text
    ///     }
    public func transcriptions(options: VoiceToTextOptions = VoiceToTextOptions()) -> AsyncThrowingStream<VoiceToTextResult, Error> {
        AsyncThrowingStream { continuation in
            do {
                try self.start(options: options)
                self.streamContinuation = continuation
                continuation.onTermination = { [weak self] termination in
                    guard case .cancelled = termination else { return }
                    DispatchQueue.main.async { self?.cancel() }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Listens until the user stops talking and returns the final text.
    @MainActor
    public func listenOnce(options: VoiceToTextOptions = VoiceToTextOptions()) async throws -> String {
        var text = ""
        for try await result in transcriptions(options: options) {
            text = result.text
        }
        return text
    }

    // MARK: Recognition handling

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, session: Int) {
        guard session == sessionID, state != .idle else { return }

        if let result = result {
            let converted = VoiceToTextResult(result)
            latestResult = converted
            if state == .listening { resetSilenceTimer() }
            emitResult(converted)
            if result.isFinal {
                finish(with: converted)
                return
            }
        }

        guard let error = error else { return }
        if state == .finishing || Self.isNoSpeechError(error) {
            // Ending without speech, or the recognizer closing after stop(), is not a failure.
            finish(with: latestResult)
        } else {
            fail(.recognitionFailed(error))
        }
    }

    private func finish(with result: VoiceToTextResult?) {
        guard state != .idle else { return }
        teardown()
        setState(.idle)
        delegate?.voiceToText(self, didFinishWith: result)
        onFinish?(result)
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func fail(_ error: VoiceToTextError) {
        guard state != .idle else { return }
        task?.cancel()
        teardown()
        setState(.idle)
        delegate?.voiceToText(self, didFailWith: error)
        onError?(error)
        streamContinuation?.finish(throwing: error)
        streamContinuation = nil
    }

    // MARK: Events

    private func setState(_ newState: VoiceToTextState) {
        guard state != newState else { return }
        state = newState
        delegate?.voiceToText(self, didChange: newState)
        onStateChange?(newState)
    }

    private func emitResult(_ result: VoiceToTextResult) {
        delegate?.voiceToText(self, didUpdate: result)
        onResult?(result)
        streamContinuation?.yield(result)
    }

    private func emitAudioLevel(_ level: Float) {
        guard state == .listening else { return }
        delegate?.voiceToText(self, didUpdateAudioLevel: level)
        onAudioLevel?(level)
    }

    // MARK: Cleanup

    private func stopAudio() {
        invalidateTimers(keepFinishing: true)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func teardown() {
        stopAudio()
        invalidateTimers(keepFinishing: false)
        request?.endAudio()
        request = nil
        task = nil
        sessionID += 1
        deactivateAudioSession()
    }

    private func invalidateTimers(keepFinishing: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        maximumDurationTimer?.invalidate()
        maximumDurationTimer = nil
        if !keepFinishing {
            finishingTimer?.invalidate()
            finishingTimer = nil
        }
    }

    private func deactivateAudioSession() {
        guard options.managesAudioSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        guard let timeout = options.silenceTimeout else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began,
                  self.state == .listening else { return }
            if self.latestResult == nil {
                self.fail(.interrupted)
            } else {
                self.stop()
            }
        })
        // The input device changed (e.g. headphones unplugged); the tap's format is no longer valid.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            // The engine stops itself when the configuration changes; ignore spurious notifications.
            guard let self = self, !self.audioEngine.isRunning else { return }
            self.stop()
        })
    }

    // MARK: Helpers

    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            sum += samples[i] * samples[i]
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let minimumDecibels: Float = -50
        return min(max((decibels - minimumDecibels) / -minimumDecibels, 0), 1)
    }

    static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // 1110: "No speech detected" from the speech service.
        return nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
    }

    static func combine(
        speech: SFSpeechRecognizerAuthorizationStatus,
        microphone: MicrophonePermission
    ) -> VoiceToTextAuthorizationStatus {
        switch speech {
        case .denied: return .speechRecognitionDenied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .authorized: break
        @unknown default: return .restricted
        }
        switch microphone {
        case .granted: return .authorized
        case .denied: return .microphoneDenied
        case .undetermined: return .notDetermined
        }
    }

    enum MicrophonePermission {
        case granted, denied, undetermined
    }

    private static var microphonePermission: MicrophonePermission {
        if #available(iOS 17, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    private static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }
}
