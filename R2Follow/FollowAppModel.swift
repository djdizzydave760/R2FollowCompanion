import Foundation
import UIKit
import Combine

enum ConnectionMode: String, CaseIterable, Identifiable {
    case directBluetooth = "Direct Bluetooth"
    case macBridge = "Mac Bridge"

    var id: String { rawValue }
}


enum R2OperationMode: String, CaseIterable, Identifiable {
    case hybridFollow = "Hybrid Follow"
    case backpack = "Backpack"

    var id: String { rawValue }
}

enum R2PersonalityMode: String, CaseIterable, Identifiable {
    case relaxed = "Relaxed"
    case curious = "Curious"
    case active = "Active"
    case excited = "Excited"
    case patrol = "On Patrol"
    case quiet = "Quiet"

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

    @Published var operationMode: R2OperationMode {
        didSet {
            UserDefaults.standard.set(operationMode.rawValue, forKey: "operationMode")
            applyOperationMode()
        }
    }

    @Published var personalityMode: R2PersonalityMode {
        didSet {
            UserDefaults.standard.set(personalityMode.rawValue, forKey: "personalityMode")
            applyPersonalityDefaults()
            resetPersonalitySchedule()
        }
    }

    @Published var backpackHeadInterval = 12.0 {
        didSet { UserDefaults.standard.set(backpackHeadInterval, forKey: "backpackHeadInterval") }
    }

    @Published var backpackSoundInterval = 22.0 {
        didSet { UserDefaults.standard.set(backpackSoundInterval, forKey: "backpackSoundInterval") }
    }

    @Published var backpackReactionChance = 0.65 {
        didSet { UserDefaults.standard.set(backpackReactionChance, forKey: "backpackReactionChance") }
    }

    @Published var backpackHeadAmount = 0.65 {
        didSet { UserDefaults.standard.set(backpackHeadAmount, forKey: "backpackHeadAmount") }
    }

    @Published var backpackLightIntensity = 0.65 {
        didSet { UserDefaults.standard.set(backpackLightIntensity, forKey: "backpackLightIntensity") }
    }

    @Published var externalAudioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                externalAudioEnabled,
                forKey: "externalAudioEnabled"
            )

            if externalAudioEnabled &&
               operationMode == .backpack {
                externalAudio.start()
            } else if !externalAudioEnabled {
                externalAudio.stop()
            }
        }
    }

    @Published var calibratedHeading: Double?
    @Published var isFollowing = false
    @Published var sequence = 0
    @Published var status = "Ready"

    let motion = MotionTracker()
    let bridge = MacBridge()
    let voice = VoiceCommandListener()
    let directBLE = DirectDroidBLE()
    let externalAudio = R2ExternalAudioEngine()
    lazy var directFollow = DirectShadowFollowController(droid: directBLE)

    private var sessionID = UUID().uuidString
    private var sendTimer: Timer?
    private var lifeTimer: Timer?
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

        let storedOperation = UserDefaults.standard.string(forKey: "operationMode")
        operationMode = R2OperationMode(rawValue: storedOperation ?? "") ?? .hybridFollow

        let storedPersonality = UserDefaults.standard.string(forKey: "personalityMode")
        personalityMode = R2PersonalityMode(rawValue: storedPersonality ?? "") ?? .relaxed

        let hasBackpackTuning =
            UserDefaults.standard.object(forKey: "backpackHeadInterval") != nil

        if hasBackpackTuning {
            backpackHeadInterval = UserDefaults.standard.double(forKey: "backpackHeadInterval")
            backpackSoundInterval = UserDefaults.standard.double(forKey: "backpackSoundInterval")
            backpackReactionChance = UserDefaults.standard.double(forKey: "backpackReactionChance")
            backpackHeadAmount = UserDefaults.standard.double(forKey: "backpackHeadAmount")
            backpackLightIntensity = UserDefaults.standard.double(forKey: "backpackLightIntensity")
        } else {
            applyPersonalityDefaults()
        }

        if UserDefaults.standard.object(
            forKey: "externalAudioEnabled"
        ) == nil {
            externalAudioEnabled = true
        } else {
            externalAudioEnabled =
                UserDefaults.standard.bool(
                    forKey: "externalAudioEnabled"
                )
        }

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

        externalAudio.objectWillChange
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

        motion.onActivityPulse = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.servicePersonalityPulse()
            }
        }

        beginDroidLifeLoop()
        applyOperationMode()

        if operationMode == .backpack &&
           externalAudioEnabled {
            externalAudio.start()
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

    // MARK: - R2 operation mode

    private func applyOperationMode() {
        switch operationMode {
        case .hybridFollow:
            directBLE.setDriveLocked(false)

            if !isFollowing {
                // Stop the Backpack-only background life session until Follow
                // is explicitly started.
                motion.stopTracking()
                externalAudio.stop()
                status = "Hybrid Follow mode • wheels enabled"
            }

        case .backpack:
            sendTimer?.invalidate()
            sendTimer = nil

            directFollow.stop(reason: "Backpack mode")
            directBLE.setDriveLocked(true)
            isFollowing = false
            UIApplication.shared.isIdleTimerDisabled = false

            // Backpack Mode has no wheel movement, but keeps a user-visible
            // background location activity session so iOS can deliver pulses
            // after the screen locks.
            motion.stopTracking()
            motion.startBackgroundFollowSession()

            directBLE.setAllHeadLEDs(on: false)
            resetPersonalitySchedule()

            if externalAudioEnabled {
                externalAudio.start()
            }

            status =
                "BACKPACK MODE • wheels locked • locked-screen life active"
        }
    }

    private func applyPersonalityDefaults() {
        switch personalityMode {
        case .relaxed:
            backpackHeadInterval = 14.0
            backpackSoundInterval = 26.0
            backpackReactionChance = 0.52
            backpackHeadAmount = 0.52
            backpackLightIntensity = 0.48

        case .curious:
            backpackHeadInterval = 9.0
            backpackSoundInterval = 18.0
            backpackReactionChance = 0.62
            backpackHeadAmount = 0.68
            backpackLightIntensity = 0.62

        case .active:
            backpackHeadInterval = 7.0
            backpackSoundInterval = 14.0
            backpackReactionChance = 0.72
            backpackHeadAmount = 0.78
            backpackLightIntensity = 0.72

        case .excited:
            backpackHeadInterval = 5.0
            backpackSoundInterval = 10.0
            backpackReactionChance = 0.82
            backpackHeadAmount = 0.95
            backpackLightIntensity = 0.92

        case .patrol:
            backpackHeadInterval = 8.0
            backpackSoundInterval = 17.0
            backpackReactionChance = 0.66
            backpackHeadAmount = 0.76
            backpackLightIntensity = 0.70

        case .quiet:
            backpackHeadInterval = 20.0
            backpackSoundInterval = 38.0
            backpackReactionChance = 0.42
            backpackHeadAmount = 0.42
            backpackLightIntensity = 0.32
        }
    }

    func restorePersonalityDefaults() {
        applyPersonalityDefaults()
        resetPersonalitySchedule()
        status = "\(personalityMode.rawValue) Backpack defaults restored"
    }

    private func randomizedInterval(_ base: Double) -> TimeInterval {
        let safe = max(2.0, base)
        return safe * Double.random(in: 0.78...1.32)
    }

    private func resetPersonalitySchedule() {
        let now = Date()
        nextIdleHead = now.addingTimeInterval(
            randomizedInterval(backpackHeadInterval)
        )
        nextIdleChirp = now.addingTimeInterval(
            randomizedInterval(backpackSoundInterval)
        )
        directBLE.setAllHeadLEDs(on: false)
    }

    private func randomDelay(_ range: ClosedRange<Double>) -> TimeInterval {
        Double.random(in: range)
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

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2.0
        ) { [weak self] in
            guard let self,
                  self.directBLE.isConnected else {
                return
            }

            self.applyOperationMode()
            self.servicePersonalityPulse(force: true)
        }
    }

    func disconnectDirectDroid() {
        if isFollowing && connectionMode == .directBluetooth {
            directFollow.emergencyStop()
            finishFollowLocally()
        }
        directBLE.disconnect()
        externalAudio.stop()
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
        resetPersonalitySchedule()

        lifeTimer = Timer.scheduledTimer(
            withTimeInterval: 0.30,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                self.servicePersonalityPulse()
            }
        }
    }

    private func servicePersonalityPulse(
        force: Bool = false
    ) {
        guard connectionMode == .directBluetooth,
              directBLE.isConnected,
              directFollow.personalityEnabled else {
            return
        }

        let now = Date()

        // Backpack controls are deliberately slower than the earlier build.
        // Hybrid Follow uses the same personality but at a slightly calmer rate
        // so drive/navigation remains the primary behavior.
        let modeScale =
            operationMode == .backpack
            ? 1.0
            : 1.35

        let headBase = backpackHeadInterval * modeScale
        let soundBase = backpackSoundInterval * modeScale

        let soundDue = force || now >= nextIdleChirp

        if soundDue {
            nextIdleChirp = now.addingTimeInterval(
                randomizedInterval(soundBase)
            )

            nextIdleHead = max(
                nextIdleHead,
                now.addingTimeInterval(
                    randomizedInterval(headBase * 0.70)
                )
            )

            let shouldReact =
                force ||
                Double.random(in: 0...1) <= backpackReactionChance

            if shouldReact {
                if externalAudioEnabled &&
                   externalAudio.isRunning &&
                   externalAudio.totalAvailablePackSounds > 0 {

                    if let playback = externalAudio.playNextPackSound() {
                        if let profile = playback.profile {
                            directBLE.animateForSound(
                                profile: profile,
                                headAmount: backpackHeadAmount,
                                lightIntensity: backpackLightIntensity
                            )
                        } else {
                            directBLE.expressiveHeadAndLights()
                        }
                    } else {
                        directBLE.expressiveRandomBuiltInSound()
                    }
                } else {
                    directBLE.expressiveRandomBuiltInSound()
                }
            }

            return
        }

        if force || now >= nextIdleHead {
            nextIdleHead = now.addingTimeInterval(
                randomizedInterval(headBase)
            )

            let shouldReact =
                force ||
                Double.random(in: 0...1) <= backpackReactionChance

            if shouldReact {
                directBLE.ambientDomeGlance(
                    amount: backpackHeadAmount
                )
            }
        }
    }

    // MARK: - External / JBL audio

    func setExternalAudioEnabled(_ enabled: Bool) {
        externalAudioEnabled = enabled

        if enabled {
            externalAudio.start()
            servicePersonalityPulse(force: true)
            status =
                "SOUND BATCH ON • \(externalAudio.totalAvailablePackSounds) files • \(externalAudio.routeDescription)"
        } else {
            externalAudio.stop()
            status = "External R2 audio off • using R2 internal sounds"
        }
    }

    func importExternalSoundFiles(_ urls: [URL]) {
        externalAudio.importSoundFiles(urls)
        externalAudio.start()

        status =
            "SOUND BATCH READY • \(externalAudio.totalAvailablePackSounds) files"
    }

    func clearExternalSoundPack() {
        externalAudio.clearImportedSoundPack()
        status =
            "Extra imported sounds cleared • bundled Sound Batch remains"
    }

    func testExternalSoundPack() {
        externalAudio.start()

        if let playback = externalAudio.playNextPackSound() {
            if directBLE.isConnected {
                if let profile = playback.profile {
                    directBLE.animateForSound(
                        profile: profile,
                        headAmount: backpackHeadAmount,
                        lightIntensity: backpackLightIntensity
                    )
                } else {
                    directBLE.expressiveHeadAndLights()
                }
            }

            status =
                "SOUND BATCH TEST • \(externalAudio.lastPackSound)"
        } else {
            status =
                "Bundled Sound Batch is not available in this build"
        }
    }

    func testExternalSpeaker() {
        externalAudio.start()
        externalAudio.playLoudRouteTest()

        if directBLE.isConnected {
            directBLE.expressiveHeadAndLights()
        }

        if externalAudio.isBluetoothA2DP {
            status =
                "JBL TEST SENT • \(externalAudio.routeDescription)"
        } else {
            status =
                "AUDIO NOT ROUTED TO JBL • \(externalAudio.routeDescription)"
        }
    }

    func refreshExternalAudioRoute() {
        externalAudio.start()
        externalAudio.refreshRoute()

        status = externalAudio.isBluetoothA2DP
            ? "BLUETOOTH AUDIO ROUTE READY • \(externalAudio.routeDescription)"
            : "SELECT JBL CLIP 5 AS IPHONE AUDIO OUTPUT • \(externalAudio.routeDescription)"
    }

    // MARK: - R2 pre-follow calibration

    func testR2HeadAndVoice() {
        guard connectionMode == .directBluetooth, directBLE.isConnected else {
            status = "Connect R2 directly over Bluetooth first"
            return
        }

        directBLE.testHeadAndVoice()
        status = "TEST • R2 should chirp, turn head left/right, then center"
    }

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
            format: "3.5-FT TARGET SET • %.0f dBm • Bluetooth is the close-range brake",
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
            guard operationMode == .hybridFollow else {
                status = "Backpack Mode is active • wheel motors are locked"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            await startFollow()
            return
        }

        guard directBLE.isConnected else {
            status = "Voice command heard, but Direct Bluetooth is not connected to R2"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        if operationMode == .backpack {
            switch command {
            case .turnLeft, .turnRight, .spinLeft, .spinRight, .dance, .follow:
                status = "BACKPACK MODE • wheel movement command blocked"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return

            case .excited:
                directBLE.expressiveChirp(bank: 1)
                directBLE.ambientDomeGlance()
                status = "VOICE • excited backpack response"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                return

            case .resistance, .firstOrder, .droidDepot:
                status = "BACKPACK MODE • scripted park response blocked because it may move the wheels"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return

            default:
                break
            }
        }

        if isFollowing {
            switch command {
            case .speak:
                directBLE.expressiveChirp()
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
            directBLE.expressiveChirp()
        case .think:
            directBLE.scanArea()
        case .hello:
            directBLE.greeting()
        case .happy:
            directBLE.setAllHeadLEDs(on: true)
            directBLE.expressiveChirp(bank: 1)
        case .excited:
            directBLE.dance()
        case .alert:
            directBLE.expressiveChirp(bank: 7)
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
            guard operationMode == .hybridFollow else {
                status = "Backpack Mode is active • wheel motors are locked"
                return
            }

            guard directBLE.isConnected else {
                motion.stopTracking()
                status = "Connect directly to R2 over Bluetooth first"
                return
            }

            guard directFollow.twoFootRSSI != nil else {
                motion.stopTracking()
                status = "Place the phone about 3.5 ft from R2 and set the target gap first"
                return
            }

            directBLE.setDriveLocked(false)
            motion.startTracking()
            motion.startBackgroundFollowSession()

            // Hybrid Follow learns the walking direction from the first good
            // GPS course. No pocket compass alignment is required.
            directFollow.start(initialHeading: 0)
            guard directFollow.isActive else {
                motion.stopTracking()
                status = "Could not start Direct Bluetooth Follow"
                return
            }

            isFollowing = true
            UIApplication.shared.isIdleTimerDisabled = false
            status = "HYBRID FOLLOW • background GPS + Bluetooth active • screen may lock"
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
                UIApplication.shared.isIdleTimerDisabled = false
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
        if connectionMode == .directBluetooth,
           operationMode == .backpack,
           directBLE.isConnected {

            motion.startBackgroundFollowSession()

            if externalAudioEnabled {
                externalAudio.start()
            }

            status =
                "BACKPACK BACKGROUND ACTIVE • wheels locked • screen may sleep"
            return
        }

        if isFollowing,
           connectionMode == .directBluetooth,
           operationMode == .hybridFollow {

            status =
                "BACKGROUND FOLLOW ACTIVE • screen locked is OK"
            return
        }

        if isFollowing && connectionMode == .macBridge {
            Task { @MainActor in
                await emergencyStop()
                status =
                    "Mac Bridge Follow stopped in background"
            }
        }
    }

    func appDidBecomeActive() {
        externalAudio.refreshRoute()

        if connectionMode == .directBluetooth,
           operationMode == .backpack,
           directBLE.isConnected {

            status =
                "BACKPACK MODE ACTIVE • wheel motors locked"
            servicePersonalityPulse()
            return
        }

        if isFollowing,
           connectionMode == .directBluetooth,
           operationMode == .hybridFollow {

            status =
                "HYBRID FOLLOW ACTIVE • foreground restored"
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

            let fusedPathDistance = max(
                motion.totalDistance,
                motion.gpsPathDistance
            )

            directFollow.accept(
                totalDistanceMeters: fusedPathDistance,
                gpsCourseDegrees: motion.bestPathCourse,
                gpsCourseValid: motion.bestPathCourseUsable,
                moving: motion.moving
            )

            status = String(
                format: "HYBRID • %@ • %@ • %.2fm • RSSI %.0f",
                directFollow.state,
                directFollow.trackingQuality,
                max(motion.totalDistance, motion.gpsPathDistance),
                directBLE.smoothedRSSI
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
