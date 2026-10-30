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

    // Hybrid Follow GPS/course telemetry.
    @Published var latitude = 0.0
    @Published var longitude = 0.0
    @Published var horizontalAccuracy = -1.0
    @Published var course = -1.0
    @Published var courseAccuracy = -1.0
    @Published var speed = -1.0
    @Published var gpsStatus = "GPS not started"
    @Published var locationAge = Double.infinity
    @Published var pathBearing = -1.0
    @Published var breadcrumbCount = 0
    @Published var gpsPathDistance = 0.0
    @Published var breadcrumbAge = Double.infinity

    private let pedometer = CMPedometer()
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private var lastAcceleration = 0.0
    private var lastMotionActivityAt = Date.distantPast
    private var latestLocationTimestamp = Date.distantPast
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var lastBreadcrumb: CLLocation?
    private var latestBreadcrumbTimestamp = Date.distantPast

    override init() {
        super.init()
        location.delegate = self
        location.headingFilter = 2
        location.headingOrientation = .portrait
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.activityType = .fitness
        location.pausesLocationUpdatesAutomatically = false
    }

    var gpsCourseUsable: Bool {
        course >= 0 &&
        course < 360 &&
        speed >= 0.35 &&
        horizontalAccuracy >= 0 &&
        horizontalAccuracy <= 15 &&
        (courseAccuracy < 0 || courseAccuracy <= 35) &&
        locationAge <= 2.0
    }


    var breadcrumbCourseUsable: Bool {
        pathBearing >= 0 &&
        pathBearing < 360 &&
        horizontalAccuracy >= 0 &&
        horizontalAccuracy <= 15 &&
        breadcrumbAge <= 3.0
    }

    var bestPathCourse: Double {
        breadcrumbCourseUsable ? pathBearing : course
    }

    var bestPathCourseUsable: Bool {
        breadcrumbCourseUsable || gpsCourseUsable
    }

    func requestPermissions() {
        location.requestWhenInUseAuthorization()

        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        }

        // Ask Core Location for real walking positions as well as compass data.
        location.startUpdatingLocation()

        if CMPedometer.isDistanceAvailable() {
            pedometer.queryPedometerData(
                from: Date().addingTimeInterval(-1),
                to: Date()
            ) { _, _ in }
        }

        permissionMessage = "Requested GPS + motion + compass access"
    }

    func startBackgroundFollowSession() {
        // This is only active during a user-started Follow session.
        // CLBackgroundActivitySession keeps When-In-Use location eligible for
        // timely background delivery while the screen is locked.
        if #available(iOS 17.0, *) {
            if backgroundActivitySession == nil {
                backgroundActivitySession = CLBackgroundActivitySession()
            }
        }

        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.pausesLocationUpdatesAutomatically = false
        location.startUpdatingLocation()
        gpsStatus = "Background GPS active"
    }

    func stopBackgroundFollowSession() {
        if #available(iOS 17.0, *) {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
        }

        location.allowsBackgroundLocationUpdates = false
        location.showsBackgroundLocationIndicator = false
    }

    func startTracking() {
        totalDistance = 0
        moving = false
        lastMotionActivityAt = Date.distantPast
        lastBreadcrumb = nil
        latestBreadcrumbTimestamp = .distantPast
        pathBearing = -1
        breadcrumbCount = 0
        gpsPathDistance = 0
        breadcrumbAge = .infinity

        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        }

        location.startUpdatingLocation()

        if CMPedometer.isDistanceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let self else { return }

                Task { @MainActor in
                    self.totalDistance =
                        data?.distance?.doubleValue ??
                        self.totalDistance

                    if let pace = data?.currentPace?.doubleValue {
                        if pace > 0 && pace < 10 {
                            self.lastMotionActivityAt = Date()
                            self.moving = true
                        }
                    }
                }
            }
        }

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.10
            motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
                guard let self, let sample else { return }

                let a = sample.userAcceleration
                let magnitude = sqrt(
                    a.x * a.x +
                    a.y * a.y +
                    a.z * a.z
                )

                self.lastAcceleration = magnitude

                if magnitude > 0.035 {
                    self.lastMotionActivityAt = Date()
                    self.moving = true
                } else if Date().timeIntervalSince(self.lastMotionActivityAt) > 0.75 {
                    self.moving = false
                }

                if self.latestLocationTimestamp != .distantPast {
                    self.locationAge =
                        Date().timeIntervalSince(self.latestLocationTimestamp)
                }

                if self.latestBreadcrumbTimestamp != .distantPast {
                    self.breadcrumbAge =
                        Date().timeIntervalSince(self.latestBreadcrumbTimestamp)
                }
            }
        }
    }

    func stopTracking() {
        pedometer.stopUpdates()
        motion.stopDeviceMotionUpdates()
        stopBackgroundFollowSession()
        location.stopUpdatingLocation()
        moving = false
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let sample = locations.last else { return }
        guard sample.horizontalAccuracy >= 0 else { return }

        latitude = sample.coordinate.latitude
        longitude = sample.coordinate.longitude
        horizontalAccuracy = sample.horizontalAccuracy
        speed = sample.speed
        course = sample.course

        if #available(iOS 13.4, *) {
            courseAccuracy = sample.courseAccuracy
        } else {
            courseAccuracy = -1
        }

        latestLocationTimestamp = sample.timestamp
        locationAge = max(0, Date().timeIntervalSince(sample.timestamp))

        if sample.horizontalAccuracy <= 15 {
            if let previous = lastBreadcrumb {
                let displacement = sample.distance(from: previous)
                let accuracyFloor = max(
                    0.85,
                    min(
                        2.25,
                        max(
                            sample.horizontalAccuracy,
                            previous.horizontalAccuracy
                        ) * 0.24
                    )
                )

                if displacement >= accuracyFloor {
                    let bearing = bearingDegrees(
                        from: previous.coordinate,
                        to: sample.coordinate
                    )

                    if pathBearing < 0 {
                        pathBearing = bearing
                    } else {
                        pathBearing = circularBlend(
                            from: pathBearing,
                            to: bearing,
                            alpha: 0.28
                        )
                    }

                    gpsPathDistance += displacement
                    breadcrumbCount += 1
                    lastBreadcrumb = sample
                    latestBreadcrumbTimestamp = sample.timestamp
                    breadcrumbAge = 0
                }
            } else {
                lastBreadcrumb = sample
                latestBreadcrumbTimestamp = sample.timestamp
                breadcrumbAge = 0
            }
        }

        if horizontalAccuracy <= 5 {
            gpsStatus = "GPS excellent"
        } else if horizontalAccuracy <= 10 {
            gpsStatus = "GPS good"
        } else if horizontalAccuracy <= 15 {
            gpsStatus = "GPS usable"
        } else {
            gpsStatus = "GPS weak • steering held"
        }

        if sample.speed > 0.35 {
            lastMotionActivityAt = Date()
            moving = true
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        gpsStatus = "GPS error: \(error.localizedDescription)"
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        let value =
            newHeading.trueHeading >= 0
            ? newHeading.trueHeading
            : newHeading.magneticHeading

        heading = value
        headingAccuracy = newHeading.headingAccuracy
    }

    private func bearingDegrees(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLon =
            (to.longitude - from.longitude) *
            .pi / 180

        let y = sin(deltaLon) * cos(lat2)
        let x =
            cos(lat1) * sin(lat2) -
            sin(lat1) * cos(lat2) * cos(deltaLon)

        var degrees = atan2(y, x) * 180 / .pi

        if degrees < 0 {
            degrees += 360
        }

        return degrees
    }

    private func circularBlend(
        from: Double,
        to: Double,
        alpha: Double
    ) -> Double {
        var difference =
            (to - from).truncatingRemainder(
                dividingBy: 360
            )

        if difference > 180 {
            difference -= 360
        }

        if difference < -180 {
            difference += 360
        }

        var result = from + difference * alpha
        result = result.truncatingRemainder(
            dividingBy: 360
        )

        if result < 0 {
            result += 360
        }

        return result
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            permissionMessage = "GPS + compass permission ready"

            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }

            manager.startUpdatingLocation()

        case .denied, .restricted:
            permissionMessage = "Location/GPS permission denied"

        case .notDetermined:
            permissionMessage = "Waiting for location permission"

        @unknown default:
            permissionMessage = "Unknown location permission state"
        }
    }
}
