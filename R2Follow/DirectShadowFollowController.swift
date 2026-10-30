import Foundation
import Combine

@MainActor
final class DirectShadowFollowController: ObservableObject {
    private struct Segment {
        let readyAt: Date
        let distanceDeltaMeters: Double
        let targetHeading: Double
    }

    @Published private(set) var isActive = false
    @Published private(set) var state = "OFF"
    @Published private(set) var filteredHeading = 0.0
    @Published private(set) var headingError = 0.0
    @Published private(set) var queuedDistance = 0.0
    @Published var personalityEnabled = true
    @Published var turnCorrectionEnabled = false
    @Published var twoFootRSSI: Double?
    @Published private(set) var proximityState = "NOT CALIBRATED"

    // Live calibration controls. These can be adjusted from the iPhone before Follow.
    @Published var shadowDelay = 0.35
    @Published var driveSpeed = 92.0
    @Published var turnSpeed = 66.0
    @Published var minimumDistanceMeters = 0.04
    @Published var secondsPerMeter = 3.10
    @Published var turnDegreesPerSecond = 92.0
    @Published var turnDeadbandDegrees = 18.0
    @Published var maxHeadingAccuracy = 35.0
    @Published var headingSmoothing = 0.22
    @Published var maxDrivePulse = 0.32
    @Published var maxTurnPulse = 0.22

    private let droid: DirectDroidBLE
    private var referenceHeading = 0.0
    private var estimatedDroidHeading = 0.0
    private var latestTargetHeading = 0.0
    private var lastQueuedHeading = 0.0
    private var lastTotalDistance = 0.0
    private var accumulatedDistance = 0.0
    private var queue: [Segment] = []
    private var processingTimer: Timer?
    private var executing = false
    private var hasFilteredHeading = false
    private var nextChirpAt = Date.distantFuture
    private var nextLightAt = Date.distantFuture
    private var proximityHolding = false

    init(droid: DirectDroidBLE) {
        self.droid = droid
    }

    func resetRecommendedCalibration() {
        shadowDelay = 0.35
        driveSpeed = 92
        turnSpeed = 66
        minimumDistanceMeters = 0.04
        secondsPerMeter = 3.10
        turnDegreesPerSecond = 92
        turnDeadbandDegrees = 18
        maxHeadingAccuracy = 35
        headingSmoothing = 0.22
        maxDrivePulse = 0.32
        maxTurnPulse = 0.22
        turnCorrectionEnabled = false
    }

    func calibrateTwoFootStop(usingRSSI rssi: Double) {
        guard rssi < 0, rssi > -120 else {
            proximityState = "WAITING FOR VALID BLUETOOTH SIGNAL"
            return
        }

        twoFootRSSI = rssi
        proximityState = String(format: "2 FT SET • %.0f dBm", rssi)
    }

    func clearTwoFootStop() {
        twoFootRSSI = nil
        proximityState = "NOT CALIBRATED"
    }

    private func isInsideStopDistance() -> Bool {
        guard let twoFootRSSI else { return false }
        let current = droid.smoothedRSSI
        guard current < 0, current > -120 else { return false }

        // RSSI becomes less negative as the phone gets closer. A small margin
        // prevents rapid stop/start chatter around the calibration point.
        return current >= twoFootRSSI - 1.5
    }

    private func isClearlyOutsideStopDistance() -> Bool {
        guard let twoFootRSSI else { return true }
        let current = droid.smoothedRSSI
        guard current < 0, current > -120 else { return true }

        // Hysteresis: R2 must fall several dB farther away before resuming.
        return current <= twoFootRSSI - 4.0
    }

    func setReferenceHeading(_ heading: Double) {
        referenceHeading = normalized360(heading)
        estimatedDroidHeading = 0
        latestTargetHeading = 0
        lastQueuedHeading = 0
        filteredHeading = 0
        headingError = 0
        hasFilteredHeading = false
        state = "R2 FORWARD HEADING ALIGNED"
    }

    func start(initialHeading: Double) {
        stop(reason: "Restarting", updateState: false)

        guard droid.isConnected else {
            state = "R2 NOT CONNECTED"
            return
        }

        setReferenceHeading(initialHeading)
        lastTotalDistance = 0
        accumulatedDistance = 0
        queuedDistance = 0
        queue.removeAll()
        executing = false
        isActive = true
        state = "FOLLOWING / WAITING FOR STEPS"
        nextChirpAt = Date().addingTimeInterval(2.5)
        nextLightAt = Date().addingTimeInterval(0.6)
        proximityHolding = false

        if personalityEnabled {
            droid.setAllHeadLEDs(on: true)
            droid.chirp(bank: 1)
        }

        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func accept(
        totalDistanceMeters: Double,
        headingDegrees: Double,
        headingAccuracy: Double,
        moving: Bool
    ) {
        guard isActive, droid.isConnected else { return }

        let total = max(0, totalDistanceMeters)
        let delta = max(0, min(1.0, total - lastTotalDistance))
        lastTotalDistance = total

        let headingUsable =
            headingAccuracy >= 0 &&
            headingAccuracy <= maxHeadingAccuracy &&
            headingDegrees.isFinite

        var targetHeading = latestTargetHeading

        if headingUsable {
            let rawRelative = shortestAngle(normalized360(headingDegrees) - referenceHeading)

            if !hasFilteredHeading {
                filteredHeading = rawRelative
                hasFilteredHeading = true
            } else {
                filteredHeading = circularBlend(
                    from: filteredHeading,
                    to: rawRelative,
                    alpha: headingSmoothing
                )
            }

            // Ignore impossible single-sample compass jumps. A real walking turn
            // will continue arriving and the filtered value will catch up smoothly.
            let jump = shortestAngle(filteredHeading - lastQueuedHeading)
            let limitedJump = max(-35.0, min(35.0, jump))
            targetHeading = shortestAngle(lastQueuedHeading + limitedJump)
        }

        let headingChange = abs(shortestAngle(targetHeading - lastQueuedHeading))

        // Always record real forward progress quickly.
        let hasForwardProgress = delta >= 0.01

        // A heading-only segment is accepted only while the phone says the user
        // is actually moving. This prevents pocket compass wobble from making R2
        // spin in circles while standing still.
        let hasMeaningfulTurn =
            turnCorrectionEnabled &&
            moving &&
            headingUsable &&
            headingChange >= turnDeadbandDegrees

        if hasForwardProgress || hasMeaningfulTurn {
            queue.append(
                Segment(
                    readyAt: Date().addingTimeInterval(max(0.10, shadowDelay)),
                    distanceDeltaMeters: delta,
                    targetHeading: targetHeading
                )
            )

            if hasMeaningfulTurn || hasForwardProgress {
                lastQueuedHeading = targetHeading
            }

            if queue.count > 70 {
                queue.removeFirst(queue.count - 70)
            }
        }
    }

    func stop(reason: String = "Stopped", updateState: Bool = true) {
        processingTimer?.invalidate()
        processingTimer = nil
        queue.removeAll()
        accumulatedDistance = 0
        queuedDistance = 0
        executing = false
        isActive = false
        droid.stopDrive()

        if updateState {
            state = reason.uppercased()
        }
    }

    func emergencyStop() {
        stop(reason: "Emergency stop")
        droid.emergencyStop()
    }

    private func tick() {
        guard isActive else { return }

        guard droid.isConnected else {
            stop(reason: "Bluetooth lost")
            return
        }

        performPersonalityIfNeeded()

        if twoFootRSSI != nil {
            if proximityHolding {
                if isClearlyOutsideStopDistance() {
                    proximityHolding = false
                    proximityState = "PHONE MOVED AWAY • RESUMING"
                } else {
                    droid.stopDrive()
                    state = "HOLDING • ABOUT 2 FT"
                    proximityState = "HOLDING NEAR 2 FT"
                    return
                }
            } else if isInsideStopDistance() {
                proximityHolding = true
                droid.stopDrive()
                state = "HOLDING • ABOUT 2 FT"
                proximityState = "HOLDING NEAR 2 FT"
                return
            } else {
                proximityState = "PHONE FARTHER THAN STOP POINT"
            }
        }

        guard !executing else { return }

        while let first = queue.first, first.readyAt <= Date() {
            queue.removeFirst()
            accumulatedDistance += first.distanceDeltaMeters
            latestTargetHeading = first.targetHeading
        }

        queuedDistance = accumulatedDistance

        let difference = shortestAngle(latestTargetHeading - estimatedDroidHeading)
        headingError = difference

        // Drive first when heading is already reasonably close. Only pivot when
        // the error is outside the deadband. This dramatically reduces circling.
        if turnCorrectionEnabled && abs(difference) >= turnDeadbandDegrees {
            performTurn(difference)
            return
        }

        if accumulatedDistance >= minimumDistanceMeters {
            performForwardPulse()
            return
        }

        state = queue.isEmpty ? "FOLLOWING / WAITING" : "FOLLOWING / TRAIL BUFFER"
    }

    private func performTurn(_ difference: Double) {
        let degreesPerSecond = max(30, turnDegreesPerSecond)
        let requestedDuration = abs(difference) / degreesPerSecond
        let duration = min(max(0.06, requestedDuration), max(0.08, maxTurnPulse))
        let speed = UInt8(clamping: Int(max(42, min(90, turnSpeed))))

        executing = true

        if difference < 0 {
            droid.rotateLeft(speed: speed)
            state = "FOLLOWING / TURN LEFT"
        } else {
            droid.rotateRight(speed: speed)
            state = "FOLLOWING / TURN RIGHT"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.isActive else { return }

            self.droid.stopDrive()

            let signedDegrees =
                (difference < 0 ? -1.0 : 1.0) *
                duration *
                degreesPerSecond

            self.estimatedDroidHeading = self.shortestAngle(
                self.estimatedDroidHeading + signedDegrees
            )

            self.executing = false
        }
    }

    private func performForwardPulse() {
        let seconds = max(0.8, secondsPerMeter)
        let requestedDuration = accumulatedDistance * seconds
        let duration = min(max(0.07, requestedDuration), max(0.09, maxDrivePulse))
        let speed = UInt8(clamping: Int(max(45, min(100, driveSpeed))))

        executing = true
        droid.forward(speed: speed)
        state = "FOLLOWING / CATCH UP"

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.isActive else { return }

            self.droid.stopDrive()

            let consumedMeters = duration / seconds
            self.accumulatedDistance = max(
                0,
                self.accumulatedDistance - consumedMeters
            )
            self.queuedDistance = self.accumulatedDistance
            self.executing = false
        }
    }

    private func performPersonalityIfNeeded() {
        guard personalityEnabled, droid.isConnected else { return }

        let now = Date()

        if now >= nextLightAt {
            droid.naturalFollowBlink()

            if Int.random(in: 0...3) == 0 {
                droid.ambientDomeGlance()
            }

            nextLightAt = now.addingTimeInterval(Double.random(in: 0.55...1.65))
        }

        if now >= nextChirpAt {
            droid.chirp(bank: 1)
            nextChirpAt = now.addingTimeInterval(Double.random(in: 4.0...7.5))
        }
    }

    private func circularBlend(from: Double, to: Double, alpha: Double) -> Double {
        let clamped = max(0.05, min(0.80, alpha))
        let difference = shortestAngle(to - from)
        return shortestAngle(from + difference * clamped)
    }

    private func normalized360(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }

    private func shortestAngle(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}
