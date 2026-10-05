import Foundation
import AVFoundation
import Speech
import Combine

enum R2VoiceCommand: String {
    case speak = "R2 speak"
    case think = "R2 what do you think"
    case spin = "R2 spin"
    case hello = "R2 hello"
    case excited = "R2 get excited"
    case center = "R2 center"
    case follow = "R2 follow me"
    case stopFollowing = "R2 stop following"
    case stop = "R2 stop"
}

@MainActor
final class VoiceCommandListener: ObservableObject {
    @Published var isListening = false
    @Published var transcript = "Voice commands off"
    @Published var lastCommand = "None"
    @Published var permissionStatus = "Not requested"

    var onCommand: ((R2VoiceCommand) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastHandledPhrase = ""
    private var lastHandledAt = Date.distantPast
    private var intentionalStop = false

    func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechAuthorized else {
            permissionStatus = "Speech recognition permission denied"
            return false
        }

        let microphoneAuthorized = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        guard microphoneAuthorized else {
            permissionStatus = "Microphone permission denied"
            return false
        }

        permissionStatus = "Microphone + speech recognition ready"
        return true
    }

    func start() async {
        guard !isListening else { return }

        guard await requestPermissions() else {
            isListening = false
            return
        }

        intentionalStop = false
        isListening = true
        startRecognitionSession()
    }

    func stop() {
        intentionalStop = true
        isListening = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcript = "Voice commands off"
    }

    private func startRecognitionSession() {
        guard isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            transcript = "Speech recognition is temporarily unavailable"
            isListening = false
            return
        }

        task?.cancel()
        task = nil
        request = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            request = newRequest

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak newRequest] buffer, _ in
                newRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            transcript = "Listening for “R2 …”"

            task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                guard let self else { return }

                Task { @MainActor in
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.transcript = text
                        self.handleTranscript(text)
                    }

                    if error != nil || result?.isFinal == true {
                        self.task = nil
                        self.request = nil

                        if self.audioEngine.isRunning {
                            self.audioEngine.stop()
                        }
                        self.audioEngine.inputNode.removeTap(onBus: 0)

                        if self.isListening && !self.intentionalStop {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            self.startRecognitionSession()
                        }
                    }
                }
            }
        } catch {
            transcript = "Voice listener error: \(error.localizedDescription)"
            isListening = false
        }
    }

    private func handleTranscript(_ raw: String) {
        let text = normalize(raw)
        guard text.contains("r2") || text.contains("r two") || text.contains("artoo") else {
            return
        }

        let command: R2VoiceCommand?

        if containsAny(text, ["stop following", "stop follow"]) {
            command = .stopFollowing
        } else if containsAny(text, ["what do you think", "what you think"]) {
            command = .think
        } else if containsAny(text, ["get excited", "be excited"]) {
            command = .excited
        } else if containsAny(text, ["follow me", "start following"]) {
            command = .follow
        } else if containsAny(text, ["speak", "say something", "talk"]) {
            command = .speak
        } else if containsAny(text, ["spin", "turn around"]) {
            command = .spin
        } else if containsAny(text, ["hello", "say hello", "hi r2"]) {
            command = .hello
        } else if containsAny(text, ["center", "center your head", "center dome"]) {
            command = .center
        } else if containsAny(text, ["stop", "emergency stop", "freeze"]) {
            command = .stop
        } else {
            command = nil
        }

        guard let command else { return }

        let now = Date()
        let phrase = command.rawValue
        if phrase == lastHandledPhrase && now.timeIntervalSince(lastHandledAt) < 1.75 {
            return
        }

        lastHandledPhrase = phrase
        lastHandledAt = now
        lastCommand = phrase
        onCommand?(command)
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}
