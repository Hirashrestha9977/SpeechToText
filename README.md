# VoiceToText

A small Swift package for iOS that listens to the microphone and turns speech into text. It wraps Apple's `Speech` and `AVFoundation` frameworks, handling permissions, the audio session and automatic stopping for you.

- Live (partial) results while the user speaks
- Stops on its own after a pause or a maximum duration
- Delegate, closure, `async`/`await` and SwiftUI (`ObservableObject`) APIs
- Microphone level for animating a meter
- Optional on-device recognition, automatic punctuation (iOS 16+) and custom vocabulary
- English and Nepali (Nepali through a speech-to-text API)

## Requirements

- iOS 13+
- Swift 5.7+ / Xcode 14+

## Installation

### Swift Package Manager

In Xcode, choose **File → Add Package Dependencies…** and enter:

```
https://github.com/Hirashrestha9977/SpeechToText
```

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Hirashrestha9977/SpeechToText", branch: "main")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "VoiceToText", package: "SpeechToText")
    ])
]
```

### XCFramework

To build a binary framework (device + simulator):

```sh
./scripts/build-xcframework.sh
```

The result is written to `build/VoiceToText.xcframework`. Drag it into your app target and set it to **Embed & Sign**.

### Info.plist

Your app **must** declare both usage descriptions, or iOS will terminate it the first time it asks for permission:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>We use the microphone to hear what you say.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>We convert your speech to text.</string>
```

## Usage

### SwiftUI

`VoiceToTextModel` requests permission on first use and publishes the transcript, state, audio level and any error.

```swift
import SwiftUI
import VoiceToText

struct ContentView: View {
    @StateObject private var speech = VoiceToTextModel()

    var body: some View {
        VStack {
            Text(speech.transcript)
            Button(speech.isListening ? "Stop" : "Speak") { speech.toggle() }
            if let error = speech.error {
                Text(error.localizedDescription).foregroundColor(.red)
            }
        }
    }
}
```

A complete screen with an animated microphone button is in [`Example/ContentView.swift`](Example/ContentView.swift).

### async/await

```swift
let voiceToText = VoiceToText()

guard await VoiceToText.requestAuthorization() == .authorized else { return }

// Get the final text once the user stops talking:
let text = try await voiceToText.listenOnce()

// Or stream live results:
for try await result in voiceToText.transcriptions() {
    label.text = result.text
}
```

Cancelling the enclosing `Task` cancels recognition.

### Closures

```swift
let voiceToText = VoiceToText(locale: Locale(identifier: "en-US"))

voiceToText.onResult = { result in label.text = result.text }
voiceToText.onFinish = { result in print("Final:", result?.text ?? "(nothing heard)") }
voiceToText.onError = { error in print(error.localizedDescription) }
voiceToText.onAudioLevel = { level in meter.progress = level }

VoiceToText.requestAuthorization { status in
    guard status == .authorized else { return }
    try? voiceToText.start()
}

// Later:
voiceToText.stop()    // stop and deliver the final result
voiceToText.cancel()  // stop and discard everything
```

### Delegate

Adopt `VoiceToTextDelegate` and implement only the methods you need:

```swift
extension ViewController: VoiceToTextDelegate {
    func voiceToText(_ voiceToText: VoiceToText, didUpdate result: VoiceToTextResult) { … }
    func voiceToText(_ voiceToText: VoiceToText, didFinishWith result: VoiceToTextResult?) { … }
    func voiceToText(_ voiceToText: VoiceToText, didFailWith error: VoiceToTextError) { … }
    func voiceToText(_ voiceToText: VoiceToText, didChange state: VoiceToTextState) { … }
    func voiceToText(_ voiceToText: VoiceToText, didUpdateAudioLevel level: Float) { … }
}
```

All callbacks are delivered on the main thread, and `VoiceToText` should be used from the main thread.

## Languages

Choose a language with `VoiceToTextLanguage`: `.english` or `.nepali`.

- **English** uses Apple's Speech framework, with live results.
- **Nepali** isn't supported by Apple, so the audio is recorded (16 kHz mono) and, when the user stops talking, sent to a `SpeechTranscriptionService`. The text arrives once, as a final result. Only microphone permission is needed.

`GoogleSpeechService` uses [Google Cloud Speech-to-Text](https://cloud.google.com/speech-to-text), which supports Nepali (`ne-NP`):

```swift
let service = GoogleSpeechService(apiKey: "YOUR_GOOGLE_CLOUD_API_KEY")

// SwiftUI
@StateObject private var speech = VoiceToTextModel(language: .nepali, transcriptionService: service)
speech.setLanguage(.english)   // switch at any time

// Or directly
let voiceToText = VoiceToText(language: .nepali, transcriptionService: service)
guard await voiceToText.requestAuthorization() == .authorized else { return }
let text = try await voiceToText.listenOnce()
```

An API key inside an app can be extracted. Restrict it to your bundle ID in the Google Cloud console, or call your own backend by implementing `SpeechTranscriptionService`:

```swift
struct MyBackendService: SpeechTranscriptionService {
    func transcribe(_ audio: VoiceToTextAudio, language: VoiceToTextLanguage) async throws -> String {
        var request = URLRequest(url: URL(string: "https://example.com/transcribe?lang=\(language.languageCode)")!)
        request.httpMethod = "POST"
        request.httpBody = audio.wavData   // or audio.pcmData (raw LINEAR16)
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}
```

Without a service, starting in Nepali throws `.transcriptionServiceRequired(.nepali)`; a failed API call is reported as `.transcriptionFailed(error)`.

## Options

Pass `VoiceToTextOptions` to `start(options:)`, `transcriptions(options:)`, `listenOnce(options:)` or `VoiceToTextModel(options:)`.

| Option | Default | Description |
| --- | --- | --- |
| `reportsPartialResults` | `true` | Deliver results while the user is still speaking. |
| `requiresOnDeviceRecognition` | `false` | Keep audio on the device. Throws `.onDeviceRecognitionUnsupported` if the locale has no on-device model. |
| `addsPunctuation` | `true` | Automatic punctuation (iOS 16+). |
| `contextualStrings` | `[]` | Names or terms likely to be spoken, to improve accuracy. |
| `taskHint` | `.dictation` | The kind of speech expected. |
| `silenceTimeout` | `2.0` | Stop after this many seconds without new words. `nil` disables it. |
| `maximumDuration` | `60` | Stop after this many seconds in total. `nil` disables it. Apple limits server-based recognition to about one minute. |
| `managesAudioSession` | `true` | Configure and activate `AVAudioSession` automatically. Set `false` if your app manages it. |

```swift
var options = VoiceToTextOptions()
options.silenceTimeout = 3
options.contextualStrings = ["SwiftUI", "Xcode"]
try voiceToText.start(options: options)
```

## Results

`VoiceToTextResult` contains:

- `text` — the best transcription so far
- `isFinal` — `true` once the recognizer won't revise it
- `segments` — words with `timestamp`, `duration` and `confidence` (confidence is 0 for partial results)
- `alternatives` — other possible transcriptions, most likely first

## States and errors

`VoiceToTextState` is `.idle`, `.listening` or `.finishing` (recording stopped, waiting for the final result).

`VoiceToTextError` conforms to `LocalizedError`, so `localizedDescription` gives a user-facing message. Cases include `.notAuthorized(status)`, `.unsupportedLocale`, `.recognizerUnavailable` (often no network), `.onDeviceRecognitionUnsupported`, `.alreadyListening`, `.noAudioInput`, `.audioSessionFailed`, `.audioEngineFailed`, `.recognitionFailed`, `.interrupted`, `.transcriptionServiceRequired` and `.transcriptionFailed`.

Useful helpers:

- `VoiceToText.authorizationStatus` — current combined speech + microphone permission
- `VoiceToText.supportedLocales` — every locale the device can transcribe
- `isAvailable`, `supportsOnDeviceRecognition` — per-instance recognizer checks

## Notes

- Speech recognition doesn't work in the iOS Simulator on all Macs; test on a real device.
- Audio interruptions (e.g. a phone call) and input changes (e.g. unplugging headphones) end the session gracefully, delivering whatever was recognized so far.

## Testing

The package is iOS-only, so run the tests on a simulator:

```sh
xcodebuild test -scheme VoiceToText -destination 'platform=iOS Simulator,name=iPhone 15'
```

## License

VoiceToText is available under the MIT License. See [LICENSE](LICENSE).
