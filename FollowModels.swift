import Foundation

struct FollowStartPayload: Codable {
    let sessionID: String
    let initialHeading: Double
}

struct FollowTelemetryPayload: Codable {
    let sessionID: String
    let sequence: Int
    let timestamp: Double
    let totalDistanceMeters: Double
    let headingDegrees: Double
    let headingAccuracy: Double
    let moving: Bool
}

struct StatusEnvelope: Codable {
    let ok: Bool?
    let connected: Bool?
    let armed: Bool?
    let active: Bool?
    let droidConnected: Bool?
    let state: String?
    let error: String?
}
