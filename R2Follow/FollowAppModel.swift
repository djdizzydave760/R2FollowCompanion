import Foundation
import UIKit
import Combine

@MainActor
final class FollowAppModel: ObservableObject {
    @Published var macHost: String {
        didSet { UserDefaults.standard.set(macHost, forKey: "macHost") }
    }
    @Published var macPort: String {
        didSet { UserDefaults.standard.set(macPort, forKey: "macPort") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }
    @Published var calibratedHeading: Double?
    @Published var isFollowing = false
    @Published var sequence = 0
    @Published var status = "Ready"

    let motion = MotionTracker()
    let bridge = MacBridge()
    let voice = VoiceCommandListener()

    private var sessionID = UUID().uuidString
    private var sendTimer: Timer?
    private var lastSentDistance = 0.0
    private var cancellables = Set<AnyCancellable>()

    init() {
        macHost = UserDefaults.standard.string(forKey: "macHost") ?? ""
        macPort = UserDefaults.standard.string(forKey: "macPort") ?? "8782"
        token = UserDefaults.standard.string(forKey: "token") ?? ""
        syncBridgeSettings()
        motion.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bridge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        voice.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        voice.onCommand = { [weak self] command in
            guard let self else { return }
            Task { @MainActor in
                await self.handleVoiceCommand(command)
            }
        }
    }

    func syncBridgeSettings() {
        bridge.host = macHost
        bridge.port = macPort
        bridge.token = token
    }

    func requestPermissions() {
        motion.requestPermissions()
    }

    func startVoiceCommands() async {
        syncBridgeSettings()
        await voice.start()
        if voice.isListening {
            status = "VOICE COMMANDS ON • say “R2 …”"
        } else {
            status = voice.permissionStatus
        }
    }

    func stopVoiceCommands() {
        voice.stop()
        status = "Voice commands off"
    }

    private func handleVoiceCommand(_ command: R2VoiceCommand) async {
        syncBridgeSettings()

        do {
            switch command {
            case .speak:
                try await bridge.chirp()
                status = "VOICE • R2 speak"

            case .think:
                try await bridge.reaction("Curious")
                status = "VOICE • R2 what do you think"

            case .hello:
                try await bridge.reaction("Greeting")
                status = "VOICE • R2 hello"

            case .happy:
                try await bridge.reaction("Happy")
                status = "VOICE • R2 be happy"

            case .excited:
                try await bridge.reaction("Excited")
                status = "VOICE • R2 get excited"

            case .alert:
                try await bridge.reaction("Alert")
                status = "VOICE • R2 alert"

            case .sleep:
                try await bridge.reaction("Sleep")
                status = "VOICE • R2 go to sleep"

            case .wake:
                try await bridge.action("wake")
                status = "VOICE • R2 wake up"

            case .lookLeft:
                try await bridge.action("look-left")
                status = "VOICE • R2 look left"

            case .lookRight:
                try await bridge.action("look-right")
                status = "VOICE • R2 look right"

            case .center:
                try await bridge.centerDome()
                status = "VOICE • R2 center"

            case .scan:
                try await bridge.action("scan")
                status = "VOICE • R2 scan the area"

            case .turnLeft:
                try await bridge.action("turn-left")
                status = "VOICE • R2 turn left"

            case .turnRight:
                try await bridge.action("turn-right")
                status = "VOICE • R2 turn right"

            case .spinLeft:
                try await bridge.action("spin-left")
                status = "VOICE • R2 spin left"

            case .spinRight:
                try await bridge.spin()
                status = "VOICE • R2 spin right"

            case .dance:
                try await bridge.action("dance")
                status = "VOICE • R2 dance"

            case .lightsOn:
                try await bridge.action("lights/on")
                status = "VOICE • R2 lights on"

            case .lightsOff:
                try await bridge.action("lights/off")
                status = "VOICE • R2 lights off"

            case .resistance:
                try await bridge.runScript(3)
                status = "VOICE • Resistance response"

            case .firstOrder:
                try await bridge.runScript(7)
                status = "VOICE • First Order response"

            case .droidDepot:
                try await bridge.runScript(2)
                status = "VOICE • Droid Depot response"

            case .follow:
                await startFollow()

            case .stopFollowing:
                await stopFollow()

            case .stop:
                await emergencyStop()
            }

            if command != .follow && command != .stopFollowing && command != .stop {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            status = "Voice command failed: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    func calibrate() {
        guard motion.headingAccuracy >= 0 else {
            status = "Waiting for a valid compass heading"
            return
        }
        calibratedHeading = motion.heading
        status = "Calibrated at \(Int(motion.heading.rounded()))°. Keep the phone in the same pocket orientation."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func testConnection() async {
        syncBridgeSettings()
        await bridge.testConnection()
        status = bridge.lastMessage
    }

    func startFollow() async {
        syncBridgeSettings()
        guard !macHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Enter your Mac IP address first"
            return
        }
        guard let calibratedHeading else {
            status = "Calibrate before starting Follow Me"
            return
        }

        let followStatus = await bridge.followStatus()
        if followStatus?.armed != true {
            status = "Arm Follow Me in Droid Control on the Mac first"
            return
        }
        if followStatus?.droidConnected != true {
            status = "Connect R2 to Droid Control first"
            return
        }

        sessionID = UUID().uuidString
        sequence = 0
        lastSentDistance = 0

        do {
            try await bridge.startFollow(FollowStartPayload(sessionID: sessionID, initialHeading: calibratedHeading))
            motion.startTracking()
            isFollowing = true
            UIApplication.shared.isIdleTimerDisabled = true
            status = "FOLLOWING • keep the iPhone app open and screen awake"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            beginTelemetryLoop()
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func stopFollow() async {
        sendTimer?.invalidate()
        sendTimer = nil
        motion.stopTracking()
        isFollowing = false
        UIApplication.shared.isIdleTimerDisabled = false
        await bridge.stopFollow()
        status = bridge.lastMessage
    }

    func emergencyStop() async {
        sendTimer?.invalidate()
        sendTimer = nil
        motion.stopTracking()
        isFollowing = false
        UIApplication.shared.isIdleTimerDisabled = false
        await bridge.emergencyStop()
        status = "EMERGENCY STOP SENT"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func beginTelemetryLoop() {
        sendTimer?.invalidate()
        sendTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self, self.isFollowing else { return }
            Task { @MainActor in
                await self.sendTelemetry()
            }
        }
    }

    private func sendTelemetry() async {
        sequence += 1
        let payload = FollowTelemetryPayload(
            sessionID: sessionID,
            sequence: sequence,
            timestamp: Date().timeIntervalSince1970,
            totalDistanceMeters: motion.totalDistance,
            headingDegrees: motion.heading,
            headingAccuracy: motion.headingAccuracy,
            moving: motion.moving
        )

        do {
            try await bridge.sendTelemetry(payload)
            status = String(
                format: "FOLLOWING • %.2fm walked • heading %.0f°",
                motion.totalDistance,
                motion.heading
            )
        } catch {
            let detail = error.localizedDescription

            sendTimer?.invalidate()
            sendTimer = nil
            motion.stopTracking()
            isFollowing = false
            UIApplication.shared.isIdleTimerDisabled = false

            // Preserve the actual network/server error instead of overwriting it
            // with a generic emergency-stop message. R2 is still stopped for safety.
            await bridge.emergencyStop()
            status = "Telemetry stopped: \(detail)"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
