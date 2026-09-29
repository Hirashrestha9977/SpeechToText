// Example SwiftUI screen. Copy into an iOS app that depends on the VoiceToText package,
// and add NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription to Info.plist.

import SwiftUI
import VoiceToText

struct ContentView: View {
    @StateObject private var speech = VoiceToTextModel()

    var body: some View {
        VStack(spacing: 24) {
            ScrollView {
                Text(speech.transcript.isEmpty ? "Tap the microphone and start speaking…" : speech.transcript)
                    .font(.title3)
                    .foregroundColor(speech.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            if let error = speech.error {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: speech.toggle) {
                Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .foregroundColor(speech.isListening ? .red : .accentColor)
                    .scaleEffect(1 + CGFloat(speech.audioLevel) * 0.3)
                    .animation(.easeOut(duration: 0.1), value: speech.audioLevel)
            }
            .accessibilityLabel(speech.isListening ? "Stop listening" : "Start listening")

            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var statusText: String {
        switch speech.state {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        }
    }
}
