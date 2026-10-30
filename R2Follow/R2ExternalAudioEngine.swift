import Foundation
import AVFoundation
import Combine

@MainActor
final class R2ExternalAudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var routeDescription = "No active audio route"
    @Published private(set) var status = "External audio off"
    @Published private(set) var isBluetoothA2DP = false
    @Published private(set) var outputVolume: Float = 0

    private let engine = AVAudioEngine()
    private let ambientNode = AVAudioPlayerNode()
    private let effectNode = AVAudioPlayerNode()

    private let format = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!

    private var configured = false
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    init() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRoute()
                self?.restartEngineIfNeeded()
            }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard
                    let self,
                    let info = notification.userInfo,
                    let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else {
                    return
                }

                switch type {
                case .began:
                    self.status = "Audio interrupted"

                case .ended:
                    self.activatePlaybackSession()
                    self.restartEngineIfNeeded()

                @unknown default:
                    break
                }
            }
        }

        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configured = false
                self?.activatePlaybackSession()
                self?.restartEngineIfNeeded()
            }
        }
    }

    deinit {
        [routeObserver, interruptionObserver, mediaResetObserver]
            .compactMap { $0 }
            .forEach {
                NotificationCenter.default.removeObserver($0)
            }
    }

    func start() {
        activatePlaybackSession()
        configureEngineIfNeeded()
        restartEngineIfNeeded()
        refreshRoute()

        if isRunning {
            status = isBluetoothA2DP
                ? "External audio active • Bluetooth speaker selected"
                : "External audio active • output is NOT Bluetooth A2DP"
        }
    }

    func stop() {
        ambientNode.stop()
        effectNode.stop()
        engine.stop()
        isRunning = false

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )

        status = "External audio off"
        refreshRoute()
    }

    func playDroidChirp(
        intensity: Double = 0.70
    ) {
        activatePlaybackSession()
        configureEngineIfNeeded()
        restartEngineIfNeeded()
        refreshRoute()

        guard isRunning else {
            status = "Audio engine is not running"
            return
        }

        let buffer = makeChirpBuffer(
            intensity: max(0.30, min(1.0, intensity))
        )

        effectNode.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionHandler: nil
        )

        if !effectNode.isPlaying {
            effectNode.play()
        }

        status = isBluetoothA2DP
            ? "R2 sound sent to Bluetooth A2DP"
            : "R2 sound playing • active route: \(routeDescription)"
    }

    func playLoudRouteTest() {
        activatePlaybackSession()
        configureEngineIfNeeded()
        restartEngineIfNeeded()
        refreshRoute()

        guard isRunning else {
            status = "Could not start audio engine"
            return
        }

        effectNode.stop()
        effectNode.play()

        let first = makeTestToneBuffer(
            frequency: 720,
            duration: 0.42,
            level: 0.75
        )

        let second = makeTestToneBuffer(
            frequency: 1_080,
            duration: 0.42,
            level: 0.75
        )

        let third = makeChirpBuffer(intensity: 1.0)

        effectNode.scheduleBuffer(
            first,
            at: nil,
            options: [],
            completionHandler: nil
        )

        effectNode.scheduleBuffer(
            second,
            at: nil,
            options: [],
            completionHandler: nil
        )

        effectNode.scheduleBuffer(
            third,
            at: nil,
            options: [],
            completionHandler: nil
        )

        if !effectNode.isPlaying {
            effectNode.play()
        }

        status = isBluetoothA2DP
            ? "LOUD TEST → \(routeDescription)"
            : "LOUD TEST is NOT routed to Bluetooth • \(routeDescription)"
    }

    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs

        outputVolume = session.outputVolume

        if outputs.isEmpty {
            routeDescription = "No audio output"
            isBluetoothA2DP = false
            return
        }

        isBluetoothA2DP =
            outputs.contains {
                $0.portType == .bluetoothA2DP
            }

        routeDescription =
            outputs
            .map { output in
                let friendlyType: String

                switch output.portType {
                case .bluetoothA2DP:
                    friendlyType = "Bluetooth A2DP"

                case .builtInSpeaker:
                    friendlyType = "iPhone Speaker"

                case .builtInReceiver:
                    friendlyType = "iPhone Receiver"

                case .headphones:
                    friendlyType = "Headphones"

                case .airPlay:
                    friendlyType = "AirPlay"

                default:
                    friendlyType = output.portType.rawValue
                }

                return "\(output.portName) • \(friendlyType)"
            }
            .joined(separator: ", ")
    }

    private func activatePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()

            // For the playback category iOS automatically supports A2DP.
            // Do not force the built-in speaker here.
            try session.setCategory(
                .playback,
                mode: .default,
                options: []
            )

            try session.setActive(true)

            refreshRoute()
        } catch {
            isRunning = false
            status =
                "Audio session error: \(error.localizedDescription)"
        }
    }

    private func configureEngineIfNeeded() {
        guard !configured else { return }

        engine.attach(ambientNode)
        engine.attach(effectNode)

        engine.connect(
            ambientNode,
            to: engine.mainMixerNode,
            format: format
        )

        engine.connect(
            effectNode,
            to: engine.mainMixerNode,
            format: format
        )

        // Keep the ambient bed almost inaudible, but nonzero so the playback
        // session remains actively producing audio while the screen is locked.
        ambientNode.volume = 0.22
        effectNode.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0

        configured = true
    }

    private func restartEngineIfNeeded() {
        guard configured else { return }

        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }

            if !ambientNode.isPlaying {
                let buffer = makeAmbientBuffer()

                ambientNode.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: .loops,
                    completionHandler: nil
                )

                ambientNode.play()
            }

            if !effectNode.isPlaying {
                effectNode.play()
            }

            isRunning = engine.isRunning
        } catch {
            isRunning = false
            status =
                "Audio engine error: \(error.localizedDescription)"
        }
    }

    private func makeAmbientBuffer() -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let seconds = 4.0
        let frameCount =
            AVAudioFrameCount(sampleRate * seconds)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!

        buffer.frameLength = frameCount

        guard let channel = buffer.floatChannelData?[0] else {
            return buffer
        }

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate

            let slowPulse =
                0.55 +
                0.45 *
                sin(2.0 * .pi * 0.45 * time)

            let base =
                sin(2.0 * .pi * 105.0 * time)

            let harmonic =
                0.26 *
                sin(2.0 * .pi * 210.0 * time)

            channel[frame] =
                Float(
                    0.030 *
                    slowPulse *
                    (base + harmonic)
                )
        }

        return buffer
    }

    private func makeTestToneBuffer(
        frequency: Double,
        duration: Double,
        level: Double
    ) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount =
            AVAudioFrameCount(sampleRate * duration)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!

        buffer.frameLength = frameCount

        guard let channel = buffer.floatChannelData?[0] else {
            return buffer
        }

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let progress = time / duration

            let envelope =
                min(
                    min(progress / 0.04, (1.0 - progress) / 0.08),
                    1.0
                )

            channel[frame] =
                Float(
                    max(0, envelope) *
                    level *
                    sin(2.0 * .pi * frequency * time)
                )
        }

        return buffer
    }

    private func makeChirpBuffer(
        intensity: Double
    ) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let seconds = Double.random(in: 0.48...0.78)
        let frameCount =
            AVAudioFrameCount(sampleRate * seconds)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!

        buffer.frameLength = frameCount

        guard let channel = buffer.floatChannelData?[0] else {
            return buffer
        }

        let startFrequency =
            Double.random(in: 520...760)

        let endFrequency =
            Double.random(in: 980...1_520)

        let wobbleRate =
            Double.random(in: 7...14)

        let reverseSweep = Bool.random()

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let progress = time / seconds

            let sweepProgress =
                reverseSweep
                ? (1.0 - progress)
                : progress

            let frequency =
                startFrequency +
                (endFrequency - startFrequency) *
                sweepProgress +
                70.0 *
                sin(
                    2.0 *
                    .pi *
                    wobbleRate *
                    time
                )

            let attack =
                min(1.0, progress / 0.05)

            let release =
                min(
                    1.0,
                    (1.0 - progress) / 0.10
                )

            let envelope =
                max(
                    0.0,
                    min(attack, release)
                )

            let main =
                sin(
                    2.0 *
                    .pi *
                    frequency *
                    time
                )

            let second =
                0.30 *
                sin(
                    2.0 *
                    .pi *
                    (frequency * 1.98) *
                    time
                )

            channel[frame] =
                Float(
                    0.55 *
                    intensity *
                    envelope *
                    (main + second)
                )
        }

        return buffer
    }
}
