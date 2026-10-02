import SwiftUI
import Testing
import UIKit
@testable import BrickWares

// The share card is rasterized with ImageRenderer. These render it the way Save / Share do and check what
// must (not) be in the image; the PNGs are also written to the temp directory for a look.

@MainActor
struct ShareCardRenderTests {
    private let summary = CollectionSummary(
        setCount: 1, minifigCount: 4, pieceCount: 2178, collectionValue: 19_999, paid: 19_999, growthPercent: 0
    )
    private let themes = [ThemeSummary(theme: "Ninjago", setCount: 1, totalValue: 19_999)]
    private let dragon = ShareEntry(
        id: "s1", setNumber: "71872", name: "Ultra Dragon Battle", theme: "Ninjago", value: 19_999, imageUrls: []
    )

    private func card(dark: Bool, capture: Bool, selected: [ShareEntry?]) -> ShareCard {
        ShareCard(
            memberName: "collector", summary: summary, themes: themes, currency: .usd, dark: dark,
            showValue: true, showCollectionValue: true, captureMode: capture, selected: selected, thumbs: [:]
        )
    }

    private func render(_ card: ShareCard, as name: String) throws -> UIImage {
        let renderer = ImageRenderer(content: card.frame(width: ShareCard.width))
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sharecard-\(name).png")
        try image.pngData()?.write(to: url)
        print("SHARECARD \(name) \(url.path)")
        return image
    }

    @Test func emptySlotsAreAnInvitationInTheEditorAndAbsentFromTheImage() throws {
        let editor = try render(card(dark: false, capture: false, selected: [nil, nil, nil]), as: "editor-light")
        let image = try render(card(dark: false, capture: true, selected: [nil, nil, nil]), as: "image-light-empty")
        #expect(abs(editor.size.width - ShareCard.width) < 0.5 && abs(image.size.width - ShareCard.width) < 0.5)
        // Three placeholders + the section label are gone from the image.
        #expect(image.size.height < editor.size.height - 100)
    }

    @Test func aChosenItemIsInTheImageAndTheDarkCardRenders() throws {
        let none = try render(card(dark: true, capture: true, selected: [nil, nil, nil]), as: "image-dark-empty")
        let one = try render(card(dark: true, capture: true, selected: [dragon, nil, nil]), as: "image-dark-one")
        #expect(one.size.height > none.size.height + 40)
        _ = try render(card(dark: true, capture: false, selected: [dragon, nil, nil]), as: "editor-dark-one")
    }
}
