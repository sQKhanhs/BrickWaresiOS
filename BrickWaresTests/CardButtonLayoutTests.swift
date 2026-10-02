import SwiftUI
import Testing
import UIKit
@testable import BrickWares

// The price column of a list card, measured inside a real `List` row — the context matters: iOS 26's
// list label style reports no ideal width, which once left "See Detail" cut to "Se…" there while the same
// column outside a List (and on iOS 18) measured fine.

@MainActor
private final class Widths { var value: [String: CGFloat] = [:] }

@MainActor
struct CardButtonLayoutTests {
    private func measured(_ key: String, in box: Widths) -> some ViewModifier { Measure(key: key, box: box) }

    private struct Measure: ViewModifier {
        let key: String
        let box: Widths
        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box.value[key] = $0 }
        }
    }

    /// A card row like `WishlistCard`: thumb, flexible title column, price column with two stacked buttons.
    private func row(_ box: Widths) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Color.gray.frame(width: 72, height: 72)
            Text(verbatim: "76304 Batman Forever Batmobile").font(.subheadline.weight(.bold)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                PriceLine(label: "Paid", value: "$0.50") // narrower than either button
                Button {} label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.bwPrimaryColumn)
                    .modifier(measured("add", in: box))
                Button {} label: { Label("See Detail", systemImage: "checkmark") }
                    .buttonStyle(.bwSecondaryColumn)
                    .modifier(measured("detail", in: box))
            }
            .priceColumn()
            .modifier(measured("column", in: box))
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    /// The label on its own: the least a button can be without cutting its title.
    private func bareLabel(_ box: Widths) -> some View {
        HStack(spacing: 5) { Image(systemName: "checkmark"); Text(verbatim: "See Detail") }
            .font(.footnote.weight(.semibold)).fixedSize()
            .modifier(measured("label", in: box))
    }

    @Test func columnButtonsShowTheirWholeTitleAndMatchInWidth() async throws {
        let box = Widths()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: List { row(box); bareLabel(box) }.listStyle(.plain))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // Geometry lands on the next run-loop turns.
        for _ in 0..<40 where box.value.count < 4 { try await Task.sleep(for: .milliseconds(50)) }
        window.isHidden = true

        let label = try #require(box.value["label"])
        let detail = try #require(box.value["detail"])
        let add = try #require(box.value["add"])
        let column = try #require(box.value["column"])
        #expect(detail >= label + 20 - 0.5) // the title plus the button's side padding: nothing cut
        #expect(abs(add - detail) < 0.5)    // stacked buttons are the same width…
        #expect(abs(column - detail) < 0.5) // …the column's, which hugs its widest line
    }
}
