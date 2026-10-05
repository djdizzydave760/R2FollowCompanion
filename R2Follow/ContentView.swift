import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: FollowAppModel
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    connectionCard
                    setupCard
                    voiceCard
                    followCard
                    telemetryCard
                    safetyCard
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [Color.black, Color(red: 0.02, green: 0.08, blue: 0.12), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("R2 Follow")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                model.syncBridgeSettings()
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.cyan)
                .shadow(color: .cyan.opacity(0.7), radius: 12)
            Text("SHADOW FOLLOW BETA")
                .font(.headline.monospaced().bold())
                .foregroundStyle(.cyan)
            Text("iPhone 14 Pro → Wi-Fi → Droid Control Mac → Bluetooth → R2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var connectionCard: some View {
        card("MAC CONNECTION", icon: "desktopcomputer") {
            TextField("Mac IP (example 192.168.1.25)", text: $model.macHost)
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Port", text: $model.macPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                SecureField("API token from Droid Control", text: $model.token)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
            }
            Button("Test Connection") {
                Task { await model.testConnection() }
            }
            .buttonStyle(.borderedProminent)
            Text(model.bridge.lastMessage)
                .font(.caption)
                .foregroundStyle(model.bridge.reachable ? .green : .secondary)
        }
    }

    private var setupCard: some View {
        card("CALIBRATE", icon: "safari") {
            Text("First tap Enable iPhone Sensors and approve the iOS prompts. Then calibrate with R2 behind you, both facing the same direction.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Enable iPhone Sensors") {
                model.requestPermissions()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            Text("1. Put R2 4–6 ft behind you and point R2 in the same direction you are facing.\n2. Hold the iPhone upright with the top edge pointing forward.\n3. Tap Calibrate.\n4. Put the phone into your pocket in a consistent top-up orientation.\n5. Tap Start Follow and walk slowly.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Calibrate Forward") {
                model.calibrate()
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            if let heading = model.calibratedHeading {
                Text("Reference heading: \(Int(heading.rounded()))°")
                    .font(.caption.monospaced())
                    .foregroundStyle(.cyan)
            }
        }
    }

    private var voiceCard: some View {
        card("R2 VOICE COMMANDS", icon: "mic.fill") {
            Text("Hands-free commands use the iPhone microphone while this app is open. Commands only trigger when R2 is heard first.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.voice.isListening {
                Button(role: .destructive) {
                    model.stopVoiceCommands()
                } label: {
                    Label("Stop Voice Commands", systemImage: "mic.slash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await model.startVoiceCommands() }
                } label: {
                    Label("Start Voice Commands", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }

            metric("Microphone", model.voice.isListening ? "Listening" : "Off")
            metric("Heard", model.voice.transcript)
            metric("Last command", model.voice.lastCommand)

            Text(model.voice.permissionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("VOICE COMMANDS")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.cyan)
                Text("Personality: R2 speak • R2 hello • R2 what do you think • R2 be happy • R2 get excited • R2 alert • R2 go to sleep • R2 wake up")
                Text("Dome: R2 look left • R2 look right • R2 center • R2 scan the area")
                Text("Movement: R2 turn left • R2 turn right • R2 spin left • R2 spin right • R2 dance")
                Text("Lights: R2 lights on • R2 lights off")
                Text("Batuu: R2 resistance • R2 first order • R2 droid depot")
                Text("Follow: R2 follow me • R2 stop following • R2 stop")
            }
            .font(.caption)
            .foregroundStyle(.cyan)
            .textSelection(.enabled)
        }
    }

    private var followCard: some View {
        card("FOLLOW CONTROL", icon: "figure.walk.motion") {
            if model.isFollowing {
                Button(role: .destructive) {
                    Task { await model.stopFollow() }
                } label: {
                    Label("Stop Follow", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await model.startFollow() }
                } label: {
                    Label("Start Pocket Follow", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            Button(role: .destructive) {
                Task { await model.emergencyStop() }
            } label: {
                Label("EMERGENCY STOP", systemImage: "exclamationmark.octagon.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text(model.status)
                .font(.caption.monospaced())
                .foregroundStyle(model.isFollowing ? .green : .secondary)
        }
    }

    private var telemetryCard: some View {
        card("LIVE PHONE TELEMETRY", icon: "waveform.path.ecg") {
            metric("Heading", String(format: "%.0f°", model.motion.heading))
            metric("Heading accuracy", model.motion.headingAccuracy >= 0 ? String(format: "±%.0f°", model.motion.headingAccuracy) : "—")
            metric("Walked", String(format: "%.2f m", model.motion.totalDistance))
            metric("Motion", model.motion.moving ? "Moving" : "Still")
            metric("Sequence", "\(model.sequence)")
            Text(model.motion.permissionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        card("IMPORTANT", icon: "shield.lefthalf.filled") {
            Text("This is not true location tracking. It estimates your route from the iPhone and asks R2 to replay it after a delay. R2 cannot see stairs, pets, people, furniture, or walls. Test only on a clear single-level floor and stay close enough to reach the Emergency Stop immediately.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospaced().bold())
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.cyan)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
        )
    }
}
