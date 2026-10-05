import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: FollowAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    modeCard

                    if model.connectionMode == .directBluetooth {
                        directBluetoothCard
                    } else {
                        connectionCard
                    }

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
                    colors: [
                        Color.black,
                        Color(red: 0.02, green: 0.08, blue: 0.12),
                        Color.black
                    ],
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
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    model.appDidEnterBackground()
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: model.connectionMode == .directBluetooth
                  ? "dot.radiowaves.left.and.right"
                  : "location.north.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.cyan)
                .shadow(color: .cyan.opacity(0.7), radius: 12)

            Text(
                model.connectionMode == .directBluetooth
                    ? "R2 DIRECT BLUETOOTH"
                    : "SHADOW FOLLOW • MAC BRIDGE"
            )
            .font(.headline.monospaced().bold())
            .foregroundStyle(.cyan)

            Text(
                model.connectionMode == .directBluetooth
                    ? "iPhone → Bluetooth → R2 • No Wi-Fi or Mac required"
                    : "iPhone → Wi-Fi → Droid Control Mac → Bluetooth → R2"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var modeCard: some View {
        card("CONNECTION MODE", icon: "arrow.triangle.branch") {
            Picker("Connection Mode", selection: $model.connectionMode) {
                ForEach(ConnectionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isFollowing)

            Text(
                model.connectionMode == .directBluetooth
                    ? "Portable mode. Your iPhone controls R2 directly over Bluetooth."
                    : "Legacy mode. Your iPhone sends commands to Droid Control on the Mac."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var directBluetoothCard: some View {
        card("DIRECT R2 BLUETOOTH", icon: "antenna.radiowaves.left.and.right") {
            Text("Disconnect R2 from Droid Control on the Mac before connecting here. If several DROID units are nearby, choose yours from the list instead of connecting automatically.")
                .font(.caption)
                .foregroundStyle(.orange)

            if model.directBLE.isConnected {
                Label(
                    "Connected • \(model.directBLE.connectedName)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                Button(role: .destructive) {
                    model.disconnectDirectDroid()
                } label: {
                    Label("Disconnect R2", systemImage: "bolt.slash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    model.scanForR2()
                } label: {
                    Label(
                        model.directBLE.isScanning ? "Scanning…" : "Scan for R2",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(model.directBLE.isScanning)

                if model.directBLE.isScanning {
                    ProgressView()
                }

                ForEach(model.directBLE.devices) { device in
                    Button {
                        model.connectDirectDroid(device)
                    } label: {
                        HStack {
                            Image(systemName: "circle.hexagongrid.fill")
                            Text(device.displayName)
                                .font(.caption.monospaced())
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(model.directBLE.status)
                .font(.caption.monospaced())
                .foregroundStyle(model.directBLE.isConnected ? .green : .secondary)
        }
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
            Text("First enable iPhone sensors. Then put R2 4–6 ft behind you, with R2 facing the same direction you are facing.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Enable iPhone Sensors") {
                model.requestPermissions()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Text("1. Hold the iPhone upright with its top edge pointing forward.\n2. Tap Calibrate Forward.\n3. Put the phone in your pocket in a consistent top-up orientation.\n4. Start Follow and walk slowly.")
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
            Text(
                model.connectionMode == .directBluetooth
                    ? "Voice commands are sent directly from the iPhone to R2 over Bluetooth."
                    : "Voice commands are sent through Droid Control on the Mac."
            )
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
            if model.connectionMode == .directBluetooth {
                Label(
                    "Direct Bluetooth • no Wi-Fi required",
                    systemImage: "bolt.horizontal.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }

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
            metric("Mode", model.connectionMode.rawValue)
            metric("Heading", String(format: "%.0f°", model.motion.heading))
            metric(
                "Heading accuracy",
                model.motion.headingAccuracy >= 0
                    ? String(format: "±%.0f°", model.motion.headingAccuracy)
                    : "—"
            )
            metric("Walked", String(format: "%.2f m", model.motion.totalDistance))
            metric("Motion", model.motion.moving ? "Moving" : "Still")
            metric("Sequence", "\(model.sequence)")

            if model.connectionMode == .directBluetooth {
                metric("Direct Follow", model.directFollow.state)
            }

            Text(model.motion.permissionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        card("IMPORTANT", icon: "shield.lefthalf.filled") {
            Text("Direct Bluetooth removes the Wi-Fi and Mac dependency, but it does not turn R2 into a true position-tracking robot. Follow still estimates your route from the iPhone. R2 cannot see stairs, pets, people, furniture, walls, curbs, or traffic. Test on a clear, flat, single-level area and stay close enough to stop R2 immediately.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospaced().bold())
                .multilineTextAlignment(.trailing)
        }
    }

    private func card<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
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
