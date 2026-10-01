import ImageIO
import SwiftUI
import UIKit

/// Image pipeline for catalog art: memory cache + URLCache-backed disk cache + ImageIO downsampling
/// (full Rebrickable renders are 1–5 MB; decoding them at full size for a 90 pt thumbnail would burn
/// memory and scroll performance).
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    /// URLs the server said aren't there (404s are common: many sets have no box shot) — skip re-requests
    /// for the session. ONLY a definitive answer lands here: remembering a network error or a timeout
    /// blanked every image that failed during one offline moment until the app was relaunched.
    private var missing = Set<String>()
    /// A busy-server answer (429 / 5xx): don't hammer it, but do ask again after a cooldown.
    private var retryAfter: [String: Date] = [:]
    private static let busyCooldown: TimeInterval = 60

    private enum Outcome: Sendable {
        case image(UIImage)
        /// Definitively absent — remembered.
        case missing
        /// Rate-limited / server error — retried after `busyCooldown`.
        case busy
        /// Offline, timed out, cancelled — never remembered, so a reconnect can retry at once.
        case unreachable
    }

    /// A client error says the image isn't there (404, 403, 410…); 408 and 429 are "try again later".
    static func isDefinitivelyMissing(status: Int) -> Bool {
        (400..<500).contains(status) && status != 408 && status != 429
    }

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
        if missing.contains(urlString) { return nil }
        if let until = retryAfter[urlString] {
            if until > Date() { return nil }
            retryAfter[urlString] = nil
        }
        if let running = inFlight[key] { return await Self.image(of: running.value) }
        guard let url = URL(string: urlString) else { return nil }

        let session = session
        let task = Task<Outcome, Never>.detached(priority: .userInitiated) {
            do {
                let (data, response) = try await session.data(from: url)
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    return Self.isDefinitivelyMissing(status: status) ? .missing : .busy
                }
                // A body that isn't an image (an error page served with 200) won't decode next time either.
                return Self.downsample(data, maxPixel: maxPixel).map(Outcome.image) ?? .missing
            } catch {
                return .unreachable
            }
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        switch outcome {
        case .image(let image):
            cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        case .missing:
            missing.insert(urlString)
        case .busy:
            retryAfter[urlString] = Date().addingTimeInterval(Self.busyCooldown)
        case .unreachable:
            break
        }
        return Self.image(of: outcome)
    }

    private static func image(of outcome: Outcome) -> UIImage? {
        if case .image(let image) = outcome { return image }
        return nil
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
    /// Bumped to re-run the load when connectivity returns after a failure.
    @State private var retry = 0
    /// The URLs the current `image` / `didFail` state belongs to.
    @State private var shownFor: [String]?

    private struct LoadKey: Hashable {
        var urls: [String]
        var retry: Int
    }

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
        .task(id: LoadKey(urls: urls, retry: retry)) {
            // New URLs reset the tile; a reconnect retry keeps the "No image" tile up until something loads.
            if shownFor != urls {
                image = nil
                didFail = urls.isEmpty
                shownFor = urls
            }
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
        // A failure while offline isn't final: when the connection returns, walk the chain again — but
        // only if it had actually failed, so a loaded (or genuinely image-less, which the loader remembers)
        // tile isn't disturbed and nothing is re-requested on every connectivity blip. Android 31dcc5d.
        .onChange(of: Connectivity.shared.isOnline) { _, online in
            if online, didFail, !urls.isEmpty { retry += 1 }
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

    /// Detail-hero candidates: the render, then the box shot — the re-hosted one, else BrickLink's packaging
    /// photo (Android does the same). That fallback is for ONE detail page only, never list cards: it 404s
    /// for many sets and rate-limits a burst. `HeroImageGallery` probes and drops whatever doesn't load.
    var heroUrls: [String] {
        guard itemType != .minifig else { return [imageUrl].compactMap { $0?.nilIfBlank } }
        let box = boxImageUrl?.nilIfBlank ?? CatalogImages.boxUrl(setNumber, variant: numberVariant)
        return [imageUrl, box].compactMap { $0?.nilIfBlank }.uniqued(by: \.self)
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
