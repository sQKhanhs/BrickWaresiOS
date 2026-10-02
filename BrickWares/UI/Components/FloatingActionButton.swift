import SwiftUI

/// The round yellow action button floating at the bottom-right of a tab, above the tab bar — Android's
/// FAB (56 pt, 20 from the edge, 24 above the bar). iOS would put this action in the navigation bar's
/// top-right corner, which is the hardest spot to reach one-handed on a tall phone; the owner chose
/// reach, and the same place on both platforms.
///
/// `pulsing` fades it in and out to prompt the first action while the list is empty (Android's
/// `blinkAttention`); it stays solid under Reduce Motion.
struct FloatingActionButton: View {
    let systemImage: String
    let label: String
    var pulsing = false
    let action: () -> Void

    /// Bottom scroll margin for the list underneath, so its last card can scroll clear of the button.
    static let listClearance: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var pulse: Bool { pulsing && !reduceMotion }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Bw.onYellow)
                .frame(width: 56, height: 56)
                .background(Bw.yellow, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Scoped to the opacity alone: a repeating `withAnimation` started as the screen lays out would
        // also capture the button's position and send it drifting in from the corner.
        .animation(pulse ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : .easeOut(duration: 0.2)) {
            $0.opacity(dimmed ? 0.4 : 1)
        }
        .accessibilityLabel(label)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .onChange(of: pulse, initial: true) { _, on in dimmed = on }
    }
}

/// The Collection ⇄ Sales switch: a round button floating at the bottom-LEFT of the Collection tab,
/// opposite the add button — Android's "swap FAB" (52 pt, card-coloured with a border, turning brand
/// yellow while Sales is showing). It replaced a segmented control in the navigation bar, which sat out
/// of thumb reach. Which mode is showing is also told by the banner title ("My Collection" / "My Sales").
struct SalesSwapButton: View {
    let salesActive: Bool
    let action: () -> Void

    var body: some View {
        let tint = salesActive ? Bw.onYellow : Bw.text
        Button(action: action) {
            ZStack {
                Image("ic_bw_sales_swap").resizable().scaledToFit().frame(width: 26, height: 26)
                Text(verbatim: "$").font(.system(size: 9, weight: .black))
            }
            .foregroundStyle(tint)
            .frame(width: 52, height: 52)
            .background(salesActive ? Bw.yellow : Bw.card, in: Circle())
            .overlay(Circle().strokeBorder(salesActive ? Bw.yellow : Bw.borderStrong, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("collection_toggle_sales_cd"))
        .accessibilityAddTraits(salesActive ? .isSelected : [])
        .padding(.leading, 20)
        .padding(.bottom, 24)
    }
}

