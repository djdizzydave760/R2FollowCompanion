import Foundation
import CoreMotion
import CoreLocation
import UIKit

@MainActor
final class MotionTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var heading = 0.0
    @Published var headingAccuracy = -1.0
    @Published var totalDistance = 0.0
    @Published var moving = false
    @Published var permissionMessage = "Permissions not requested"

    private let pedometer = CMPedometer()
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private var motionTimer: Timer?
    private var lastAcceleration = 0.0

    override init() {
        super.init()
        location.delegate = self
        location.headingFilter = 1
        location.headingOrientation = .portrait
    }

    func requestPermissions() {
        location.requestWhenInUseAuthorization()
        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        }

        // Starting a short pedometer query prompts Motion & Fitness permission if needed.
        if CMPedometer.isDistanceAvailable() {
            pedometer.queryPedometerData(from: Date().addingTimeInterval(-1), to: Date()) { _, _ in }
        }
        permissionMessage = "Requested motion + compass access"
    }

    func startTracking() {
        totalDistance = 0
        moving = false

        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        }

        if CMPedometer.isDistanceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.totalDistance = data?.distance?.doubleValue ?? self.totalDistance
                    if let pace = data?.currentPace?.doubleValue {
                        self.moving = pace > 0 && pace < 10
                    }
                }
            }
        }

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.15
            motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
                guard let self, let sample else { return }
                let a = sample.userAcceleration
                let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                self.lastAcceleration = magnitude
                if magnitude > 0.035 { self.moving = true }
            }
        }
    }

    func stopTracking() {
        pedometer.stopUpdates()
        motion.stopDeviceMotionUpdates()
        moving = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        heading = value
        headingAccuracy = newHeading.headingAccuracy
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            permissionMessage = "Compass permission ready"
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        case .denied, .restricted:
            permissionMessage = "Location/compass permission denied"
        case .notDetermined:
            permissionMessage = "Waiting for location permission"
        @unknown default:
            permissionMessage = "Unknown location permission state"
        }
    }
}
