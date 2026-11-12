import SwiftUI
import UIKit

/// Persistent (disk + memory) cache for firmware preview thumbnails.
///
/// `AsyncImage` alone only benefits from `URLCache`, whose default
/// capacity is small and isn't guaranteed to survive — this instead
/// writes decoded images straight to a dedicated cache directory keyed by
/// the card's own filename (which already embeds a content hash, e.g.
/// `etch-246c899b.w640.webp`), so a firmware's thumbnail is fetched over
/// the network at most once per device, ever, and reappears instantly on
/// every later scroll or app launch.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("FirmwareThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.lastPathComponent

        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [directory] in
            let fileURL = directory.appendingPathComponent(key)

            if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                return image
            }

            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }
            try? data.write(to: fileURL, options: .atomic)
            return image
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString)
        }
        return image
    }
}

struct CachedThumbnail: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Color.secondary.opacity(0.15)
                    .overlay {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            } else if url != nil {
                Color.secondary.opacity(0.08)
                    .overlay { ProgressView().controlSize(.small) }
            } else {
                Color.secondary.opacity(0.15)
                    .overlay {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            if let loaded = await ThumbnailCache.shared.image(for: url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}
