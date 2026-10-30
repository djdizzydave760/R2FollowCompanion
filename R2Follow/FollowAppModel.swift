import Foundation
import UIKit
import Combine

enum ConnectionMode: String, CaseIterable, Identifiable {
    case directBluetooth = "Direct Bluetooth"
    case macBridge = "Mac Bridge"

    var id: String { rawValue }
}

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

    @Published var connectionMode: ConnectionMode {
        didSet { UserDefaults.standard.set(connectionMode.rawValue, forKey: "connectionMode") }
    }

    @Published var calibratedHeading: Double?
    @Published var isFollowing = false
    @Published var sequence = 0
    @Published var status = "Ready"

    let motion = MotionTracker()
    let bridge = MacBridge()
    let voice = VoiceCommandListener()
    let directBLE = DirectDroidBLE()
    lazy var directFollow = DirectShadowFollowController(droid: directBLE)

    private var sessionID = UUID().uuidString
    private var sendTimer: Timer?
    private var lifeTimer: Timer?
    private var nextIdleBlink = Date.distantPast
    private var nextIdleHead = Date.distantPast
    private var nextIdleChirp = Date.distantPast
    private var lastSentDistance = 0.0
    private var cancellables = Set<AnyCancellable>()

    init() {
        macHost = UserDefaults.standard.string(forKey: "macHost") ?? ""
        macPort = UserDefaults.standard.string(forKey: "macPort") ?? "8782"
        token = UserDefaults.standard.string(forKey: "token") ?? ""

        let storedMode = UserDefaults.standard.string(forKey: "connectionMode")
        connectionMode = ConnectionMode(rawValue: storedMode ?? "") ?? .directBluetooth

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

        directBLE.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        directFollow.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        voice.onCommand = { [weak self] command in
            guard let self else { return }
            Task { @MainActor in
                await self.handleVoiceCommand(command)
            }
        }

        directBLE.onDisconnected = { [weak self] in
            guard let self else { return }
            if self.connectionMode == .directBluetooth {
                self.stopLocalFollowAfterBluetoothLoss()
            }
        }

        beginDroidLifeLoop()
    }

    func syncBridgeSettings() {
        bridge.host = macHost
        bridge.port = macPort
        bridge.token = token
    }

    func requestPermissions() {
        motion.requestPermissions()
    }

    // MARK: - Direct Bluetooth

    func scanForR2() {
        guard !isFollowing else {
            status = "Stop Follow before scanning for another R2"
            return
        }
        directBLE.scan()
    }

    func connectDirectDroid(_ device: DirectDroidDevice) {
        guard !isFollowing else { return }
        directBLE.connect(device)
        status = "Connecting directly to R2…"
    }

    func disconnectDirectDroid() {
        if isFollowing && connectionMode == .directBluetooth {
            directFollow.emergencyStop()
            finishFollowLocally()
        }
        directBLE.disconnect()
        status = "Direct Bluetooth disconnected"
    }

    private func stopLocalFollowAfterBluetoothLoss() {
        sendTimer?.invalidate()
        sendTimer = nil
        motion.stopTracking()
        isFollowing = false
        UIApplication.shared.isIdleTimerDisabled = false
        directFollow.stop(reason: "Bluetooth lost")
        status = "DIRECT FOLLOW STOPPED • Bluetooth connection lost"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - Always-on R2 personality

    private func beginDroidLifeLoop() {
        lifeTimer?.invalidate()
        nextIdleBlink = Date().addingTimeInterval(0.8)
        nextIdleHead = Date().addingTimeInterval(2.0)
        nextIdleChirp = Date().addingTimeInterval(4.0)

        lifeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                guard self.connectionMode == .directBluetooth,
                      self.directBLE.isConnected,
                      !self.isFollowing else {
                    return
                }

                let now = Date()

                if now >= self.nextIdleBlink {
                    self.directBLE.naturalFollowBlink()
                    self.nextIdleBlink = now.addingTimeInterval(Double.random(in: 0.7...2.2))
                }

                if now >= self.nextIdleHead {
                    self.directBLE.ambientDomeGlance()
                    self.nextIdleHead = now.addingTimeInterval(Double.random(in: 2.5...5.5))
                }

                if now >= self.nextIdleChirp {
                    self.directBLE.chirp(bank: 1)
                    self.nextIdleChirp = now.addingTimeInterval(Double.random(in: 5.0...10.0))
                }
            }
        }
    }

    // MARK: - R2 pre-follow calibration

    func calibrateTwoFootStop() {
        guard connectionMode == .directBluetooth, directBLE.isConnected else {
            status = "Connect R2 directly over Bluetooth first"
            return
        }

        let value = directBLE.smoothedRSSI
        guard value < 0, value > -120 else {
            status = "Waiting for a stable Bluetooth distance reading"
            return
        }

        directFollow.calibrateTwoFootStop(usingRSSI: value)
        status = String(
            format: "2-FOOT STOP SET • %.0f dBm • keep phone position consistent",
            value
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func markR2AlignedWithPhone() {
        guard connectionMode == .directBluetooth else {
            calibrate()
            return
        }

        guard directBLE.isConnected else {
            status = "Connect R2 over Bluetooth before calibrating"
            return
        }

        guard motion.headingAccuracy >= 0 else {
            status = "Waiting for a valid compass heading"
            return
        }

        calibratedHeading = motion.heading
        directFollow.setReferenceHeading(motion.heading)
        status = "R2 aligned • \(Int(motion.heading.rounded()))° • test forward next"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func testR2Forward() {
        guard connectionMode == .directBluetooth, directBLE.isConnected, !isFollowing else {
            status = "Connect R2 directly and stop Follow before testing"
            return
        }

        directBLE.calibrationForwardPulse(
            speed: UInt8(clamping: Int(directFollow.driveSpeed)),
            duration: 0.20
        )
        status = "CALIBRATION • short forward pulse"
    }

    func testR2TurnLeft() {
        guard connectionMode == .directBluetooth, directBLE.isConnected, !isFollowing else {
            status = "Connect R2 directly and stop Follow before testing"
            return
        }

        directBLE.calibrationTurnLeftPulse(
            speed: UInt8(clamping: Int(directFollow.turnSpeed)),
            duration: 0.14
        )
        status = "CALIBRATION • small left turn"
    }

    func testR2TurnRight() {
        guard connectionMode == .directBluetooth, directBLE.isConnected, !isFollowing else {
            status = "Connect R2 directly and stop Follow before testing"
            return
        }

        directBLE.calibrationTurnRightPulse(
            speed: UInt8(clamping: Int(directFollow.turnSpeed)),
            duration: 0.14
        )
        status = "CALIBRATION • small right turn"
    }

    func stopR2CalibrationMotion() {
        directBLE.calibrationStop()
        status = "CALIBRATION STOP"
    }

    func resetFollowCalibration() {
        directFollow.resetRecommendedCalibration()
        status = "Recommended Follow calibration restored"
    }

    // MARK: - Voice

    func startVoiceCommands() async {
        syncBridgeSettings()
        await voice.start()
        if voice.isListening {
            status = connectionMode == .directBluetooth
                ? "VOICE COMMANDS ON • direct to R2"
                : "VOICE COMMANDS ON • through Mac"
        } else {
            status = voice.permissionStatus
        }
    }

    func stopVoiceCommands() {
        voice.stop()
        status = "Voice commands off"
    }

    private func handleVoiceCommand(_ command: R2VoiceCommand) async {
        if connectionMode == .directBluetooth {
            await handleDirectVoiceCommand(command)
        } else {
            await handleMacVoiceCommand(command)
        }
    }

    private func handleDirectVoiceCommand(_ command: R2VoiceCommand) async {
        if command == .stop {
            await emergencyStop()
            return
        }

        if command == .stopFollowing {
            await stopFollow()
            return
        }

        if command == .follow {
            await startFollow()
            return
        }

        guard directBLE.isConnected else {
            status = "Voice command heard, but Direct Bluetooth is not connected to R2"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        if isFollowing {
            switch command {
            case .speak:
                directBLE.chirp()
                status = "VOICE • R2 speak"
            case .lightsOn:
                directBLE.setAllHeadLEDs(on: true)
                status = "VOICE • R2 lights on"
            case .lightsOff:
                directBLE.setAllHeadLEDs(on: false)
                status = "VOICE • R2 lights off"
            default:
                status = "Voice command blocked while Follow is moving R2. Say “R2 stop following” first."
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        switch command {
        case .speak:
            directBLE.chirp()
        case .think:
            directBLE.scanArea()
        case .hello:
            directBLE.greeting()
        case .happy:
            directBLE.setAllHeadLEDs(on: true)
            directBLE.chirp(bank: 1)
        case .excited:
            directBLE.dance()
        case .alert:
            directBLE.chirp(bank: 7)
        case .sleep:
            directBLE.sleepReaction()
        case .wake:
            directBLE.wakeReaction()
        case .lookLeft:
            directBLE.lookLeft()
        case .lookRight:
            directBLE.lookRight()
        case .center:
            directBLE.centerDome()
        case .scan:
            directBLE.scanArea()
        case .turnLeft:
            directBLE.turnLeftPulse()
        case .turnRight:
            directBLE.turnRightPulse()
        case .spinLeft:
            directBLE.spinLeft()
        case .spinRight:
            directBLE.spinRight()
        case .dance:
            directBLE.dance()
        case .lightsOn:
            directBLE.setAllHeadLEDs(on: true)
        case .lightsOff:
            directBLE.setAllHeadLEDs(on: false)
        case .resistance:
            directBLE.executeScript(3)
        case .firstOrder:
            directBLE.executeScript(7)
        case .droidDepot:
            directBLE.executeScript(2)
        case .follow, .stopFollowing, .stop:
            break
        }

        status = "VOICE • \(command.rawValue)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handleMacVoiceCommand(_ command: R2VoiceCommand) async {
        syncBridgeSettings()

        do {
            switch command {
            case .speak:
                try await bridge.chirp()
            case .think:
                try await bridge.reaction("Curious")
            case .hello:
                try await bridge.reaction("Greeting")
            case .happy:
                try await bridge.reaction("Happy")
            case .excited:
                try await bridge.reaction("Excited")
            case .alert:
                try await bridge.reaction("Alert")
            case .sleep:
                try await bridge.reaction("Sleep")
            case .wake:
                try await bridge.action("wake")
            case .lookLeft:
                try await bridge.action("look-left")
            case .lookRight:
                try await bridge.action("look-right")
            case .center:
                try await bridge.centerDome()
            case .scan:
                try await bridge.action("scan")
            case .turnLeft:
                try await bridge.action("turn-left")
            case .turnRight:
                try await bridge.action("turn-right")
            case .spinLeft:
                try await bridge.action("spin-left")
            case .spinRight:
                try await bridge.spin()
            case .dance:
                try await bridge.action("dance")
            case .lightsOn:
                try await bridge.action("lights/on")
            case .lightsOff:
                try await bridge.action("lights/off")
            case .resistance:
                try await bridge.runScript(3)
            case .firstOrder:
                try await bridge.runScript(7)
            case .droidDepot:
                try await bridge.runScript(2)
            case .follow:
                await startFollow()
                return
            case .stopFollowing:
                await stopFollow()
                return
            case .stop:
                await emergencyStop()
                return
            }

            status = "VOICE • \(command.rawValue)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            status = "Voice command failed: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: - Calibration / connections

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

    // MARK: - Follow

    func startFollow() async {
        guard !isFollowing else {
            status = "Follow is already active"
            return
        }

        sequence = 0
        lastSentDistance = 0

        switch connectionMode {
        case .directBluetooth:
            guard directBLE.isConnected else {
                motion.stopTracking()
                status = "Connect directly to R2 over Bluetooth first"
                return
            }

            guard directFollow.twoFootRSSI != nil else {
                motion.stopTracking()
                status = "Set the 2-foot Bluetooth stop distance before starting Follow"
                return
            }

            let directHeading: Double
            if directFollow.turnCorrectionEnabled {
                guard let calibratedHeading else {
                    status = "Align R2 + iPhone before using experimental turn correction"
                    return
                }
                motion.startTracking()
                directHeading = calibratedHeading
            } else {
                // Pure BLE proximity mode needs no compass or pedometer.
                directHeading = 0
            }

            directFollow.start(initialHeading: directHeading)
            guard directFollow.isActive else {
                motion.stopTracking()
                status = "Could not start Direct Bluetooth Follow"
                return
            }

            isFollowing = true
            UIApplication.shared.isIdleTimerDisabled = true
            status = "DIRECT FOLLOWING • iPhone → Bluetooth → R2"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            beginTelemetryLoop()

        case .macBridge:
            motion.startTracking()
            syncBridgeSettings()

            guard !macHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                motion.stopTracking()
                status = "Enter your Mac IP address first"
                return
            }

            let followStatus = await bridge.followStatus()

            guard followStatus?.armed == true else {
                motion.stopTracking()
                status = "Arm Follow Me in Droid Control on the Mac first"
                return
            }

            guard followStatus?.droidConnected == true else {
                motion.stopTracking()
                status = "Connect R2 to Droid Control first"
                return
            }

            guard let calibratedHeading else {
                motion.stopTracking()
                status = "Calibrate before starting Mac Bridge Follow"
                return
            }

            sessionID = UUID().uuidString

            do {
                try await bridge.startFollow(
                    FollowStartPayload(
                        sessionID: sessionID,
                        initialHeading: calibratedHeading
                    )
                )

                isFollowing = true
                UIApplication.shared.isIdleTimerDisabled = true
                status = "MAC BRIDGE FOLLOWING"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                beginTelemetryLoop()
            } catch {
                motion.stopTracking()
                status = "Could not start: \(error.localizedDescription)"
            }
        }
    }

    func stopFollow() async {
        sendTimer?.invalidate()
        sendTimer = nil
        motion.stopTracking()
        isFollowing = false
        UIApplication.shared.isIdleTimerDisabled = false

        if connectionMode == .directBluetooth {
            directFollow.stop(reason: "Stopped")
            status = "Direct Follow stopped"
        } else {
            await bridge.stopFollow()
            status = bridge.lastMessage
        }
    }

    func emergencyStop() async {
        sendTimer?.invalidate()
        sendTimer = nil
        motion.stopTracking()
        isFollowing = false
        UIApplication.shared.isIdleTimerDisabled = false

        if connectionMode == .directBluetooth {
            directFollow.emergencyStop()
            directBLE.emergencyStop()
        } else {
            await bridge.emergencyStop()
        }

        status = "EMERGENCY STOP SENT"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func appDidEnterBackground() {
        guard isFollowing else {
            if connectionMode == .directBluetooth {
                directBLE.emergencyStop()
            }
            return
        }

        Task { @MainActor in
            await emergencyStop()
            status = "Follow stopped because the app left the foreground"
        }
    }

    private func finishFollowLocally() {
        sendTimer?.invalidate()
        sendTimer = nil
        motion.stopTracking()
        isFollowing = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func beginTelemetryLoop() {
        sendTimer?.invalidate()
        let interval = connectionMode == .directBluetooth ? 0.12 : 0.45
        sendTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.isFollowing else { return }
            Task { @MainActor in
                await self.sendTelemetry()
            }
        }
    }

    private func sendTelemetry() async {
        sequence += 1

        if connectionMode == .directBluetooth {
            guard directBLE.isConnected else {
                stopLocalFollowAfterBluetoothLoss()
                return
            }

            directFollow.accept(
                totalDistanceMeters: motion.totalDistance,
                headingDegrees: motion.heading,
                headingAccuracy: motion.headingAccuracy,
                moving: motion.moving
            )

            status = String(
                format: "DIRECT • %@ • %.2fm • %.0f°",
                directFollow.state,
                motion.totalDistance,
                motion.heading
            )
            return
        }

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
                format: "MAC BRIDGE • %.2fm walked • heading %.0f°",
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

            await bridge.emergencyStop()
            status = "Telemetry stopped: \(detail)"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
