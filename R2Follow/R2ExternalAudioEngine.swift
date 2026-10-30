import Foundation
import AVFoundation
import Combine

@MainActor
final class R2ExternalAudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var routeDescription = "iPhone audio"
    @Published private(set) var status = "External audio off"

    private let engine = AVAudioEngine()
    private let ambientNode = AVAudioPlayerNode()
    private let effectNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!

    private var configured = false
    private var routeObserver: NSObjectProtocol?

    init() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRoute()
            }
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playback,
                mode: .default,
                options: [
                    .allowBluetoothA2DP,
                    .mixWithOthers
                ]
            )

            try session.setActive(true)

            if !configured {
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

                ambientNode.volume = 0.12
                effectNode.volume = 0.80
                configured = true
            }

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

            isRunning = true
            status = "External/background R2 audio active"
            refreshRoute()
        } catch {
            isRunning = false
            status = "Audio error: \(error.localizedDescription)"
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

    func playDroidChirp(intensity: Double = 0.55) {
        guard isRunning else { return }

        let buffer = makeChirpBuffer(
            intensity: max(0.15, min(1.0, intensity))
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
    }

    func refreshRoute() {
        let outputs =
            AVAudioSession.sharedInstance()
            .currentRoute
            .outputs

        if outputs.isEmpty {
            routeDescription = "No audio output"
            return
        }

        routeDescription =
            outputs
            .map { output in
                let type = output.portType.rawValue
                return "\(output.portName) • \(type)"
            }
            .joined(separator: ", ")
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
                sin(2.0 * .pi * 92.0 * time)

            let harmonic =
                0.30 *
                sin(2.0 * .pi * 184.0 * time)

            let shimmer =
                0.10 *
                sin(2.0 * .pi * 368.0 * time)

            channel[frame] =
                Float(
                    0.018 *
                    slowPulse *
                    (base + harmonic + shimmer)
                )
        }

        return buffer
    }

    private func makeChirpBuffer(
        intensity: Double
    ) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let seconds = Double.random(in: 0.42...0.78)
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
            Double.random(in: 480...760)

        let endFrequency =
            Double.random(in: 920...1_520)

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
                65.0 *
                sin(
                    2.0 *
                    .pi *
                    wobbleRate *
                    time
                )

            let attack =
                min(1.0, progress / 0.08)

            let release =
                min(
                    1.0,
                    (1.0 - progress) / 0.14
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
                0.28 *
                sin(
                    2.0 *
                    .pi *
                    (frequency * 1.98) *
                    time
                )

            channel[frame] =
                Float(
                    0.20 *
                    intensity *
                    envelope *
                    (main + second)
                )
        }

        return buffer
    }
}
