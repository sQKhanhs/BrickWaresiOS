import Foundation

/// CSV (de)serialization for the user-data export/import — collection, sales AND wishlist in one file,
/// **format-compatible with the Android app** (same columns, same `format_version`), so a backup moves
/// between platforms. Every row is tagged with a `record_type`; import maps by header **name** (not
/// position) so a hand-edited or older file still loads.
///
/// Sync/identity fields (`id`, `deleted`, `updatedAt`, `dirty`) are NOT exported — import always mints
/// a fresh id and marks the row dirty. RFC-4180 quoting handles commas, quotes and newlines.
enum CollectionCSV {
    /// v2 = `record_type` + the sales/wishlist columns. A NEWER file is refused rather than imported
    /// with silent gaps; a file with no marker reads as v1 (all rows are collection copies).
    static let formatVersion = 2

    enum ImportError: LocalizedError {
        case notABrickWaresExport
        case tooNew(Int)

        var errorDescription: String? {
            switch self {
            case .notABrickWaresExport: String(localized: "This file isn't a BrickWares export.")
            case .tooNew: String(localized: "This file was made by a newer version of BrickWares. Update the app to import it.")
            }
        }
    }

    private static let columns = [
        "format_version", "record_type",
        "set_number", "name", "item_kind", "fig_num", "set_id",
        "theme", "subtheme", "release_year", "release_month", "pieces", "minifigs",
        "retail_price", "status", "image_url",
        "quantity", "condition", "currency", "price_paid", "sale_price",
        "acquired_on", "sold_on", "notes",
    ]

    struct Parsed {
        var header: [String]
        var rows: [[String: String]]
    }

    struct Imported {
        var copies: [CollectionCopy] = []
        var sales: [Sale] = []
        var wishlist: [WishlistItem] = []
    }

    // MARK: Encode

    @MainActor
    static func encode(copies: [CollectionCopy], sales: [Sale], wishlist: [WishlistItem]) -> String {
        var out = columns.map(escape).joined(separator: ",") + "\n"
        func append(_ row: [String: String]) {
            out += columns.map { escape(row[$0] ?? "") }.joined(separator: ",") + "\n"
        }
        let v = String(formatVersion)
        for r in copies {
            append([
                "format_version": v, "record_type": "collection",
                "set_number": r.setNumber, "name": r.name, "item_kind": r.itemKind,
                "fig_num": r.figNum ?? "", "set_id": r.setId.map(String.init) ?? "",
                "theme": r.theme, "subtheme": r.subtheme,
                "release_year": String(r.releaseYear), "release_month": String(r.releaseMonth),
                "pieces": String(r.pieces), "minifigs": String(r.minifigs),
                "retail_price": r.retailPrice.map(String.init) ?? "", "status": r.status,
                "image_url": r.imageUrl ?? "",
                "quantity": String(r.quantity), "condition": r.condition, "currency": r.currency,
                "price_paid": String(r.pricePaid),
                "acquired_on": r.acquiredOn ?? "", "notes": r.notes ?? "",
            ])
        }
        for r in sales {
            append([
                "format_version": v, "record_type": "sale",
                "set_number": r.setNumber, "name": r.name, "item_kind": r.itemKind,
                "fig_num": r.figNum ?? "", "set_id": r.setId.map(String.init) ?? "",
                "theme": r.theme,
                "release_year": String(r.releaseYear), "release_month": String(r.releaseMonth),
                "retail_price": r.retailPrice.map(String.init) ?? "", "image_url": r.imageUrl ?? "",
                "quantity": String(r.quantity), "condition": r.condition, "currency": r.currency,
                "price_paid": String(r.pricePaid), "sale_price": String(r.salePrice),
                "sold_on": r.soldOn ?? "", "notes": r.notes ?? "",
            ])
        }
        for r in wishlist {
            append([
                "format_version": v, "record_type": "wishlist",
                "set_number": r.setNumber, "name": r.name, "item_kind": r.itemKind,
                "fig_num": r.figNum ?? "", "set_id": r.setId.map(String.init) ?? "",
                "theme": r.theme, "subtheme": r.subtheme,
                "release_year": String(r.releaseYear), "release_month": String(r.releaseMonth),
                "pieces": String(r.pieces), "minifigs": String(r.minifigs),
                "retail_price": r.retailPrice.map(String.init) ?? "", "status": r.status,
                "image_url": r.imageUrl ?? "",
            ])
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : s
    }

    // MARK: Parse

    static func version(of parsed: Parsed) -> Int {
        parsed.rows.first?["format_version"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
    }

    static func parse(_ text: String) -> Parsed {
        // Strip a UTF-8 BOM (Excel adds one) so the first header still reads "format_version".
        let records = parseRecords(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let first = records.first else { return Parsed(header: [], rows: []) }
        let header = first.map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = records.dropFirst()
            .filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
            .map { fields in
                Dictionary(uniqueKeysWithValues: header.indices.map { i in
                    (header[i], i < fields.count ? fields[i] : "")
                }.uniqued(by: \.0))
            }
        return Parsed(header: header, rows: rows)
    }

    /// Split CSV text into records of fields, honoring quoted fields. Iterates unicode scalars (not
    /// Characters) so a CRLF — one grapheme in Swift — is still seen as '\r' then '\n'.
    private static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var cur = String.UnicodeScalarView()
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { cur.append(ch); i += 1 } else { inQuotes = false }
                } else {
                    cur.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": fields.append(String(cur)); cur = .init()
                case "\n": fields.append(String(cur)); cur = .init(); records.append(fields); fields = []
                case "\r": break // CRLF — the '\n' closes the record
                default: cur.append(ch)
                }
            }
            i += 1
        }
        if !cur.isEmpty || !fields.isEmpty { fields.append(String(cur)); records.append(fields) }
        return records
    }

    // MARK: Rows → fresh dirty models

    @MainActor
    static func rows(from parsed: Parsed, setIdByNumber: [String: Int64], now: Int64) -> Imported {
        var out = Imported()
        for row in parsed.rows {
            let kind = row.value("item_kind")?.lowercased() == "minifig" ? "minifig" : "set"
            let setIdCol = row.value("set_id").flatMap { Int64($0) }
            // Fig-referenced iff there's a real fig_num: the explicit column, or a legacy minifig row
            // that stored the fig_num in set_number with no set_id. A CMF is minifig-KIND but set_id-
            // referenced, so it must NOT be read as a fig_num row (that breaks the server one_ref XOR).
            let figNum = row.value("fig_num")?.nilIfBlank
                ?? ((kind == "minifig" && setIdCol == nil) ? row.value("set_number")?.nilIfBlank : nil)
            guard let setNumber = row.value("set_number")?.nilIfBlank ?? figNum else { continue }
            let isFigRef = figNum != nil
            let setId = isFigRef ? nil : (setIdCol ?? setIdByNumber[setNumber])
            let currency = AppCurrency(rawValue: (row.value("currency") ?? "").uppercased())?.rawValue ?? "USD"
            let condition = row.value("condition")?.lowercased() == "used" ? "used" : "new"
            let quantity = max(1, row.value("quantity").flatMap { Int($0) } ?? 1)
            func int(_ k: String) -> Int { row.value(k).flatMap { Int($0) } ?? 0 }
            func money(_ k: String) -> Int64 { row.value(k).flatMap { Int64($0) } ?? 0 }

            switch row.value("record_type")?.lowercased() ?? "collection" {
            case "sale":
                out.sales.append(Sale(
                    setId: setId, figNum: figNum, itemKind: kind, setNumber: setNumber,
                    name: row.value("name") ?? "", theme: row.value("theme") ?? "Unknown",
                    releaseYear: int("release_year"), releaseMonth: int("release_month"),
                    imageUrl: row.value("image_url"), retailPrice: row.value("retail_price").flatMap { Int64($0) },
                    quantity: quantity, condition: condition,
                    pricePaid: money("price_paid"), salePrice: money("sale_price"), currency: currency,
                    soldOn: row.value("sold_on"), notes: row.value("notes"), updatedAt: now, dirty: true
                ))
            case "wishlist":
                out.wishlist.append(WishlistItem(
                    setId: setId, figNum: figNum, itemKind: kind, setNumber: setNumber,
                    name: row.value("name") ?? "", theme: row.value("theme") ?? "Unknown",
                    subtheme: row.value("subtheme") ?? "General",
                    releaseYear: int("release_year"), releaseMonth: int("release_month"),
                    pieces: int("pieces"), minifigs: int("minifigs"),
                    retailPrice: row.value("retail_price").flatMap { Int64($0) },
                    status: row.value("status") ?? Availability.available.rawValue,
                    imageUrl: row.value("image_url"), updatedAt: now, dirty: true
                ))
            default:
                out.copies.append(CollectionCopy(
                    setId: setId, figNum: figNum, itemKind: kind, setNumber: setNumber,
                    name: row.value("name") ?? "", theme: row.value("theme") ?? "Unknown",
                    subtheme: row.value("subtheme") ?? "General",
                    releaseYear: int("release_year"), releaseMonth: int("release_month"),
                    pieces: int("pieces"), minifigs: int("minifigs"),
                    retailPrice: row.value("retail_price").flatMap { Int64($0) },
                    status: row.value("status") ?? Availability.available.rawValue,
                    imageUrl: row.value("image_url"),
                    quantity: quantity, condition: condition,
                    pricePaid: money("price_paid"), currency: currency,
                    acquiredOn: row.value("acquired_on"), notes: row.value("notes"),
                    updatedAt: now, dirty: true
                ))
            }
        }
        return out
    }
}

extension Dictionary where Key == String, Value == String {
    /// Trimmed, blank → nil.
    func value(_ key: String) -> String? {
        self[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
