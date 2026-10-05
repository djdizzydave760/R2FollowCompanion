import Foundation
import AVFoundation
import Speech
import Combine

enum R2VoiceCommand: String {
    case speak = "R2 speak"
    case think = "R2 what do you think"
    case hello = "R2 hello"
    case happy = "R2 be happy"
    case excited = "R2 get excited"
    case alert = "R2 alert"
    case sleep = "R2 go to sleep"
    case wake = "R2 wake up"

    case lookLeft = "R2 look left"
    case lookRight = "R2 look right"
    case center = "R2 center"
    case scan = "R2 scan the area"

    case turnLeft = "R2 turn left"
    case turnRight = "R2 turn right"
    case spinLeft = "R2 spin left"
    case spinRight = "R2 spin right"
    case dance = "R2 dance"

    case lightsOn = "R2 lights on"
    case lightsOff = "R2 lights off"

    case resistance = "R2 resistance"
    case firstOrder = "R2 first order"
    case droidDepot = "R2 droid depot"

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
            newRequest.taskHint = .confirmation
            newRequest.contextualStrings = [
                "R2", "R two", "Artoo",
                "R2 speak", "R2 hello", "R2 what do you think",
                "R2 be happy", "R2 get excited", "R2 alert",
                "R2 go to sleep", "R2 wake up",
                "R2 look left", "R2 look right", "R2 center",
                "R2 scan the area", "R2 turn left", "R2 turn right",
                "R2 spin left", "R2 spin right", "R2 dance",
                "R2 lights on", "R2 lights off",
                "R2 resistance", "R2 first order", "R2 droid depot",
                "R2 follow me", "R2 stop following", "R2 stop"
            ]

            if recognizer.supportsOnDeviceRecognition {
                newRequest.requiresOnDeviceRecognition = true
                permissionStatus = "Microphone + on-device speech recognition ready"
            } else {
                permissionStatus = "Microphone ready • speech recognition may require internet"
            }

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
        guard text.contains("r2") ||
              text.contains("r two") ||
              text.contains("are two") ||
              text.contains("r too") ||
              text.contains("artoo") else {
            return
        }

        let command: R2VoiceCommand?

        // Most specific phrases first so "spin left" is not mistaken for "turn left",
        // and "stop following" is not mistaken for the emergency-stop command.
        if containsAny(text, ["stop following", "stop follow", "quit following"]) {
            command = .stopFollowing
        } else if containsAny(text, ["spin left", "spin counter clockwise", "spin counterclockwise"]) {
            command = .spinLeft
        } else if containsAny(text, ["spin right", "spin clockwise", "spin", "turn around"]) {
            command = .spinRight
        } else if containsAny(text, ["look left", "head left", "dome left"]) {
            command = .lookLeft
        } else if containsAny(text, ["look right", "head right", "dome right"]) {
            command = .lookRight
        } else if containsAny(text, ["scan the area", "scan area", "look around", "take a look around"]) {
            command = .scan
        } else if containsAny(text, ["turn left", "rotate left"]) {
            command = .turnLeft
        } else if containsAny(text, ["turn right", "rotate right"]) {
            command = .turnRight
        } else if containsAny(text, ["dance", "do a dance", "show me your moves"]) {
            command = .dance
        } else if containsAny(text, ["lights on", "turn your lights on", "turn lights on"]) {
            command = .lightsOn
        } else if containsAny(text, ["lights off", "turn your lights off", "turn lights off"]) {
            command = .lightsOff
        } else if containsAny(text, ["go to sleep", "go to bed", "sleep"]) {
            command = .sleep
        } else if containsAny(text, ["wake up", "wake", "good morning"]) {
            command = .wake
        } else if containsAny(text, ["first order"]) {
            command = .firstOrder
        } else if containsAny(text, ["resistance", "rebel", "rebellion"]) {
            command = .resistance
        } else if containsAny(text, ["droid depot", "batuu droid depot"]) {
            command = .droidDepot
        } else if containsAny(text, ["what do you think", "what you think", "are you curious"]) {
            command = .think
        } else if containsAny(text, ["be happy", "happy", "are you happy"]) {
            command = .happy
        } else if containsAny(text, ["get excited", "be excited", "excited"]) {
            command = .excited
        } else if containsAny(text, ["alert", "watch out", "danger"]) {
            command = .alert
        } else if containsAny(text, ["follow me", "start following"]) {
            command = .follow
        } else if containsAny(text, ["speak", "say something", "talk", "beep", "chirp"]) {
            command = .speak
        } else if containsAny(text, ["hello", "say hello", "hi r2", "greet me"]) {
            command = .hello
        } else if containsAny(text, ["center", "center your head", "center dome", "look forward"]) {
            command = .center
        } else if containsAny(text, ["stop", "emergency stop", "freeze", "hold it"]) {
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
