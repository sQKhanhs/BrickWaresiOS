import Foundation

/// Public image URLs for a set, constructed from its number + variant (both hosts are deterministic).
///
/// The set number is **lowercased**: both CDNs are case-sensitive and store alphanumeric set numbers
/// ("COMCON022", "DC1") in lowercase, while Brickset gives them uppercase.
enum CatalogImages {
    /// BrickLink "original box" packaging photo. Some sets (polybags/promos) have none → 404.
    static func boxUrl(_ setNumber: String, variant: Int = 1) -> String {
        "https://img.bricklink.com/ItemImage/ON/0/\(setNumber.lowercased())-\(variant).png"
    }

    /// Rebrickable studio render of the built set (full resolution — can be several MB).
    static func renderUrl(_ setNumber: String, variant: Int = 1) -> String {
        "https://cdn.rebrickable.com/media/sets/\(setNumber.lowercased())-\(variant).jpg"
    }

    /// Rebrickable's server-resized, square-padded thumbnail (~10–150 KB) for list cards.
    static func thumbUrl(_ setNumber: String, variant: Int = 1, size: Int = 320) -> String {
        "https://cdn.rebrickable.com/media/thumbs/sets/\(setNumber.lowercased())-\(variant).jpg/\(size)x\(size)p.jpg"
    }

    /// The full-resolution render for a stored thumb — same set + **variant**. User rows persist the
    /// thumb but not the number variant, so the render can't be rebuilt from `setNumber` alone.
    static func renderFromThumb(_ thumbUrl: String?) -> String? {
        guard let thumbUrl else { return nil }
        let marker = "/media/thumbs/sets/"
        guard let r = thumbUrl.range(of: marker) else { return thumbUrl }
        let slug = thumbUrl[r.upperBound...].components(separatedBy: ".jpg").first ?? ""
        return "https://cdn.rebrickable.com/media/sets/\(slug).jpg"
    }

    /// The card-sized thumb for a stored Rebrickable *render* URL — the inverse of `renderFromThumb`.
    static func thumbFromRender(_ renderUrl: String, size: Int = 320) -> String {
        let marker = "/media/sets/"
        guard let r = renderUrl.range(of: marker) else { return renderUrl }
        let slug = renderUrl[r.upperBound...].components(separatedBy: ".jpg").first ?? ""
        return "https://cdn.rebrickable.com/media/thumbs/sets/\(slug).jpg/\(size)x\(size)p.jpg"
    }

    /// A theme's hand-curated icon in R2, addressed by a deterministic slug of the theme name.
    static func themeIconUrl(_ theme: String) -> URL? {
        URL(string: "https://img.brickwares.app/themes/\(themeSlug(theme)).png")
    }

    /// "DC Comics Super Heroes" → "dc-comics-super-heroes"; "Pokémon" → "pokemon"; "Gabby's Dollhouse"
    /// → "gabbys-dollhouse". Must stay in step with scripts/theme-icons.csv in the Android repo.
    static func themeSlug(_ theme: String) -> String {
        let stripped = theme.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !$0.properties.generalCategory.isMark }
        let lowered = String(String.UnicodeScalarView(stripped)).lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        let dashed = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private extension Unicode.GeneralCategory {
    var isMark: Bool { self == .nonspacingMark || self == .spacingMark || self == .enclosingMark }
}

/// The "New LEGO Sets" selection rule, shared by the Home preview and the full grouped page.
///
/// A catalog row is "new" when it's **Pending Release**, or was **released in the current or previous
/// month**. Ordered pending-first, then newest release first, then by set number.
enum NewSets {
    static func select(_ catalog: [CatalogSet], now: Date = Date()) -> [CatalogSet] {
        let cal = Calendar.current
        let ref = cal.dateComponents([.year, .month], from: now)
        let prevDate = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let prev = cal.dateComponents([.year, .month], from: prevDate)

        func isNew(_ s: CatalogSet) -> Bool {
            if s.status == .pending { return true }
            guard (1...12).contains(s.releaseMonth) else { return false }
            return (s.releaseYear == ref.year && s.releaseMonth == ref.month)
                || (s.releaseYear == prev.year && s.releaseMonth == prev.month)
        }

        return catalog.filter(isNew).sorted { a, b in
            let ap = a.status == .pending, bp = b.status == .pending
            if ap != bp { return ap }
            let ak = a.releaseYear * 100 + a.releaseMonth, bk = b.releaseYear * 100 + b.releaseMonth
            if ak != bk { return ak > bk }
            return a.setNumber < b.setNumber
        }
    }

    /// `select`ed new sets grouped by theme, themes A→Z; each theme keeps newest-first order.
    static func groupedByTheme(_ catalog: [CatalogSet], now: Date = Date()) -> [(theme: String, sets: [CatalogSet])] {
        let selected = select(catalog, now: now)
        var order: [String] = []
        var groups: [String: [CatalogSet]] = [:]
        for s in selected {
            if groups[s.theme] == nil { order.append(s.theme) }
            groups[s.theme, default: []].append(s)
        }
        return order.sorted { $0.lowercased() < $1.lowercased() }.map { ($0, groups[$0] ?? []) }
    }
}
