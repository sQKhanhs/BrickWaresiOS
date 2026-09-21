import ImageIO
import SwiftUI
import UIKit

/// Image pipeline for catalog art: memory cache + URLCache-backed disk cache + ImageIO downsampling
/// (full Rebrickable renders are 1–5 MB; decoding them at full size for a 90 pt thumbnail would burn
/// memory and scroll performance).
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// URLs that failed this session (404s are common: many sets have no box shot) — skip re-requests.
    private var failed = Set<String>()

    private let session: URLSession = {
        // Ephemeral (no persisted alt-svc → no sticky HTTP/3, see SupabaseProvider.apiSession) but
        // with an explicit disk-backed cache, since images are exactly what we DO want cached.
        let config = URLSessionConfiguration.ephemeral
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("images")
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private init() { cache.totalCostLimit = 96 << 20 }

    func image(_ urlString: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(urlString)#\(Int(maxPixel))"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if failed.contains(urlString) { return nil }
        if let running = inFlight[key] { return await running.value }
        guard let url = URL(string: urlString) else { return nil }

        let session = session
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        } else if !Task.isCancelled {
            failed.insert(urlString)
        }
        return image
    }

    /// Warm the disk cache (theme icons) without decoding.
    func prefetch(_ urls: [URL]) {
        let session = session
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls.prefix(200) { group.addTask { _ = try? await session.data(from: url) } }
            }
        }
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// An image that tries each candidate URL in order until one loads (e.g. render thumb → box shot),
/// showing a neutral placeholder meanwhile and a "No image" tile when every candidate fails.
struct RemoteImage: View {
    let urls: [String]
    var contentMode: ContentMode = .fit
    /// Longest edge in points the image will be shown at (drives downsampling).
    var maxPointSize: CGFloat = 120
    /// Reports whether an image actually loaded (detail heroes gate their gallery tap on it).
    var onLoaded: ((Bool) -> Void)?
    /// Render nothing (instead of the "No image" tile) when every candidate fails — for optional art
    /// such as theme icons that simply haven't been uploaded yet.
    var hidesOnFailure = false

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var didFail = false

    init(
        _ urls: [String?], contentMode: ContentMode = .fit, maxPointSize: CGFloat = 120,
        hidesOnFailure: Bool = false, onLoaded: ((Bool) -> Void)? = nil
    ) {
        self.hidesOnFailure = hidesOnFailure
        self.urls = urls.compactMap { $0?.nilIfBlank }.uniqued(by: \.self)
        self.contentMode = contentMode
        self.maxPointSize = maxPointSize
        self.onLoaded = onLoaded
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if didFail, hidesOnFailure {
                Color.clear
            } else if didFail {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.title3)
                    Text(L("no_image")).font(.caption2)
                }
                .foregroundStyle(Bw.textFaint)
            } else {
                LinearGradient(colors: [Bw.placeholderA, Bw.placeholderB], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .task(id: urls) {
            image = nil
            didFail = urls.isEmpty
            for url in urls {
                if let loaded = await ImageLoader.shared.image(url, maxPixel: maxPointSize * scale) {
                    withAnimation(.easeIn(duration: 0.15)) { image = loaded }
                    onLoaded?(true)
                    return
                }
                if Task.isCancelled { return }
            }
            didFail = true
            onLoaded?(false)
        }
    }
}

/// The square thumbnail used on every set / minifig card.
struct ItemThumb: View {
    let urls: [String?]
    var size: CGFloat = 84

    var body: some View {
        RemoteImage(urls, maxPointSize: size)
            .frame(width: size, height: size)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Bw.borderSoft))
            .accessibilityHidden(true)
    }
}

extension CatalogSet {
    /// List-card candidates: the small render thumb first, then the re-hosted box shot. (Never the
    /// BrickLink box URL for list bursts — it 404s for many sets and rate-limits.)
    var cardImageUrls: [String?] {
        itemType == .minifig ? [imageUrl] : [thumbnailUrl, boxImageUrl, imageUrl]
    }

    /// Gallery candidates: full render first, then the box shot.
    var galleryUrls: [String] {
        [imageUrl, boxImageUrl].compactMap { $0?.nilIfBlank }.uniqued(by: \.self)
    }
}

/// Card/galleries for persisted rows, which store only the thumb (see CatalogImages.renderFromThumb).
enum RowImages {
    static func card(imageUrl: String?, boxImageUrl: String?) -> [String?] {
        [imageUrl.map { CatalogImages.thumbFromRender($0) }, boxImageUrl]
    }

    static func gallery(imageUrl: String?, boxImageUrl: String?) -> [String] {
        [CatalogImages.renderFromThumb(imageUrl), boxImageUrl].compactMap { $0?.nilIfBlank }.uniqued(by: \.self)
    }
}
