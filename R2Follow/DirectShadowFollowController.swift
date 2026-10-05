import Foundation
import Combine

@MainActor
final class DirectShadowFollowController: ObservableObject {
    struct Settings {
        var shadowDelay = 2.0
        var maxSpeed = 70
        var turnSpeed = 62
        var minimumDistanceMeters = 0.18
        var secondsPerMeter = 2.9
        var turnDegreesPerSecond = 80.0
        var turnThresholdDegrees = 15.0
        var maxDrivePulse = 0.55
        var maxTurnPulse = 0.45
    }

    private struct Segment {
        let readyAt: Date
        let distanceDeltaMeters: Double
        let targetHeading: Double
    }

    @Published private(set) var isActive = false
    @Published private(set) var state = "OFF"

    var settings = Settings()

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

    init(droid: DirectDroidBLE) {
        self.droid = droid
    }

    func start(initialHeading: Double) {
        stop(reason: "Restarting", updateState: false)

        guard droid.isConnected else {
            state = "R2 NOT CONNECTED"
            return
        }

        referenceHeading = normalized360(initialHeading)
        estimatedDroidHeading = 0
        latestTargetHeading = 0
        lastQueuedHeading = 0
        lastTotalDistance = 0
        accumulatedDistance = 0
        queue.removeAll()
        executing = false
        isActive = true
        state = "FOLLOWING / WAITING FOR STEPS"

        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func accept(totalDistanceMeters: Double, headingDegrees: Double) {
        guard isActive, droid.isConnected else { return }

        let total = max(0, totalDistanceMeters)
        let delta = max(0, min(1.5, total - lastTotalDistance))
        lastTotalDistance = total

        let relativeHeading = shortestAngle(normalized360(headingDegrees) - referenceHeading)
        let headingChanged = abs(shortestAngle(relativeHeading - lastQueuedHeading)) >= settings.turnThresholdDegrees

        if delta >= 0.015 || headingChanged {
            queue.append(
                Segment(
                    readyAt: Date().addingTimeInterval(max(0, settings.shadowDelay)),
                    distanceDeltaMeters: delta,
                    targetHeading: relativeHeading
                )
            )
            lastQueuedHeading = relativeHeading

            if queue.count > 80 {
                queue.removeFirst(queue.count - 80)
            }
        }
    }

    func stop(reason: String = "Stopped", updateState: Bool = true) {
        processingTimer?.invalidate()
        processingTimer = nil
        queue.removeAll()
        accumulatedDistance = 0
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

        guard !executing else { return }

        while let first = queue.first, first.readyAt <= Date() {
            queue.removeFirst()
            accumulatedDistance += first.distanceDeltaMeters
            latestTargetHeading = first.targetHeading
        }

        let difference = shortestAngle(latestTargetHeading - estimatedDroidHeading)
        if abs(difference) >= settings.turnThresholdDegrees {
            performTurn(difference)
            return
        }

        if accumulatedDistance >= settings.minimumDistanceMeters {
            performForwardPulse()
            return
        }

        state = queue.isEmpty ? "FOLLOWING / WAITING" : "FOLLOWING / DELAY BUFFER"
    }

    private func performTurn(_ difference: Double) {
        let degreesPerSecond = max(20, settings.turnDegreesPerSecond)
        let requestedDuration = abs(difference) / degreesPerSecond
        let duration = min(max(0.08, requestedDuration), max(0.10, settings.maxTurnPulse))
        let speed = UInt8(clamping: max(40, min(settings.maxSpeed, settings.turnSpeed)))

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
            let signedDegrees = (difference < 0 ? -1.0 : 1.0) * duration * degreesPerSecond
            self.estimatedDroidHeading = self.shortestAngle(self.estimatedDroidHeading + signedDegrees)
            self.executing = false
        }
    }

    private func performForwardPulse() {
        let secondsPerMeter = max(0.5, settings.secondsPerMeter)
        let requestedDuration = accumulatedDistance * secondsPerMeter
        let duration = min(max(0.08, requestedDuration), max(0.10, settings.maxDrivePulse))
        let speed = UInt8(clamping: max(40, min(100, settings.maxSpeed)))

        executing = true
        droid.forward(speed: speed)
        state = "FOLLOWING / CATCH UP"

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.isActive else { return }
            self.droid.stopDrive()
            let consumedMeters = duration / secondsPerMeter
            self.accumulatedDistance = max(0, self.accumulatedDistance - consumedMeters)
            self.executing = false
        }
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
