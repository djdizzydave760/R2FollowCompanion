import Foundation

struct R2SoundBeatEvent: Codable, Hashable {
    let t: Double
    let intensity: Double
    let mask: Int
    let width: Double
}

struct R2SoundProfile: Codable, Hashable, Identifiable {
    let file: String
    let label: String
    let mood: String
    let duration: Double
    let headStyle: String
    let events: [R2SoundBeatEvent]

    var id: String { file }
}

struct R2SoundBatchManifest: Codable {
    let version: Int
    let source: String
    let count: Int
    let lightsDefault: String
    let behavior: String
    let sounds: [R2SoundProfile]
}
