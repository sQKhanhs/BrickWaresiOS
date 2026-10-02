import SwiftUI

/// Numbered pages for the long lists (Collection, Sales, Wishlist, a theme's results, the theme browse) —
/// Android's `PAGE_SIZE` and `pageWindow`. Pages are 1-based.
enum Pagination {
    static let pageSize = 10

    static func pageCount(of total: Int, pageSize: Int = pageSize) -> Int {
        max(1, (total + pageSize - 1) / pageSize)
    }

    /// `page` kept inside 1...pageCount — a stored page can be past the end after a delete or a filter.
    static func clamp(_ page: Int, total: Int, pageSize: Int = pageSize) -> Int {
        min(max(page, 1), pageCount(of: total, pageSize: pageSize))
    }

    /// The items of `page` (clamped).
    static func items<T>(_ all: [T], page: Int, pageSize: Int = pageSize) -> [T] {
        let start = (clamp(page, total: all.count, pageSize: pageSize) - 1) * pageSize
        return Array(all.dropFirst(start).prefix(pageSize))
    }

    /// What the bar shows: page numbers, with nil marking an ellipsis gap. Up to seven pages are all
    /// shown; beyond that, the first, the last and the current page with its two neighbours.
    static func window(current: Int, total: Int) -> [Int?] {
        guard total > 7 else { return Array(1...max(total, 1)) }
        var pages: Set<Int> = [1, total]
        for p in (current - 1)...(current + 1) where p > 1 && p < total { pages.insert(p) }
        var result: [Int?] = []
        var previous = 0
        for p in pages.sorted() {
            if previous != 0, p - previous > 1 { result.append(nil) }
            result.append(p)
            previous = p
        }
        return result
    }
}

/// ‹ 1 2 … n › — tap a number to jump straight to that page; the ellipsis asks for one (Android's
/// `PaginationBar`). Draws nothing for a single page.
struct PaginationBar: View {
    let currentPage: Int
    let totalPages: Int
    let onSelect: (Int) -> Void

    @State private var showJump = false
    @State private var jumpText = ""

    var body: some View {
        if totalPages > 1 {
            // Three-digit page numbers don't fit seven cells at full size on a phone.
            ViewThatFits(in: .horizontal) {
                cells(spacing: 6, minSize: 34, inset: 10)
                cells(spacing: 4, minSize: 30, inset: 6)
                cells(spacing: 2, minSize: 26, inset: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .alert(L("pagination_go_title"), isPresented: $showJump) {
                // A plain String: a literal here would be extracted into the string catalog as a key.
                TextField(String("1–\(totalPages)"), text: $jumpText).keyboardType(.numberPad)
                Button(L("action_go")) {
                    if let page = Int(jumpText.filter(\.isNumber)) { onSelect(min(max(page, 1), totalPages)) }
                }
                Button(L("action_cancel"), role: .cancel) {}
            }
        }
    }

    private func cells(spacing: CGFloat, minSize: CGFloat, inset: CGFloat) -> some View {
        HStack(spacing: spacing) {
            cell("‹", minSize: minSize, inset: inset, enabled: currentPage > 1) { onSelect(currentPage - 1) }
                .accessibilityLabel(L("pagination_page_of", currentPage - 1, totalPages))
            ForEach(Array(Pagination.window(current: currentPage, total: totalPages).enumerated()), id: \.offset) { _, token in
                if let token {
                    cell(String(token), minSize: minSize, inset: inset, selected: token == currentPage) { onSelect(token) }
                        .accessibilityLabel(L("pagination_page_of", token, totalPages))
                        .accessibilityAddTraits(token == currentPage ? .isSelected : [])
                } else {
                    cell("…", minSize: minSize, inset: inset) { jumpText = ""; showJump = true }
                        .accessibilityLabel(L("pagination_go_title"))
                }
            }
            cell("›", minSize: minSize, inset: inset, enabled: currentPage < totalPages) { onSelect(currentPage + 1) }
                .accessibilityLabel(L("pagination_page_of", currentPage + 1, totalPages))
        }
    }

    private func cell(
        _ label: String, minSize: CGFloat, inset: CGFloat, selected: Bool = false, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? Bw.onYellow : (enabled ? Bw.text : Bw.textFaint))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, inset)
                .frame(minWidth: minSize, minHeight: minSize)
                .background(selected ? Bw.yellow : Bw.card, in: shape)
                .overlay(shape.strokeBorder(Bw.borderSoft))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // The current page is not a button — but `.disabled` would also grey out its highlight.
        .allowsHitTesting(!selected)
    }
}
