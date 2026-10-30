import Foundation
import AVFoundation
import Combine

@MainActor
final class R2ExternalAudioEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var routeDescription = "No active audio route"
    @Published private(set) var status = "External audio off"
    @Published private(set) var isBluetoothA2DP = false
    @Published private(set) var outputVolume: Float = 0

    @Published private(set) var importedSoundCount = 0
    @Published private(set) var importedSoundNames: [String] = []
    @Published private(set) var lastPackSound = "None"

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

    private var packURLs: [URL] = []
    private var shuffledPackDeck: [URL] = []
    private var lastPackURL: URL?
    private var packPlayer: AVAudioPlayer?

    private var soundPackFolder: URL {
        let base =
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

        return base.appendingPathComponent(
            "R2SoundPack",
            isDirectory: true
        )
    }

    override init() {
        super.init()

        ensureSoundPackFolder()
        reloadSoundPack()

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
                    let rawType =
                        info[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    let type =
                        AVAudioSession.InterruptionType(
                            rawValue: rawType
                        )
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
            forName:
                AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configured = false
                self?.activatePlaybackSession()
                self?.configureEngineIfNeeded()
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

    var hasImportedSoundPack: Bool {
        !packURLs.isEmpty
    }

    func start() {
        activatePlaybackSession()
        configureEngineIfNeeded()
        restartEngineIfNeeded()
        refreshRoute()

        if isRunning {
            if hasImportedSoundPack {
                status =
                    isBluetoothA2DP
                    ? "JBL sound pack ready • \(importedSoundCount) sounds"
                    : "Sound pack ready • output is not Bluetooth A2DP"
            } else {
                status =
                    "No imported sound pack • R2 internal sounds will be used"
            }
        }
    }

    func stop() {
        packPlayer?.stop()
        packPlayer = nil
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

    func importSoundFiles(_ urls: [URL]) {
        ensureSoundPackFolder()

        var imported = 0
        var skipped = 0

        for sourceURL in urls {
            let accessed =
                sourceURL.startAccessingSecurityScopedResource()

            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let ext =
                sourceURL.pathExtension.lowercased()

            let allowed =
                ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf"]

            guard allowed.contains(ext) else {
                skipped += 1
                continue
            }

            let cleanName =
                sourceURL.deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "/", with: "-")

            var destination =
                soundPackFolder.appendingPathComponent(
                    "\(cleanName).\(ext)"
                )

            var suffix = 2

            while FileManager.default.fileExists(
                atPath: destination.path
            ) {
                destination =
                    soundPackFolder.appendingPathComponent(
                        "\(cleanName)-\(suffix).\(ext)"
                    )
                suffix += 1
            }

            do {
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destination
                )

                imported += 1
            } catch {
                skipped += 1
            }
        }

        reloadSoundPack()

        if imported > 0 {
            status =
                "Imported \(imported) R2 sound file\(imported == 1 ? "" : "s")" +
                (skipped > 0 ? " • \(skipped) skipped" : "")
        } else {
            status =
                skipped > 0
                ? "No supported audio files were imported"
                : "No files selected"
        }
    }

    func clearSoundPack() {
        packPlayer?.stop()
        packPlayer = nil

        ensureSoundPackFolder()

        if let files =
            try? FileManager.default.contentsOfDirectory(
                at: soundPackFolder,
                includingPropertiesForKeys: nil
            ) {

            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        reloadSoundPack()
        lastPackSound = "None"
        status = "Imported sound pack cleared"
    }

    @discardableResult
    func playNextPackSound() -> Bool {
        activatePlaybackSession()
        refreshRoute()

        guard !packURLs.isEmpty else {
            status =
                "No imported sound pack • using R2 internal sounds"
            return false
        }

        if shuffledPackDeck.isEmpty {
            var deck = packURLs.shuffled()

            if let lastPackURL,
               deck.count > 1,
               deck.last == lastPackURL {

                deck.swapAt(
                    deck.count - 1,
                    deck.count - 2
                )
            }

            shuffledPackDeck = deck
        }

        guard let url = shuffledPackDeck.popLast() else {
            return false
        }

        do {
            packPlayer?.stop()

            let player =
                try AVAudioPlayer(contentsOf: url)

            player.delegate = self
            player.volume = 1.0
            player.prepareToPlay()

            guard player.play() else {
                status = "Could not play \(url.lastPathComponent)"
                return false
            }

            packPlayer = player
            lastPackURL = url
            lastPackSound =
                url.deletingPathExtension().lastPathComponent

            status =
                isBluetoothA2DP
                ? "JBL PACK • \(lastPackSound)"
                : "PACK PLAYING • \(routeDescription)"

            return true
        } catch {
            status =
                "Pack sound error: \(error.localizedDescription)"
            return false
        }
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

        let first =
            makeTestToneBuffer(
                frequency: 720,
                duration: 0.42,
                level: 0.75
            )

        let second =
            makeTestToneBuffer(
                frequency: 1_080,
                duration: 0.42,
                level: 0.75
            )

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

        if !effectNode.isPlaying {
            effectNode.play()
        }

        status =
            isBluetoothA2DP
            ? "LOUD ROUTE TEST → \(routeDescription)"
            : "TEST NOT ROUTED TO BLUETOOTH • \(routeDescription)"
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

                return
                    "\(output.portName) • \(friendlyType)"
            }
            .joined(separator: ", ")
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        if flag {
            status = "Sound finished • ready"
        }
    }

    private func ensureSoundPackFolder() {
        try? FileManager.default.createDirectory(
            at: soundPackFolder,
            withIntermediateDirectories: true
        )
    }

    private func reloadSoundPack() {
        ensureSoundPackFolder()

        let allowed =
            Set(["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf"])

        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: soundPackFolder,
                includingPropertiesForKeys: nil
            )) ?? []

        packURLs =
            files
            .filter {
                allowed.contains(
                    $0.pathExtension.lowercased()
                )
            }
            .sorted {
                $0.lastPathComponent
                    .localizedCaseInsensitiveCompare(
                        $1.lastPathComponent
                    ) == .orderedAscending
            }

        importedSoundCount = packURLs.count
        importedSoundNames =
            packURLs.map {
                $0.lastPathComponent
            }

        shuffledPackDeck.removeAll()
    }

    private func activatePlaybackSession() {
        do {
            let session =
                AVAudioSession.sharedInstance()

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

        // A nearly inaudible continuous audio bed keeps the playback session
        // active during locked-screen Backpack Mode.
        ambientNode.volume = 0.08
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

        let buffer =
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )!

        buffer.frameLength = frameCount

        guard let channel =
            buffer.floatChannelData?[0] else {
            return buffer
        }

        for frame in 0..<Int(frameCount) {
            let time =
                Double(frame) / sampleRate

            channel[frame] =
                Float(
                    0.010 *
                    sin(2.0 * .pi * 96.0 * time)
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
            AVAudioFrameCount(
                sampleRate * duration
            )

        let buffer =
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )!

        buffer.frameLength = frameCount

        guard let channel =
            buffer.floatChannelData?[0] else {
            return buffer
        }

        for frame in 0..<Int(frameCount) {
            let time =
                Double(frame) / sampleRate

            let progress =
                time / duration

            let envelope =
                min(
                    min(
                        progress / 0.04,
                        (1.0 - progress) / 0.08
                    ),
                    1.0
                )

            channel[frame] =
                Float(
                    max(0, envelope) *
                    level *
                    sin(
                        2.0 *
                        .pi *
                        frequency *
                        time
                    )
                )
        }

        return buffer
    }
}
