import AirGuitarCore
import AVFoundation
import Foundation

/// Plays the recording on one node. The authored audio is also the input to the
/// wrist effect, so the two share a clock, a pitch and a single playback position.
@MainActor
final class RecordingPlayer {
    private let stream: RecordingStream
    private var configurationObserver: NSObjectProtocol?
    var didFinish: ((Bool) -> Void)?

    init(url: URL) throws {
        let stream = try RecordingStream(url: url)
        self.stream = stream
        stream.onFinish = { [weak self] generation, success in
            Task { @MainActor in
                guard let self, self.stream.isCurrent(generation) else { return }
                self.didFinish?(success)
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: stream.engine, queue: nil
        ) { [weak stream] _ in stream?.handleConfigurationChange() }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        stream.close()
    }

    var duration: Double { stream.duration }
    var isPlaying: Bool { stream.queue.sync { stream.playing } }
    var hasSignal: Bool { stream.queue.sync { stream.playing && stream.audible } }
    var currentTime: Double {
        get { stream.queue.sync { Double(stream.position()) / stream.rate } }
        set { stream.queue.sync { stream.seek(to: newValue) } }
    }
    var volume: Float {
        get { stream.queue.sync { stream.player.volume } }
        set {
            stream.queue.sync {
                stream.player.volume = newValue.isFinite ? min(1, max(0, newValue)) : 0
            }
        }
    }

    func play() throws { try stream.queue.sync { try stream.start() } }
    func pause() { stream.queue.sync { stream.stop(at: stream.position()) } }
    func clearStroke() { stream.queue.sync { stream.effect.reset() } }
    func continueMotion() {
        stream.queue.async { [stream] in
            guard stream.playing, stream.player.volume > 0 else { return }
            stream.effect.continueMotion()
        }
    }
    func stroke(strength: Double, amount: Double, speaker: Bool) {
        stream.queue.sync {
            guard stream.playing, stream.player.volume > 0 else { return }
            stream.effect.trigger(strength: strength, amount: amount, speaker: speaker)
        }
    }
}

private final class RecordingStream: @unchecked Sendable {
    let queue = DispatchQueue(label: "WristGuitar.RecordingPlayback", qos: .userInitiated)
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let rate: Double
    let duration: Double
    var effect: RecordingStroke
    var onFinish: ((UInt64, Bool) -> Void)?

    private let file: AVAudioFile
    private var buffers = [AVAudioPCMBuffer]()
    private var generation: UInt64 = 0
    private var origin: AVAudioFramePosition = 0
    private var playedThrough: AVAudioFramePosition = 0
    private(set) var playing = false
    private(set) var audible = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        rate = format.sampleRate
        guard file.length > 0, rate.isFinite, rate > 0, format.channelCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        duration = Double(file.length) / rate
        effect = RecordingStroke(sampleRate: rate, channels: Int(format.channelCount))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = 0.25
    }

    private func prepareBuffers() throws {
        let ioDuration: Double
        if engine.isInManualRenderingMode {
            ioDuration = Double(engine.manualRenderingMaximumFrameCount) / engine.manualRenderingFormat.sampleRate
        } else {
#if os(watchOS)
            ioDuration = AVAudioSession.sharedInstance().ioBufferDuration
#else
            ioDuration = 0.012
#endif
        }
        // Reserve two output periods and a short allowance for a late file
        // decode/refill. Small routes get additional short blocks; routes
        // that already buffer at least three long periods keep that latency.
        let period = ioDuration.isFinite ? max(0.001, min(0.5, ioDuration)) : 0.012
        let minimumBlock = max(0.012, period)
        let horizon = max(3 * minimumBlock, 2 * minimumBlock + 0.046)
        let blockCount = min(5, max(3, Int((horizon / minimumBlock).rounded())))
        let secondsPerBlock = max(period, horizon / Double(blockCount))
        let capacity = AVAudioFrameCount(ceil(rate * secondsPerBlock))
        guard buffers.count != blockCount || buffers.first?.frameCapacity != capacity else { return }
        let format = file.processingFormat
        buffers = try (0..<blockCount).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return buffer
        }
    }

    func isCurrent(_ value: UInt64) -> Bool { queue.sync { generation == value } }

    func position() -> AVAudioFramePosition {
        guard playing else { return origin }
        if let render = player.lastRenderTime, let clock = player.playerTime(forNodeTime: render),
           clock.isSampleTimeValid, clock.sampleRate > 0 {
            let offset = Double(clock.sampleTime) * rate / clock.sampleRate
            return min(file.length, max(origin, origin + AVAudioFramePosition(max(0, offset))))
        }
        return playedThrough
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        let frame = AVAudioFramePosition((min(duration, max(0, time)) * rate).rounded())
        let resume = playing && frame < file.length
        stop(at: frame)
        if resume {
            do { try start() }
            catch { onFinish?(generation, false) }
        }
    }

    func stop(at frame: AVAudioFramePosition) {
        generation &+= 1
        playing = false
        audible = false
        origin = min(file.length, max(0, frame))
        playedThrough = origin
        effect.reset()
        player.stop()
        engine.pause()
    }

    func start() throws {
        guard !playing else { return }
        if origin >= file.length { origin = 0 }
        generation &+= 1
        let id = generation
        playedThrough = origin
        file.framePosition = origin
        effect.reset()
        playing = true
        do {
            try prepareBuffers()
            for buffer in buffers where file.framePosition < file.length {
                try enqueue(buffer, id: id)
            }
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            stop(at: origin)
            throw error
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, id: UInt64) throws {
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { return }
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity)))
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frames = Int(buffer.frameLength)
        let end = file.framePosition
        var signal = false
        for c in 0..<Int(buffer.format.channelCount) {
            if stride(from: 0, to: frames, by: 4).contains(where: { abs(data[c][$0]) > 0.004 }) {
                signal = true
                break
            }
        }
        let blockHasSignal = signal
        effect.process(data, frames: frames)
        let last = end >= file.length || buffer.frameLength < count
        player.scheduleBuffer(buffer, completionCallbackType: last ? .dataPlayedBack : .dataRendered) {
            [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.playing, self.generation == id, self.engine.isRunning else { return }
                self.playedThrough = max(self.playedThrough, end)
                self.audible = blockHasSignal
                if last {
                    self.stop(at: self.file.length)
                    self.onFinish?(self.generation, true)
                } else {
                    do { try self.enqueue(buffer, id: id) }
                    catch {
                        self.stop(at: self.position())
                        self.onFinish?(self.generation, false)
                    }
                }
            }
        }
    }

    func handleConfigurationChange() {
        // Give the session interruption/route observers time to pause explicitly.
        queue.async { [weak self] in
            guard let self, self.playing, !self.engine.isRunning || !self.player.isPlaying else { return }
            let id = self.generation
            self.queue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                guard let self, self.generation == id, self.playing else { return }
                self.stop(at: self.playedThrough)
                do { try self.start() }
                catch { self.onFinish?(self.generation, false) }
            }
        }
    }

    func close() {
        queue.sync {
            onFinish = nil
            stop(at: 0)
            engine.stop()
        }
    }
}
