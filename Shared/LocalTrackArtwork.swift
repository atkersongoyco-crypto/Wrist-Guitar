import AVFoundation
import ImageIO
import SwiftUI

/// Shows artwork embedded in a local recording while keeping the layout stable as it loads.
struct LocalTrackArtwork<Fallback: View>: View {
    let fileURL: URL?
    @ViewBuilder let fallback: () -> Fallback
    @State private var loadedURL: URL?
    @State private var cover: CGImage?

    var body: some View {
        Group {
            if loadedURL == fileURL, let cover {
                Image(decorative: cover, scale: 1).resizable().scaledToFill()
            } else {
                fallback()
            }
        }
        .task(id: fileURL) {
            guard let fileURL, !Task.isCancelled else { return }
            let image = await RecordingCoverCache.shared.cover(for: fileURL)
            guard !Task.isCancelled else { return }
            cover = image
            loadedURL = fileURL
        }
    }
}

actor RecordingCoverCache {
    static let shared = RecordingCoverCache()

    private final class Entry {
        let stamp: Date?
        let size: Int?
        let cover: CGImage?

        init(stamp: Date?, size: Int?, cover: CGImage?) {
            self.stamp = stamp
            self.size = size
            self.cover = cover
        }
    }

    private let entries = NSCache<NSURL, Entry>()
    #if os(watchOS)
    private let maxDimension = 448
    #else
    private let maxDimension = 840
    #endif

    private init() {
        entries.countLimit = 80
        entries.totalCostLimit = maxDimension * maxDimension * 4 * 8
    }

    func cover(for url: URL) async -> CGImage? {
        guard url.isFileURL, !Task.isCancelled,
              let file = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        let key = url as NSURL
        if let prior = entries.object(forKey: key), prior.stamp == file.contentModificationDate,
           prior.size == file.fileSize {
            return prior.cover
        }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata), !Task.isCancelled else { return nil }
        let images = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        var cover: CGImage?
        for item in images {
            guard !Task.isCancelled else { return nil }
            guard let data = try? await item.load(.dataValue), data.count <= 16 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                cover = thumbnail
                break
            }
        }
        guard !Task.isCancelled else { return nil }
        let entry = Entry(stamp: file.contentModificationDate, size: file.fileSize, cover: cover)
        entries.setObject(entry, forKey: key, cost: cover.map { $0.bytesPerRow * $0.height } ?? 0)
        return cover
    }
}
