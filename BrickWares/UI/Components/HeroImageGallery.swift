import SwiftUI

/// The detail hero: a swipeable pager over an item's images (render + box shot) with a thumbnail strip to
/// tap between them; tapping the image opens the full-screen gallery AT the current image.
///
/// Candidates are PROBED first (through the image cache), so a set with no box shot shows just its render:
/// the strip appears only once probing has settled and 2+ images actually loaded, instead of appearing and
/// then collapsing a second later. Until then only the first candidate is shown. Android `HeroImageGallery`
/// (c161c61 + 1101564).
struct HeroImageGallery: View {
    /// Candidates in display order; ones that fail to load are dropped.
    let urls: [String]
    var height: CGFloat = 240
    var maxPointSize: CGFloat = 360
    /// Open the full-screen gallery with the images that loaded, at `index`.
    let onOpen: (_ loaded: [String], _ index: Int) -> Void

    @Environment(\.displayScale) private var scale
    /// The candidates that loaded; nil while probing.
    @State private var loaded: [String]?
    @State private var selection = 0
    /// Bumped to probe again when connectivity returns.
    @State private var retry = 0
    /// The candidates `loaded` was probed for.
    @State private var probedFor: [String]?

    private struct ProbeKey: Hashable {
        var urls: [String]
        var retry: Int
    }

    var body: some View {
        VStack(spacing: 10) {
            pager
                .frame(maxWidth: .infinity).frame(height: height)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
            if let loaded, loaded.count > 1 { strip(loaded) }
        }
        .task(id: ProbeKey(urls: urls, retry: retry)) { await probe() }
        // Probed while offline (or only partly reachable): try the missing candidates again on reconnect.
        .onChange(of: Connectivity.shared.isOnline) { _, online in
            if online, let loaded, loaded.count < urls.count { retry += 1 }
        }
    }

    @ViewBuilder private var pager: some View {
        if let loaded {
            if loaded.count > 1 {
                TabView(selection: $selection) {
                    ForEach(Array(loaded.enumerated()), id: \.element) { index, url in
                        image([url])
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(loaded, index) }
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                // One image — or none, which renders the "No image" tile and stays inert.
                image(loaded)
                    .contentShape(Rectangle())
                    .onTapGesture { if !loaded.isEmpty { onOpen(loaded, 0) } }
            }
        } else {
            image(Array(urls.prefix(1)))
        }
    }

    private func image(_ urls: [String]) -> some View {
        RemoteImage(urls, maxPointSize: maxPointSize).accessibilityAddTraits(.isImage)
    }

    private func strip(_ loaded: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(loaded.enumerated()), id: \.element) { index, url in
                let selected = index == selection
                Button { withAnimation(.snappy) { selection = index } } label: {
                    RemoteImage([url], maxPointSize: 56)
                        .frame(width: 56, height: 56)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? Bw.yellow : Bw.borderSoft, lineWidth: selected ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// Loads every candidate at the hero's size (so the pager then paints from cache) and keeps the ones
    /// that worked, in order.
    private func probe() async {
        let candidates = urls
        // New candidates start over; a reconnect retry keeps what is showing until the new result is in.
        if probedFor != candidates {
            loaded = nil
            selection = 0
            probedFor = candidates
        }
        let pixel = maxPointSize * scale
        let ok = await withTaskGroup(of: (Int, Bool).self) { group -> [Bool] in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, await ImageLoader.shared.image(url, maxPixel: pixel) != nil) }
            }
            var ok = Array(repeating: false, count: candidates.count)
            for await (index, success) in group { ok[index] = success }
            return ok
        }
        guard !Task.isCancelled else { return }
        let found = candidates.enumerated().filter { ok[$0.offset] }.map { $0.element }
        if selection >= max(found.count, 1) { selection = 0 }
        loaded = found
    }
}
