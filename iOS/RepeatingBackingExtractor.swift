import Accelerate
import AVFoundation
import Foundation

/// Conservative repeating-background separation for files without enough stereo
/// separation. Each estimate uses several *different* nearby moments. Reuse the
/// mixture phase for overlap-add reconstruction. Only one bounded block is held.
enum RepeatingBackingExtractor {
    enum Failure: LocalizedError {
        case unsupported, noPattern, tooLarge, destination
        var errorDescription: String? {
            switch self {
            case .unsupported: return "这个文件的采样格式暂不支持制作伴奏。"
            case .noPattern: return "没有找到足够清晰的重复伴奏，可继续使用原曲。"
            case .tooLarge: return "生成的伴奏超过 100 MB，请使用较短的音频。"
            case .destination: return "无法创建新的伴奏文件。"
            }
        }
    }

    static func process(input: URL, output: URL, progress: (Double) -> Void,
                        isCancelled: () -> Bool) throws {
        guard input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else { throw Failure.destination }
        let file = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard (8_000...192_000).contains(rate), (1...8).contains(format.channelCount) else { throw Failure.unsupported }
        guard Double(file.length) / rate >= 2.4 else { throw Failure.noPattern }
        guard Double(file.length) / rate * 12_000 < Double(100 * 1024 * 1024) else { throw Failure.tooLarge }
        guard !isCancelled() else { throw CancellationError() }

        let transform = try BackgroundSpectrum(rate: rate)
        let hop = transform.size / 2
        let total = Int(file.length)
        let stride = max(4, Int(6 * rate) / hop)
        let halo = max(8, Int(4 * rate) / hop)
        // AVAudioFile bridges the processing format to the AAC encoder. Use the
        // file's actual sample clock for synthesis; convert to a legal AAC rate
        // through AVAudioConverter for unusual source rates when needed.
        let encodingRate: Double = rate == 48000 ? 48000 : 44100
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: encodingRate,
                                        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { throw Failure.unsupported }
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: output) } }
        // Use direct AAC writing whenever clocks match. For uncommon high or
        // fractional rates, resample each block with a single continuous converter.
        var writer: AVAudioFile? = try AVAudioFile(forWriting: output, settings: settings,
                                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        let target = writer!.processingFormat
        let converter = rate == encodingRate ? nil : AVAudioConverter(from: mono, to: target)
        if rate != encodingRate && converter == nil { throw Failure.unsupported }
        var inputEnergy = 0.0, outputEnergy = 0.0, crossEnergy = 0.0
        var previousTail = [Float]()
        let count = (total + hop - 1) / hop
        for first in Swift.stride(from: 0, to: count, by: stride) {
            if isCancelled() { throw CancellationError() }
            let end = min(count, first + stride)
            let left = max(-1, first - halo)
            let right = min(count, end + halo)
            let readAt = max(0, left * hop)
            let readEnd = min(total, right * hop + transform.size)
            let capacity = AVAudioFrameCount(readEnd - readAt)
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.unsupported }
            file.framePosition = AVAudioFramePosition(readAt)
            try file.read(into: block, frameCount: capacity)
            guard let planes = block.floatChannelData, block.frameLength == capacity else { throw Failure.unsupported }
            var inputFrames = [Float](repeating: 0, count: Int(capacity))
            for channel in 0..<Int(format.channelCount) {
                let plane = planes[channel]
                for i in inputFrames.indices { inputFrames[i] += plane[i] / Float(format.channelCount) }
            }
            let size = min(total, end * hop) - first * hop
            let renderEnd = min(count, end + 1)
            let renderSize = min(total, renderEnd * hop) - first * hop
            let rendered = try transform.extract(samples: inputFrames, origin: readAt, first: first, end: renderEnd,
                                                  left: left, right: right, length: renderSize, isCancelled: isCancelled)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(size)),
                  let samples = buffer.floatChannelData?[0] else { throw Failure.unsupported }
            buffer.frameLength = AVAudioFrameCount(size)
            for i in 0..<size {
                let original = Double(inputFrames[first * hop - readAt + i])
                var result = Double(rendered[i])
                if i < previousTail.count {
                    let blend = Double(i + 1) / Double(previousTail.count)
                    result = Double(previousTail[i]) * (1 - blend) + result * blend
                }
                inputEnergy += original * original
                outputEnergy += result * result
                crossEnergy += original * result
                samples[i] = Float(max(-0.99, min(0.99, result)))
            }
            previousTail = Array(rendered.dropFirst(size))
            if let converter {
                try writeConverted(buffer, using: converter, to: writer!, isFinal: end == count)
            } else {
                try writer!.write(from: buffer)
            }
            progress(min(0.98, Double(end) / Double(count)))
        }
        writer = nil
        guard !isCancelled() else { throw CancellationError() }
        guard inputEnergy > Double(total) * 1e-8, outputEnergy > inputEnergy * 0.015,
              outputEnergy - crossEnergy * crossEnergy / inputEnergy > inputEnergy * 0.003 else {
            throw Failure.noPattern
        }
        let check = try AVAudioFile(forReading: output)
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes <= 100 * 1024 * 1024 else { throw Failure.tooLarge }
        guard bytes > 0, abs(Double(check.length) / check.processingFormat.sampleRate - Double(total) / rate) < 0.18 else {
            throw Failure.unsupported
        }
        keep = true
        progress(1)
    }

    private static func writeConverted(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                       to file: AVAudioFile, isFinal: Bool) throws {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let count = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 512
        guard let target = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: count) else { throw Failure.unsupported }
        var supplied = false
        while true {
            var error: NSError?
            let status = converter.convert(to: target, error: &error) { _, state in
                if supplied {
                    state.pointee = isFinal ? .endOfStream : .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if target.frameLength > 0 { try file.write(from: target) }
            if status == .error { throw Failure.unsupported }
            if status != .haveData || target.frameLength == 0 { break }
        }
    }
}

private final class BackgroundSpectrum {
    let size: Int
    private let setup: FFTSetup
    private let power: vDSP_Length
    private let window: [Float]
    private let bands: [Int]
    private let exclusion: Int
    private let bandCount = 24
    private var real: [Float]
    private var imag: [Float]

    init(rate: Double) throws {
        let logSize = Int(round(log2(rate * 0.046)))
        size = 1 << max(9, min(13, logSize))
        power = vDSP_Length(max(9, min(13, logSize)))
        guard let fft = vDSP_create_fftsetup(power, FFTRadix(kFFTRadix2)) else { throw RepeatingBackingExtractor.Failure.unsupported }
        setup = fft
        let n = size
        window = (0..<n).map { Float(sin(.pi * (Double($0) + 0.5) / Double(n))) }
        bands = (0...n / 2).map { bin in
            let hz = Double(bin) * rate / Double(n)
            return (55...7000).contains(hz) ? min(23, Int(log2(hz / 55) * 3.4)) : -1
        }
        exclusion = max(4, Int(0.50 * rate / Double(n / 2)))
        real = Array(repeating: 0, count: n)
        imag = real
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    private func fft(_ direction: FFTDirection) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, power, direction)
            }
        }
    }

    private func analyze(_ samples: [Float], offset: Int) {
        for i in 0..<size {
            let frame = offset + i
            real[i] = samples.indices.contains(frame) ? samples[frame] * window[i] : 0
            imag[i] = 0
        }
        fft(FFTDirection(FFT_FORWARD))
    }

    func extract(samples: [Float], origin: Int, first: Int, end: Int, left: Int, right: Int,
                 length: Int, isCancelled: () -> Bool) throws -> [Float] {
        let hop = size / 2, bins = hop + 1
        let rows = right - left
        var magnitudes = [Float](repeating: 0, count: rows * bins)
        var features = [Float](repeating: 0, count: rows * bandCount)
        for row in 0..<rows {
            if row.isMultiple(of: 16) && isCancelled() { throw CancellationError() }
            analyze(samples, offset: (left + row) * hop - origin)
            for bin in 0..<bins {
                let magnitude = sqrt(real[bin] * real[bin] + imag[bin] * imag[bin])
                magnitudes[row * bins + bin] = magnitude
                if bands[bin] >= 0 { features[row * bandCount + bands[bin]] += magnitude }
            }
            let start = row * bandCount
            var norm: Float = 0
            for j in start..<(start + bandCount) {
                features[j] = sqrt(features[j]); norm += features[j] * features[j]
            }
            let scale = 1 / max(1e-8, sqrt(norm))
            for j in start..<(start + bandCount) { features[j] *= scale }
        }
        var output = [Float](repeating: 0, count: length)
        for frame in (first - 1)..<end {
            if frame.isMultiple(of: 8) && isCancelled() { throw CancellationError() }
            let row = frame - left
            var options: [(score: Float, row: Int)] = []
            // Pick the most similar frame in each time region, then enforce a
            // separation between all selected neighbors. Adjacent vocal frames
            // cannot vote as independent recurrences of the same background.
            for group in Swift.stride(from: 0, to: rows, by: exclusion) {
                var winner = -1, top: Float = -1
                for candidate in Swift.stride(from: group, to: min(rows, group + exclusion), by: 2) where abs(candidate - row) >= exclusion {
                    var score: Float = 0
                    for j in 0..<bandCount { score += features[candidate * bandCount + j] * features[row * bandCount + j] }
                    if score > top { top = score; winner = candidate }
                }
                if winner >= 0 { options.append((top, winner)) }
            }
            var neighbors = [Int]()
            for entry in options.sorted(by: { $0.score > $1.score }) where entry.score >= 0.60 {
                if neighbors.allSatisfy({ abs($0 - entry.row) >= exclusion }) { neighbors.append(entry.row) }
                if neighbors.count == 5 { break }
            }
            analyze(samples, offset: frame * hop - origin)
            var votes = [Float](repeating: 0, count: 5)
            for bin in 0..<bins {
                var mask: Float = 1
                if neighbors.count >= 3 {
                    for (index, neighbor) in neighbors.enumerated() {
                        let vote = magnitudes[neighbor * bins + bin]
                        var p = index
                        while p > 0 && votes[p - 1] > vote { votes[p] = votes[p - 1]; p -= 1 }
                        votes[p] = vote
                    }
                    let original = magnitudes[row * bins + bin]
                    let background = min(original, votes[neighbors.count / 2])
                    let foreground = max(0, original - background)
                    mask = min(1, max(0.025, background * background / (background * background + 2 * foreground * foreground + 1e-12)))
                }
                real[bin] *= mask; imag[bin] *= mask
                if bin > 0 && bin < hop { real[size - bin] *= mask; imag[size - bin] *= mask }
            }
            fft(FFTDirection(FFT_INVERSE))
            for i in 0..<size {
                let position = (frame - first) * hop + i
                if output.indices.contains(position) { output[position] += real[i] * window[i] / Float(size) }
            }
        }
        return output
    }
}
