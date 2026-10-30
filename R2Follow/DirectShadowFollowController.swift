import Foundation
import Combine

@MainActor
final class DirectShadowFollowController: ObservableObject {
    private struct Segment {
        let readyAt: Date
        let releaseAtPathDistance: Double
        let distanceDeltaMeters: Double
        let targetHeading: Double
    }

    @Published private(set) var isActive = false
    @Published private(set) var state = "OFF"
    @Published private(set) var filteredHeading = 0.0
    @Published private(set) var headingError = 0.0
    @Published private(set) var queuedDistance = 0.0
    @Published private(set) var trackingQuality = "WAITING"

    // Master switch used by the shared personality engine.
    @Published var personalityEnabled = true

    // Hybrid Follow steering. GPS course is the primary turning source.
    @Published var turnCorrectionEnabled = true

    // Kept under the original property name for backwards compatibility with
    // existing UI/state. It now represents the calibrated ~3.5 ft RSSI point.
    @Published var twoFootRSSI: Double?
    @Published private(set) var proximityState = "NOT CALIBRATED"

    // Live tuning controls.
    @Published var shadowDelay = 0.18
    @Published var trailDistanceMeters = 1.05
    @Published var driveSpeed = 88.0
    @Published var turnSpeed = 60.0
    @Published var minimumDistanceMeters = 0.05
    @Published var secondsPerMeter = 2.85
    @Published var turnDegreesPerSecond = 90.0
    @Published var turnDeadbandDegrees = 16.0
    @Published var maxHeadingAccuracy = 35.0
    @Published var headingSmoothing = 0.16
    @Published var maxDrivePulse = 0.28
    @Published var maxTurnPulse = 0.18

    private let droid: DirectDroidBLE

    private var pathReferenceCourse: Double?
    private var estimatedDroidHeading = 0.0
    private var latestTargetHeading = 0.0
    private var lastQueuedHeading = 0.0
    private var lastTotalDistance = 0.0
    private var currentPhonePathDistance = 0.0
    private var accumulatedDistance = 0.0
    private var queue: [Segment] = []
    private var processingTimer: Timer?
    private var executing = false
    private var hasFilteredHeading = false
    private var proximityHolding = false
    private var lastGoodCourseAt = Date.distantPast

    init(droid: DirectDroidBLE) {
        self.droid = droid
    }

    func resetRecommendedCalibration() {
        shadowDelay = 0.18
        trailDistanceMeters = 1.05
        driveSpeed = 88
        turnSpeed = 60
        minimumDistanceMeters = 0.05
        secondsPerMeter = 2.85
        turnDegreesPerSecond = 90
        turnDeadbandDegrees = 16
        maxHeadingAccuracy = 35
        headingSmoothing = 0.16
        maxDrivePulse = 0.28
        maxTurnPulse = 0.18
        turnCorrectionEnabled = true
    }

    func calibrateTwoFootStop(usingRSSI rssi: Double) {
        guard rssi < 0, rssi > -120 else {
            proximityState = "WAITING FOR VALID BLUETOOTH SIGNAL"
            return
        }

        twoFootRSSI = rssi
        proximityState = String(
            format: "3.5 FT TARGET SET • %.0f dBm",
            rssi
        )
    }

    func clearTwoFootStop() {
        twoFootRSSI = nil
        proximityState = "NOT CALIBRATED"
    }

    func setReferenceHeading(_ heading: Double) {
        // Legacy/manual alignment remains available, but Hybrid Follow normally
        // learns its reference from the first reliable GPS course while walking.
        pathReferenceCourse = normalized360(heading)
        estimatedDroidHeading = 0
        latestTargetHeading = 0
        lastQueuedHeading = 0
        filteredHeading = 0
        headingError = 0
        hasFilteredHeading = false
        state = "PATH HEADING ALIGNED"
    }

    func start(initialHeading: Double) {
        stop(reason: "Restarting", updateState: false)

        guard droid.isConnected else {
            state = "R2 NOT CONNECTED"
            return
        }

        pathReferenceCourse = nil
        estimatedDroidHeading = 0
        latestTargetHeading = 0
        lastQueuedHeading = 0
        lastTotalDistance = 0
        currentPhonePathDistance = 0
        accumulatedDistance = 0
        queuedDistance = 0
        queue.removeAll()
        executing = false
        hasFilteredHeading = false
        proximityHolding = false
        lastGoodCourseAt = .distantPast

        isActive = true
        state = "HYBRID FOLLOW / WALK FORWARD"
        trackingQuality = "WAITING FOR GPS COURSE"

        processingTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }

    func accept(
        totalDistanceMeters: Double,
        gpsCourseDegrees: Double,
        gpsCourseValid: Bool,
        moving: Bool
    ) {
        guard isActive, droid.isConnected else { return }

        let total = max(0, totalDistanceMeters)
        let delta = max(0, min(1.0, total - lastTotalDistance))
        lastTotalDistance = total
        currentPhonePathDistance = total

        var targetHeading = latestTargetHeading

        if turnCorrectionEnabled,
           gpsCourseValid,
           moving,
           gpsCourseDegrees >= 0,
           gpsCourseDegrees < 360 {

            let course = normalized360(gpsCourseDegrees)

            if pathReferenceCourse == nil {
                pathReferenceCourse = course
                filteredHeading = 0
                latestTargetHeading = 0
                lastQueuedHeading = 0
                hasFilteredHeading = true
                trackingQuality = "GPS COURSE LOCKED"
                lastGoodCourseAt = Date()
            } else if let reference = pathReferenceCourse {
                let rawRelative = shortestAngle(course - reference)

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

                // Prevent a single GPS sample from asking for a huge pivot.
                // Real turns persist across several samples and naturally catch up.
                let jump = shortestAngle(
                    filteredHeading - lastQueuedHeading
                )
                let limitedJump = max(-22.0, min(22.0, jump))
                targetHeading = shortestAngle(
                    lastQueuedHeading + limitedJump
                )

                lastGoodCourseAt = Date()
                trackingQuality = "GPS + MOTION"
            }
        } else if turnCorrectionEnabled {
            let age = Date().timeIntervalSince(lastGoodCourseAt)
            trackingQuality =
                age < 2.0
                ? "COASTING ON LAST GOOD COURSE"
                : "GPS COURSE WEAK • NO NEW TURN"
        } else {
            trackingQuality = "STRAIGHT PROXIMITY MODE"
        }

        let headingChange = abs(
            shortestAngle(targetHeading - lastQueuedHeading)
        )

        let hasForwardProgress = delta >= 0.01
        let hasMeaningfulTurn =
            turnCorrectionEnabled &&
            moving &&
            gpsCourseValid &&
            headingChange >= turnDeadbandDegrees

        if hasForwardProgress || hasMeaningfulTurn {
            let releaseDistance =
                total + max(0.60, trailDistanceMeters)

            queue.append(
                Segment(
                    readyAt: Date().addingTimeInterval(
                        max(0.05, shadowDelay)
                    ),
                    releaseAtPathDistance: releaseDistance,
                    distanceDeltaMeters: delta,
                    targetHeading: targetHeading
                )
            )

            if hasMeaningfulTurn || hasForwardProgress {
                lastQueuedHeading = targetHeading
            }

            if queue.count > 100 {
                queue.removeFirst(queue.count - 100)
            }
        }
    }

    func stop(
        reason: String = "Stopped",
        updateState: Bool = true
    ) {
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

        // Bluetooth is only the close-range spacing brake. GPS/course decides
        // the path direction.
        if twoFootRSSI != nil {
            if proximityHolding {
                if isClearlyOutsideStopDistance() {
                    proximityHolding = false
                    proximityState = "PHONE MOVED AWAY • RESUMING"
                } else {
                    droid.stopDrive()
                    state = "HOLDING • ~3–4 FT"
                    proximityState = "HOLDING TARGET GAP"
                    return
                }
            } else if isInsideStopDistance() {
                proximityHolding = true
                droid.stopDrive()
                state = "HOLDING • ~3–4 FT"
                proximityState = "HOLDING TARGET GAP"
                return
            } else {
                proximityState = "PHONE AHEAD • FOLLOWING"
            }
        }

        guard !executing else { return }

        if !turnCorrectionEnabled, twoFootRSSI != nil {
            performStraightProximityPulse()
            return
        }

        // Release breadcrumbs only after the phone is about 3–4 ft farther down
        // the recorded walking path. This makes R2 replay the path behind you
        // instead of chasing your current phone heading.
        while let first = queue.first,
              first.readyAt <= Date(),
              currentPhonePathDistance >= first.releaseAtPathDistance {

            queue.removeFirst()
            accumulatedDistance += first.distanceDeltaMeters
            latestTargetHeading = first.targetHeading
        }

        queuedDistance = accumulatedDistance

        let difference = shortestAngle(
            latestTargetHeading - estimatedDroidHeading
        )
        headingError = difference

        if turnCorrectionEnabled &&
           abs(difference) >= turnDeadbandDegrees {
            performTurn(difference)
            return
        }

        if accumulatedDistance >= minimumDistanceMeters {
            performForwardPulse()
            return
        }

        state =
            queue.isEmpty
            ? "HYBRID FOLLOW / HOLDING PATH"
            : "HYBRID FOLLOW / TRAIL BUFFER"
    }

    private func performStraightProximityPulse() {
        guard let targetRSSI = twoFootRSSI else { return }

        let current = droid.smoothedRSSI

        guard current < 0, current > -120 else {
            state = "PROXIMITY / WAITING FOR SIGNAL"
            return
        }

        let gapDB = max(0, targetRSSI - current)
        let duration = min(
            max(0.07, 0.07 + gapDB * 0.016),
            max(0.10, maxDrivePulse)
        )

        let speed = UInt8(
            clamping: Int(
                max(48, min(100, driveSpeed))
            )
        )

        executing = true
        droid.forward(speed: speed)
        state = "STRAIGHT PROXIMITY / CATCH UP"

        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration
        ) { [weak self] in
            guard let self, self.isActive else { return }
            self.droid.stopDrive()
            self.executing = false
        }
    }

    private func performTurn(_ difference: Double) {
        let degreesPerSecond = max(30, turnDegreesPerSecond)
        let requestedDuration =
            abs(difference) / degreesPerSecond

        let duration = min(
            max(0.055, requestedDuration),
            max(0.08, maxTurnPulse)
        )

        let speed = UInt8(
            clamping: Int(
                max(40, min(82, turnSpeed))
            )
        )

        executing = true

        if difference < 0 {
            droid.rotateLeft(speed: speed)
            state = "HYBRID FOLLOW / TURN LEFT"
        } else {
            droid.rotateRight(speed: speed)
            state = "HYBRID FOLLOW / TURN RIGHT"
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration
        ) { [weak self] in
            guard let self, self.isActive else { return }

            self.droid.stopDrive()

            let signedDegrees =
                (difference < 0 ? -1.0 : 1.0) *
                duration *
                degreesPerSecond

            self.estimatedDroidHeading =
                self.shortestAngle(
                    self.estimatedDroidHeading +
                    signedDegrees
                )

            self.executing = false
        }
    }

    private func performForwardPulse() {
        let seconds = max(0.8, secondsPerMeter)
        let requestedDuration =
            accumulatedDistance * seconds

        let duration = min(
            max(0.065, requestedDuration),
            max(0.09, maxDrivePulse)
        )

        var speed = max(45, min(100, driveSpeed))

        // If Bluetooth says the phone is clearly farther than the calibrated
        // gap, let R2 catch up a little harder without changing steering.
        if let targetRSSI = twoFootRSSI {
            let current = droid.smoothedRSSI
            if current < targetRSSI - 8 {
                speed = min(100, speed + 8)
            } else if current < targetRSSI - 5 {
                speed = min(100, speed + 4)
            }
        }

        executing = true
        droid.forward(
            speed: UInt8(clamping: Int(speed))
        )
        state = "HYBRID FOLLOW / CATCH UP"

        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration
        ) { [weak self] in
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

    private func isInsideStopDistance() -> Bool {
        guard let targetRSSI = twoFootRSSI else {
            return false
        }

        let current = droid.smoothedRSSI
        guard current < 0, current > -120 else {
            return false
        }

        return current >= targetRSSI - 1.2
    }

    private func isClearlyOutsideStopDistance() -> Bool {
        guard let targetRSSI = twoFootRSSI else {
            return true
        }

        let current = droid.smoothedRSSI
        guard current < 0, current > -120 else {
            return true
        }

        return current <= targetRSSI - 4.0
    }

    private func circularBlend(
        from: Double,
        to: Double,
        alpha: Double
    ) -> Double {
        let clamped = max(0.05, min(0.50, alpha))
        let difference = shortestAngle(to - from)
        return shortestAngle(from + difference * clamped)
    }

    private func normalized360(_ value: Double) -> Double {
        var result =
            value.truncatingRemainder(dividingBy: 360)

        if result < 0 {
            result += 360
        }

        return result
    }

    private func shortestAngle(_ value: Double) -> Double {
        var result =
            value.truncatingRemainder(dividingBy: 360)

        if result > 180 {
            result -= 360
        }

        if result < -180 {
            result += 360
        }

        return result
    }
}
