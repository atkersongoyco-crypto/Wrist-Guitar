import AirGuitarCore
import AVFoundation
import Darwin
import Foundation

@MainActor
final class PerformanceAudio {
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var buffers: [Chord: AVAudioPCMBuffer] = [:]
    private var nextVoice = 0
    private var backing: AVAudioPlayer?
    private var loadedSongID: UUID?
    private var prepared = false
    private let cueNode = AVAudioPlayerNode()
    private var cueBuffers: [RhythmCue: AVAudioPCMBuffer] = [:]
    private let assistedLeadNode = AVAudioPlayerNode()
    private let assistedTailNode = AVAudioPlayerNode()
    private var assistedBuffers: [AssistedVoice: AVAudioPCMBuffer] = [:]
    private var assistance = AssistedPerformance()
    private var assistedMode = false
    var guitarVolume: Float = 0.65
    var backingVolume: Float = 0.5 { didSet { backing?.volume = boundedBackingVolume * 0.5 } }

    private var boundedGuitarVolume: Float { guitarVolume.isFinite ? min(1, max(0, guitarVolume)) : 0 }
    private var boundedBackingVolume: Float { backingVolume.isFinite ? min(1, max(0, backingVolume)) : 0 }

    var currentTime: Double { backing?.currentTime ?? 0 }
    var duration: Double { backing?.duration ?? 0 }
    var backingIsPlaying: Bool { backing?.isPlaying ?? false }
    func backingHasSignal() -> Bool {
        guard let backing, backing.isPlaying else { return false }
        backing.updateMeters()
        return (0..<backing.numberOfChannels).contains { backing.peakPower(forChannel: $0) > -48 }
    }
    var routeName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: " · ")
    }

    func prepare(song: WatchSong?) throws {
        if !prepared {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
                else { throw PlaybackError.engine }
            // Wrist control remains C/Am/F/G. Do not allocate 24 long tails
            // when imported harmony uses the much smaller assisted bank.
            for chord in Chord.manualVoicings {
                let samples = PluckedStringRenderer.render(chord: chord)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { throw PlaybackError.engine }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress { channel.update(from: base, count: samples.count) }
                }
                buffers[chord] = buffer
            }
            for voice in AssistedVoice.allVoices {
                let samples = AssistedSoundRenderer.render(voice: voice)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { throw PlaybackError.engine }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress { channel.update(from: base, count: samples.count) }
                }
                assistedBuffers[voice] = buffer
            }
            // Fixed voice pool permits overlapping chord tails without unbounded allocations.
            for _ in 0..<6 {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                nodes.append(node)
            }
            engine.attach(cueNode)
            engine.connect(cueNode, to: engine.mainMixerNode, format: format)
            engine.attach(assistedLeadNode)
            engine.connect(assistedLeadNode, to: engine.mainMixerNode, format: format)
            engine.attach(assistedTailNode)
            engine.connect(assistedTailNode, to: engine.mainMixerNode, format: format)
            for cue in RhythmCue.allCases {
                let count = AVAudioFrameCount(format.sampleRate * cue.duration)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                      let channel = buffer.floatChannelData?[0] else { throw PlaybackError.engine }
                buffer.frameLength = count
                for i in 0..<Int(count) {
                    let t = Double(i) / format.sampleRate
                    let envelope = min(1, t / 0.004) * pow(1 - t / cue.duration, 3)
                    channel[i] = Float(0.48 * envelope * sin(2 * .pi * cue.frequency * t))
                }
                cueBuffers[cue] = buffer
            }
            // Manual mode has six overlapping voices. Assisted mode switches to
            // one lead + one reply, so it can be clearer at a .26 mixer level.
            engine.mainMixerNode.outputVolume = 0.1
            engine.prepare()
            prepared = true
        }
        if loadedSongID != song?.id {
            resetAssistance()
            backing?.stop()
            backing = try song.map { try AVAudioPlayer(contentsOf: $0.url) }
            backing?.volume = boundedBackingVolume * 0.5
            backing?.isMeteringEnabled = true
            backing?.prepareToPlay()
            loadedSongID = song?.id
        }
    }

    func activate(mixWithOtherMusic: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        // For external accompaniment the existing player owns the music route.
        // Only our instrument and cues should be added to it.
        if mixWithOtherMusic {
            try session.setCategory(.playback, mode: .default, policy: .default, options: [.mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PlaybackError.route) }
            }
        }
    }

    func startInstruments() throws {
        if !engine.isRunning { try engine.start() }
    }

    func cue(_ cue: RhythmCue) {
        guard engine.isRunning, let buffer = cueBuffers[cue] else { return }
        cueNode.stop()
        cueNode.scheduleBuffer(buffer)
        cueNode.play()
    }

    func play(includingBacking: Bool) throws {
        try startInstruments()
        try setBackingPlaying(includingBacking)
    }

    func setBackingPlaying(_ enabled: Bool) throws {
        guard let backing else { return }
        if !enabled { backing.pause(); return }
        if backing.currentTime >= backing.duration - 0.05 { backing.currentTime = 0 }
        guard backing.play() else { throw PlaybackError.file }
    }

    func strum(_ event: StrumEvent) {
        guard engine.isRunning, let buffer = buffers[event.chord], !nodes.isEmpty else { return }
        setInstrumentMode(assisted: false)
        let node = nodes[nextVoice]
        nextVoice = (nextVoice + 1) % nodes.count
        node.stop()
        // The motion interpreter's accepted strokes start around .45. Spread
        // that playable range across the available dynamics at the instrument.
        let touch = min(1, max(0, (event.velocity - 0.45) / 0.55))
        node.volume = boundedGuitarVolume * Float(0.26 + 0.74 * sqrt(touch))
        node.scheduleBuffer(buffer, at: nil, options: [])
        node.play()
    }

    /// No PCM is generated here. The first sweep sounds immediately, and one
    /// replaceable reply is scheduled against the audio host clock. `beat` must
    /// already be anchored to monotonic uptime, including for local-file music.
    @discardableResult
    func assistedStrum(_ event: StrumEvent, source: AssistedSource,
                       beat: BeatEstimate? = nil) -> AssistedPhrase? {
        guard engine.isRunning, !nodes.isEmpty else { return nil }
        setInstrumentMode(assisted: true)
        let phrase = assistance.phrase(at: ProcessInfo.processInfo.systemUptime,
                                       velocity: event.velocity, source: source, beat: beat)
        // stop() discards an old scheduled reply, including one not yet audible.
        assistedTailNode.stop()
        guard let first = phrase.hits.first, let firstBuffer = assistedBuffers[first.voice] else { return nil }
        assistedLeadNode.stop()
        assistedLeadNode.volume = boundedGuitarVolume * Float(first.gain)
        assistedLeadNode.scheduleBuffer(firstBuffer)
        assistedLeadNode.play()

        if phrase.hits.count > 1 {
            let reply = phrase.hits[1]
            if let replyBuffer = assistedBuffers[reply.voice] {
                let delay = max(0, phrase.timestamp + reply.offset - ProcessInfo.processInfo.systemUptime)
                let hostSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time()) + delay
                let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostSeconds))
                assistedTailNode.volume = boundedGuitarVolume * Float(reply.gain)
                assistedTailNode.scheduleBuffer(replyBuffer)
                assistedTailNode.play(at: when)
            }
        }
        return phrase
    }

    func resetAssistance() {
        assistance.reset()
        if prepared {
            assistedLeadNode.stop()
            assistedTailNode.stop()
        }
    }

    func setInstrumentMode(assisted: Bool) {
        guard assistedMode != assisted else { return }
        nodes.forEach { $0.stop() }
        assistedLeadNode.stop()
        assistedTailNode.stop()
        cueNode.stop()
        assistedMode = assisted
        // With all controls at maximum: .7*.26 + .7*.38*.26 +
        // .48*.26 + 1*.5 = .876, conservatively below full-scale.
        engine.mainMixerNode.outputVolume = assisted ? 0.26 : 0.1
    }

    func pause() {
        backing?.pause()
        nodes.forEach { $0.stop() }
        if prepared {
            cueNode.stop()
            assistedLeadNode.stop()
            assistedTailNode.stop()
            assistedMode = false
            engine.mainMixerNode.outputVolume = 0.1
        }
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func rewind() {
        backing?.currentTime = 0
        resetAssistance()
    }

    private enum PlaybackError: LocalizedError {
        case route, engine, file
        var errorDescription: String? {
            switch self {
            case .route: return "没有可用的音频输出。S10 请离开充电器，或连接耳机后重试。"
            case .engine: return "音色准备失败，请重新打开应用。"
            case .file: return "歌曲无法播放，请重新传输。"
            }
        }
    }
}

enum RhythmCue: CaseIterable {
    case count, go, streak
    var frequency: Double {
        switch self { case .count: return 660; case .go: return 990; case .streak: return 1320 }
    }
    var duration: Double { self == .count ? 0.065 : 0.115 }
}
