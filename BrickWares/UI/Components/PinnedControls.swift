import SwiftUI

extension View {
    /// Dresses the header of a `Section` that stays pinned while its list scrolls — the filter / sort row
    /// of a list screen (Android's `stickyHeader`). The screen colour sits behind it, opaque and edge to
    /// edge, so the cards sliding under it are hidden; it reaches 6 pt above and below the controls.
    ///
    /// `inList`: a `List` header is given no insets and clips, so the gutter and those 6 pt are padding.
    /// In a stack that is already inset, the colour simply overflows the header, leaving the stack's own
    /// spacing as it was.
    func pinnedControls(inList: Bool) -> some View {
        padding(.horizontal, inList ? Bw.gutter : 0)
            .padding(.vertical, inList ? 6 : 0)
            .frame(maxWidth: .infinity)
            .background(Bw.bg.padding(.horizontal, inList ? 0 : -Bw.gutter).padding(.vertical, inList ? 0 : -6))
            .listRowInsets(EdgeInsets())
            .textCase(nil)
    }

    /// For a scrolling screen with pinned controls: paints the top safe area — status bar and navigation
    /// bar — in the screen colour. A list normally shows through there, so cards would vanish under the
    /// pinned header and reappear above it.
    func opaqueTopBar() -> some View { modifier(OpaqueTopBar()) }
}

private struct OpaqueTopBar: ViewModifier {
    func body(content: Content) -> some View {
        cover(edgeEffectOff(content))
    }

    private func cover(_ view: some View) -> some View {
        view.overlay(alignment: .top) {
            Color.clear.frame(height: 0).background(Bw.bg, ignoresSafeAreaEdges: .top)
        }
    }

    /// iOS 26 fades whatever scrolls up to the top edge; with the edge opaque that fade would only smudge
    /// the first card under the pinned header.
    @ViewBuilder private func edgeEffectOff(_ view: Content) -> some View {
        if #available(iOS 26.0, *) {
            view.scrollEdgeEffectHidden(true, for: .top)
        } else {
            view
        }
    }
}
