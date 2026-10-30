import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: FollowAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdvancedFollow = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    modeCard

                    if model.connectionMode == .directBluetooth {
                        directBluetoothCard
                        r2ModeCard

                        if model.operationMode == .hybridFollow {
                            r2CalibrationCard
                            setupCard
                        }
                    } else {
                        connectionCard
                        setupCard
                    }

                    voiceCard

                    if model.connectionMode == .macBridge ||
                       model.operationMode == .hybridFollow {
                        followCard
                    }

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
                } else if phase == .active {
                    model.appDidBecomeActive()
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

                Button {
                    model.testR2HeadAndVoice()
                } label: {
                    Label("Test Head + Voice", systemImage: "waveform.and.person.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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

    private var r2ModeCard: some View {
        card("R2 MODE + PERSONALITY", icon: "sparkles") {
            Picker("R2 Mode", selection: $model.operationMode) {
                ForEach(R2OperationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Personality", selection: $model.personalityMode) {
                ForEach(R2PersonalityMode.allCases) { personality in
                    Text(personality.rawValue).tag(personality)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Head movement + sounds + natural lights",
                isOn: $model.directFollow.personalityEnabled
            )
            .tint(.cyan)

            if model.operationMode == .backpack {
                Label(
                    "BACKPACK SAFE • wheel motors physically locked by the app",
                    systemImage: "lock.shield.fill"
                )
                .font(.caption.monospaced().bold())
                .foregroundStyle(.green)

                Text("R2 can turn his dome, chirp, react to voice commands and blink his lights, but all wheel/drive commands are blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "HYBRID FOLLOW • GPS path + motion + Bluetooth spacing",
                    systemImage: "location.north.line.fill"
                )
                .font(.caption.monospaced().bold())
                .foregroundStyle(.green)

                Text("R2 replays your walking direction from GPS course and motion while Bluetooth acts as the close-range 3–4 ft brake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                switch model.personalityMode {
                case .relaxed:
                    Text("Relaxed • slower head glances, occasional chirps, gentle light activity")
                case .excited:
                    Text("Excited • frequent head movement, more talking and lively lights")
                case .patrol:
                    Text("On Patrol • frequent scanning head movement, alert-style responses and active lights")
                case .curious:
                    Text("Curious • lots of head glances and conversational reactions")
                case .quiet:
                    Text("Quiet • head and lights stay alive with very little talking")
                }
            }
            .font(.caption)
            .foregroundStyle(.cyan)
        }
    }

    private var r2CalibrationCard: some View {
        card("HYBRID FOLLOW CALIBRATION", icon: "iphone.radiowaves.left.and.right") {
            Text("Put the iPhone about 3.5 ft from R2 and save the Bluetooth signal as the target gap. Outdoors, GPS course supplies the walking path; motion fills short gaps; Bluetooth prevents R2 from getting too close.")
                .font(.caption)
                .foregroundStyle(.secondary)

            metric("Live Bluetooth", String(format: "%.0f dBm", model.directBLE.smoothedRSSI))
            metric("3.5-ft target", model.directFollow.proximityState)

            Button {
                model.calibrateTwoFootStop()
            } label: {
                Label("Set Current Phone Position as 3.5 ft", systemImage: "ruler.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!model.directBLE.isConnected || model.isFollowing)

            Toggle("R2 alive while idle + walking", isOn: $model.directFollow.personalityEnabled)
                .tint(.cyan)

            Text("Hybrid steering uses GPS course, not pocket-compass chasing. If GPS becomes weak, R2 holds the last reliable path direction instead of repeatedly spinning for compass corrections.")
                .font(.caption)
                .foregroundStyle(.orange)

            DisclosureGroup("Advanced Hybrid Follow tuning", isExpanded: $showAdvancedFollow) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Turn correction enabled", isOn: $model.directFollow.turnCorrectionEnabled)
                        .tint(.cyan)
                        .disabled(model.isFollowing)

                    Button {
                        model.markR2AlignedWithPhone()
                    } label: {
                        Label("Align R2 + iPhone Heading", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.directBLE.isConnected || model.isFollowing)

                    HStack {
                        Button("← Test Left") {
                            model.testR2TurnLeft()
                        }
                        .buttonStyle(.bordered)

                        Button("Test Forward ↑") {
                            model.testR2Forward()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button("Test Right →") {
                            model.testR2TurnRight()
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(!model.directBLE.isConnected || model.isFollowing)

                    calibrationSlider(
                        "Follow delay",
                        value: $model.directFollow.shadowDelay,
                        range: 0.20...1.20,
                        step: 0.05,
                        valueText: String(format: "%.2f sec", model.directFollow.shadowDelay)
                    )

                    calibrationSlider(
                        "Path trail distance",
                        value: $model.directFollow.trailDistanceMeters,
                        range: 0.75...1.80,
                        step: 0.05,
                        valueText: String(format: "%.2f m", model.directFollow.trailDistanceMeters)
                    )

                    calibrationSlider(
                        "Forward speed",
                        value: $model.directFollow.driveSpeed,
                        range: 55...100,
                        step: 1,
                        valueText: String(format: "%.0f", model.directFollow.driveSpeed)
                    )

                    calibrationSlider(
                        "Forward distance",
                        value: $model.directFollow.secondsPerMeter,
                        range: 1.8...4.5,
                        step: 0.05,
                        valueText: String(format: "%.2f", model.directFollow.secondsPerMeter)
                    )

                    calibrationSlider(
                        "Turn speed",
                        value: $model.directFollow.turnSpeed,
                        range: 45...85,
                        step: 1,
                        valueText: String(format: "%.0f", model.directFollow.turnSpeed)
                    )

                    calibrationSlider(
                        "Turn dead zone",
                        value: $model.directFollow.turnDeadbandDegrees,
                        range: 10...35,
                        step: 1,
                        valueText: String(format: "%.0f°", model.directFollow.turnDeadbandDegrees)
                    )

                    Button("Restore Recommended Settings") {
                        model.resetFollowCalibration()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isFollowing)
                }
                .padding(.top, 8)
            }
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
        card("PHONE TRACKING", icon: "location.fill") {
            Text(
                model.connectionMode == .directBluetooth
                    ? "Hybrid Follow uses GPS course + Motion & Fitness. You no longer need to keep the iPhone pointed like a compass."
                    : "Mac Bridge mode still uses the original motion/heading calibration."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Button(
                model.connectionMode == .directBluetooth
                    ? "Enable GPS + Motion Tracking"
                    : "Enable iPhone Sensors"
            ) {
                model.requestPermissions()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            if model.connectionMode == .directBluetooth {
                metric("GPS", model.motion.gpsStatus)
                metric(
                    "GPS accuracy",
                    model.motion.horizontalAccuracy >= 0
                        ? String(format: "±%.1f m", model.motion.horizontalAccuracy)
                        : "—"
                )
                metric(
                    "GPS course",
                    model.motion.course >= 0
                        ? String(format: "%.0f°", model.motion.course)
                        : "—"
                )
                metric(
                    "Breadcrumb bearing",
                    model.motion.pathBearing >= 0
                        ? String(format: "%.0f°", model.motion.pathBearing)
                        : "—"
                )
                metric("Breadcrumbs", "\(model.motion.breadcrumbCount)")

                Text("Best results are outdoors with a clear view of the sky. Start R2 behind you facing the same general direction, then walk several feet so the phone can establish a GPS course.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
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
                    "Hybrid Follow • faster start • GPS breadcrumbs • ~3–4 ft Bluetooth brake",
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
                metric("Operation", model.operationMode.rawValue)
                metric("Personality", model.personalityMode.rawValue)
                metric("Direct Follow", model.directFollow.state)
                metric("Tracking", model.directFollow.trackingQuality)
                metric("Bluetooth", String(format: "%.0f dBm", model.directBLE.smoothedRSSI))
                metric("GPS", model.motion.gpsStatus)
                metric(
                    "GPS accuracy",
                    model.motion.horizontalAccuracy >= 0
                        ? String(format: "±%.1f m", model.motion.horizontalAccuracy)
                        : "—"
                )
                metric(
                    "GPS course",
                    model.motion.course >= 0
                        ? String(format: "%.0f°", model.motion.course)
                        : "—"
                )
                metric("Filtered path turn", String(format: "%.0f°", model.directFollow.filteredHeading))
                metric("Heading error", String(format: "%.0f°", model.directFollow.headingError))
                metric("Drive queued", String(format: "%.2f m", model.directFollow.queuedDistance))
            }

            Text(model.motion.permissionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        card("IMPORTANT", icon: "shield.lefthalf.filled") {
            Text("Hybrid Follow improves path direction outdoors, but the stock R2 still has no GPS/UWB sensor of his own. The phone estimates the path and R2 dead-reckons through motor commands; Bluetooth spacing is approximate. Backpack Mode hard-locks the wheel motors. R2 cannot detect stairs, curbs, people, pets, walls, furniture, vehicles or traffic.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func calibrationSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.cyan)
            }

            Slider(value: value, in: range, step: step)
                .disabled(model.isFollowing)
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
