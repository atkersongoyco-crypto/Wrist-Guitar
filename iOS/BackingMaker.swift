import AVFoundation
import Foundation

enum BackingMethod: String, Codable {
    case centerReduction
    case repeatingBackground

    var label: String {
        switch self {
        case .centerReduction: return "立体声中置减弱"
        case .repeatingBackground: return "重复伴奏提取"
        }
    }
}

/// A bounded-memory, local effect, not an AI stem separator. The stereo path
/// removes common L/R content; the mono fallback looks for repeating background.
/// Run this synchronous worker away from the UI thread.
enum BackingMaker {
    struct Output {
        let method: BackingMethod
        let duration: TimeInterval
        let byteCount: Int64
    }

    private static let limit: Int64 = 100 * 1024 * 1024

    static func process(input: URL, output: URL,
                        progress: @escaping (Double) -> Void,
                        isCancelled: @escaping () -> Bool) throws -> Output {
        guard input.isFileURL, output.isFileURL,
              input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.message("无法创建伴奏文件，请重试。原曲不会被替换。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        try checkCancellation(isCancelled)
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        guard source.length > 0, format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate) else {
            throw Failure.message("这份文件没有可处理的音频。请继续使用原曲，或换一个文件。")
        }
        guard format.channelCount == 1 || format.channelCount == 2 else {
            throw Failure.message("暂时只支持单声道或双声道音频，请先转换为普通立体声。")
        }
        let duration = Double(source.length) / format.sampleRate
        guard duration * 16_000 + 65_536 < Double(limit) else {
            throw Failure.message("音频太长，生成的伴奏可能超过 100 MB。请先裁剪，再重试。")
        }

        let method: BackingMethod
        if format.channelCount == 1 {
            source.close()
            try RepeatingBackingExtractor.process(input: input, output: output,
                                                  progress: progress, isCancelled: isCancelled)
            method = .repeatingBackground
        } else {
            let metrics = try measure(source, progress: progress, isCancelled: isCancelled)
            guard metrics.originalRMS > 0.000_01 else {
                throw Failure.message("原曲几乎没有声音，无法制作伴奏。原曲已保留。")
            }
            if metrics.sideRMS / metrics.originalRMS < 0.035
                || metrics.processedRMS / metrics.originalRMS < 0.025 {
                source.close()
                try RepeatingBackingExtractor.process(input: input, output: output,
                    progress: { progress(0.4 + 0.6 * $0) }, isCancelled: isCancelled)
                method = .repeatingBackground
            } else {
                let gain = min(2.5, metrics.originalRMS * 0.65 / metrics.processedRMS,
                               0.92 / max(0.000_001, metrics.processedPeak))
                source.framePosition = 0
                try writeCenterReduction(source, output: output, gain: gain,
                                         progress: progress, isCancelled: isCancelled)
                source.close()
                method = .centerReduction
            }
        }
        try checkCancellation(isCancelled)
        let result = try AVAudioFile(forReading: output)
        let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        let seconds = Double(result.length) / result.processingFormat.sampleRate
        guard bytes > 0, bytes <= limit, seconds.isFinite, seconds > 0,
              abs(seconds - duration) < max(0.15, duration * 0.01) else {
            throw Failure.message("生成的伴奏不完整或超过 100 MB。原曲已保留，请重试。")
        }
        result.close()
        try checkCancellation(isCancelled)
        completed = true
        progress(1)
        return Output(method: method, duration: seconds, byteCount: bytes)
    }

    private struct Metrics {
        let originalRMS: Double
        let sideRMS: Double
        let processedRMS: Double
        let processedPeak: Double
    }

    private static func measure(_ source: AVAudioFile, progress: (Double) -> Void,
                                isCancelled: () -> Bool) throws -> Metrics {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8_192) else {
            throw Failure.message("无法读取音频，请换一个文件。")
        }
        var originalSquares = 0.0, sideSquares = 0.0, processedSquares = 0.0, peak = 0.0
        var bass = BassLowPass(sampleRate: source.processingFormat.sampleRate)
        var frames: Int64 = 0
        while source.framePosition < source.length {
            try checkCancellation(isCancelled)
            let count = AVAudioFrameCount(min(8_192, source.length - source.framePosition))
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw Failure.message("原曲读取中断，请重新导入后重试。")
            }
            for frame in 0..<Int(buffer.frameLength) {
                let left = Double(channels[0][frame]), right = Double(channels[1][frame])
                guard left.isFinite, right.isFinite else {
                    throw Failure.message("音频数据异常，无法制作伴奏。")
                }
                let side = (left - right) * 0.5
                let retained = side + 0.45 * bass.process((left + right) * 0.5)
                originalSquares += (left * left + right * right) * 0.5
                sideSquares += side * side
                processedSquares += retained * retained
                peak = max(peak, abs(retained))
            }
            frames += Int64(buffer.frameLength)
            progress(0.4 * Double(source.framePosition) / Double(max(1, source.length)))
        }
        guard frames > 0 else { throw Failure.message("无法读取原曲，请重新导入。") }
        return Metrics(originalRMS: sqrt(originalSquares / Double(frames)),
                       sideRMS: sqrt(sideSquares / Double(frames)),
                       processedRMS: sqrt(processedSquares / Double(frames)), processedPeak: peak)
    }

    private static func writeCenterReduction(_ source: AVAudioFile, output: URL, gain: Double,
                                             progress: (Double) -> Void,
                                             isCancelled: () -> Bool) throws {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let converter = AVAudioConverter(from: source.processingFormat, to: stereo),
              let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8_192),
              let converted = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 8_192),
              let reduced = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8_192) else {
            throw Failure.message("暂时无法处理这个采样格式，请继续使用原曲。")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let writer = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { writer.close() }
        var bass = BassLowPass(sampleRate: 44_100)
        var emptyPasses = 0
        while true {
            try checkCancellation(isCancelled)
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: converted, error: &conversionError) { packets, state in
                if isCancelled() || source.framePosition >= source.length {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    let count = AVAudioFrameCount(min(Int64(max(1, min(packets, 8_192))), source.length - source.framePosition))
                    try source.read(into: input, frameCount: count)
                    state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            try checkCancellation(isCancelled)
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw Failure.message("音频转换失败，请继续使用原曲。") }
            if converted.frameLength > 0 {
                guard let channels = converted.floatChannelData,
                      let target = reduced.floatChannelData?[0] else {
                    throw Failure.message("无法写入伴奏，请重试。")
                }
                reduced.frameLength = converted.frameLength
                for frame in 0..<Int(converted.frameLength) {
                    let left = Double(channels[0][frame]), right = Double(channels[1][frame])
                    let retained = (left - right) * 0.5 + 0.45 * bass.process((left + right) * 0.5)
                    let value = retained * gain
                    target[frame] = Float(min(0.94, max(-0.94, value)))
                }
                try writer.write(from: reduced)
                emptyPasses = 0
            } else { emptyPasses += 1 }
            progress(0.4 + 0.59 * Double(source.framePosition) / Double(max(1, source.length)))
            if status == .endOfStream { break }
            guard emptyPasses < 8 else { throw Failure.message("音频转换没有完成，请重试。") }
        }
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    /// Four-pole 90 Hz Butterworth: retain a restrained layer of centered bass
    /// while rolling off midrange vocal content. State spans every stream block.
    private struct BassLowPass {
        private struct Section {
            let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
            var z1 = 0.0, z2 = 0.0
            init(sampleRate: Double, q: Double) {
                let k = tan(.pi * 90 / sampleRate)
                let norm = 1 / (1 + k / q + k * k)
                b0 = k * k * norm; b1 = 2 * b0; b2 = b0
                a1 = 2 * (k * k - 1) * norm
                a2 = (1 - k / q + k * k) * norm
            }
            mutating func process(_ value: Double) -> Double {
                let output = b0 * value + z1
                z1 = b1 * value - a1 * output + z2
                z2 = b2 * value - a2 * output
                return output
            }
        }
        private var first: Section
        private var second: Section
        init(sampleRate: Double) {
            first = Section(sampleRate: sampleRate, q: 0.541_196_100_1)
            second = Section(sampleRate: sampleRate, q: 1.306_562_964_9)
        }
        mutating func process(_ value: Double) -> Double { second.process(first.process(value)) }
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
