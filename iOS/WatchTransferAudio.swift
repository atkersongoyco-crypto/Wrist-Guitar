import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Keep the phone library's immutable original. Files already small enough for
/// the watch do not need an encode, and only complete, verified copies enter the cache.
enum WatchTransferAudio {
    static func file(for source: URL, id: UUID, duration: TimeInterval, cacheDirectory: URL,
                     willEncode: @MainActor @Sendable () -> Void = {}) async -> URL {
        let files = FileManager.default
        guard !Task.isCancelled, duration.isFinite, duration > 0,
              let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 1024 * 1024, Double(size) * 8 / duration >= 200_000,
              let original = try? AVAudioFile(forReading: source),
              (1...2).contains(original.processingFormat.channelCount) else { return source }
        let destination = cacheDirectory.appendingPathComponent(id.uuidString + ".m4a")
        // A song ID always identifies one immutable source (including backing versions).
        func usable(_ url: URL) -> Bool {
            guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  bytes > 0, bytes <= size * 4 / 5, let file = try? AVAudioFile(forReading: url),
                  file.processingFormat.channelCount == original.processingFormat.channelCount else { return false }
            let originalSeconds = Double(original.length) / original.processingFormat.sampleRate
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            return seconds > 0 && abs(seconds - originalSeconds) <= 0.12
        }
        if usable(destination) { return destination }
        let temporary = cacheDirectory.appendingPathComponent(".encoding-" + UUID().uuidString + ".m4a")
        defer { try? files.removeItem(at: temporary) }
        do {
            try files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let asset = AVURLAsset(url: source)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return source }
            exporter.metadata = await watchMetadata(for: asset)
            try Task.checkCancellation()
            await willEncode()
            try Task.checkCancellation()
            try await exporter.export(to: temporary, as: .m4a)
            try Task.checkCancellation()
            guard usable(temporary) else { return source }
            if usable(destination) { return destination }
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try files.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch {
            return !Task.isCancelled && usable(destination) ? destination : source
        }
    }

    private static func watchMetadata(for asset: AVURLAsset) async -> [AVMetadataItem] {
        let keys: [AVMetadataKey: AVMetadataIdentifier] = [
            .commonKeyTitle: .iTunesMetadataSongName, .commonKeyArtist: .iTunesMetadataArtist,
            .commonKeyAlbumName: .iTunesMetadataAlbum, .commonKeyCreator: .iTunesMetadataComposer
        ]
        var result: [AVMetadataItem] = []
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            if Task.isCancelled { return [] }
            guard let key = item.commonKey, let id = keys[key],
                  let text = try? await item.load(.stringValue) else { continue }
            let tag = AVMutableMetadataItem()
            tag.identifier = id
            tag.value = text as NSString
            result.append(tag)
        }
        if let cover = await RecordingCoverCache.shared.cover(for: asset.url) {
            let data = NSMutableData()
            if let image = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(image, cover, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                if CGImageDestinationFinalize(image) {
                    let tag = AVMutableMetadataItem()
                    tag.identifier = .iTunesMetadataCoverArt
                    tag.dataType = kCMMetadataBaseDataType_JPEG as String
                    tag.value = data as NSData
                    result.append(tag)
                }
            }
        }
        return result
    }
}
