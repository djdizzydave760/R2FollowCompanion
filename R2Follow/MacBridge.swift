import Foundation

@MainActor
final class MacBridge: ObservableObject {
    @Published var lastMessage = "Not connected"
    @Published var reachable = false

    var host = ""
    var port = "8782"
    var token = ""

    private var baseURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "http://\(normalized):\(port)")
    }

    func testConnection() async {
        do {
            let data = try await request(path: "/status", method: "GET", body: Optional<Data>.none)
            let decoded = try? JSONDecoder().decode(StatusEnvelope.self, from: data)
            reachable = true
            if decoded?.connected == true {
                lastMessage = "Mac reached • R2 connected"
            } else {
                lastMessage = "Mac reached • R2 not connected"
            }
        } catch {
            reachable = false
            lastMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func followStatus() async -> StatusEnvelope? {
        do {
            let data = try await request(path: "/follow/status", method: "GET", body: Optional<Data>.none)
            reachable = true
            return try? JSONDecoder().decode(StatusEnvelope.self, from: data)
        } catch {
            reachable = false
            lastMessage = "Follow status failed: \(error.localizedDescription)"
            return nil
        }
    }

    func startFollow(_ payload: FollowStartPayload) async throws {
        let data = try JSONEncoder().encode(payload)
        _ = try await request(path: "/follow/start", method: "POST", body: data)
        reachable = true
        lastMessage = "Follow session accepted by Mac"
    }

    func sendTelemetry(_ payload: FollowTelemetryPayload) async throws {
        let data = try JSONEncoder().encode(payload)
        _ = try await request(path: "/follow/telemetry", method: "POST", body: data)
        reachable = true
    }

    func stopFollow() async {
        do {
            _ = try await request(path: "/follow/stop", method: "POST", body: Data())
            lastMessage = "Follow stopped"
        } catch {
            lastMessage = "Stop request failed: \(error.localizedDescription)"
        }
    }

    func emergencyStop() async {
        do {
            _ = try await request(path: "/action/stop", method: "POST", body: Data())
            lastMessage = "Emergency stop sent"
        } catch {
            lastMessage = "Emergency stop failed: \(error.localizedDescription)"
        }
    }

    func chirp() async throws {
        _ = try await request(path: "/action/chirp", method: "POST", body: Data())
        reachable = true
        lastMessage = "R2 spoke"
    }

    func reaction(_ name: String) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await request(path: "/reaction/\(encoded)", method: "POST", body: Data())
        reachable = true
        lastMessage = "R2 reaction: \(name)"
    }

    func spin() async throws {
        _ = try await request(path: "/action/spin", method: "POST", body: Data())
        reachable = true
        lastMessage = "R2 spin"
    }

    func centerDome() async throws {
        _ = try await request(path: "/action/center", method: "POST", body: Data())
        reachable = true
        lastMessage = "R2 dome centered"
    }

    private func request(path: String, method: String, body: Data?) async throws -> Data {
        guard let baseURL else { throw BridgeError.invalidAddress }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 3.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Droid-Token")
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BridgeError.server(message)
        }
        return data
    }

    enum BridgeError: LocalizedError {
        case invalidAddress
        case badResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Enter the Mac IP address shown in Droid Control."
            case .badResponse: return "Invalid response from Mac."
            case .server(let text): return text
            }
        }
    }
}
