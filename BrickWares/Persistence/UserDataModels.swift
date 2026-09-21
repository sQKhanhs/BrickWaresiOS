import Foundation
import SwiftData

/*
 * SwiftData = the offline-first source of truth for user data. Every row carries the sync columns —
 * client-generated UUID `id`, client `updatedAt` (LWW basis, epoch millis), a `tombstoned` soft-delete
 * flag, a `dirty` flag for not-yet-pushed local changes — PLUS the catalog display fields the card
 * needs, denormalized in at add-time so owned items render fully OFFLINE (the catalog is network-only).
 *
 * No user_id column: the store holds one account's data at a time; the account-switch guard
 * (`SyncStateStore.lastAccountId`) decides whose it is on login.
 *
 * Naming note: the server column is `deleted`, but Core Data reserves that attribute name
 * (NSManagedObject.isDeleted), so locally it is `tombstoned`.
 */

/// Shared shape of the three user-data rows, so sync/overlay code can be written once.
protocol SyncableRow: PersistentModel {
    var id: String { get set }
    var setId: Int64? { get set }
    var figNum: String? { get set }
    var itemKind: String { get set }
    var setNumber: String { get set }
    var tombstoned: Bool { get set }
    var updatedAt: Int64 { get set }
    var dirty: Bool { get set }

    // Concrete per-model fetches. A `#Predicate` written generically over this protocol resolves its
    // key paths through the protocol witness and fails at runtime, so each model spells its own.
    static func fetchDirty(in ctx: ModelContext) throws -> [Self]
    static func fetch(ids: [String], in ctx: ModelContext) throws -> [Self]
    /// Live (non-tombstoned) rows.
    static func fetchActive(in ctx: ModelContext) throws -> [Self]
}

@Model
final class CollectionCopy: SyncableRow {
    @Attribute(.unique) var id: String
    // Catalog reference: exactly one of setId / figNum (polymorphic set-XOR-minifig).
    var setId: Int64?
    var figNum: String?
    var itemKind: String // "set" | "minifig"
    // Denormalized catalog display (for offline cards). A minifig stores its fig_num in `setNumber`.
    var setNumber: String
    var name: String
    var theme: String
    var subtheme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces: Int
    var minifigs: Int
    var retailPrice: Int64? // USD cents; nil = no retail price
    var status: String // Availability raw value
    var imageUrl: String?
    // Copy data.
    var quantity: Int
    var condition: String // "new" | "used"
    var pricePaid: Int64 // total for qty, in `currency`'s unit
    var currency: String // "USD" | "VND"
    var acquiredOn: String? // yyyy-MM-dd
    var notes: String?
    // Sync.
    var tombstoned: Bool
    var updatedAt: Int64
    var dirty: Bool

    init(
        id: String = newRowId(), setId: Int64?, figNum: String?, itemKind: String,
        setNumber: String, name: String, theme: String, subtheme: String = "General",
        releaseYear: Int = 0, releaseMonth: Int = 0, pieces: Int = 0, minifigs: Int = 0,
        retailPrice: Int64?, status: String, imageUrl: String?,
        quantity: Int, condition: String, pricePaid: Int64, currency: String = "USD",
        acquiredOn: String?, notes: String?,
        tombstoned: Bool = false, updatedAt: Int64, dirty: Bool
    ) {
        self.id = id; self.setId = setId; self.figNum = figNum; self.itemKind = itemKind
        self.setNumber = setNumber; self.name = name; self.theme = theme; self.subtheme = subtheme
        self.releaseYear = releaseYear; self.releaseMonth = releaseMonth
        self.pieces = pieces; self.minifigs = minifigs
        self.retailPrice = retailPrice; self.status = status; self.imageUrl = imageUrl
        self.quantity = quantity; self.condition = condition
        self.pricePaid = pricePaid; self.currency = currency
        self.acquiredOn = acquiredOn; self.notes = notes
        self.tombstoned = tombstoned; self.updatedAt = updatedAt; self.dirty = dirty
    }
}

@Model
final class WishlistItem: SyncableRow {
    @Attribute(.unique) var id: String
    var setId: Int64?
    var figNum: String?
    var itemKind: String
    var setNumber: String
    var name: String
    var theme: String
    var subtheme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces: Int
    var minifigs: Int
    var retailPrice: Int64?
    var status: String
    var imageUrl: String?
    var tombstoned: Bool
    var updatedAt: Int64
    var dirty: Bool

    init(
        id: String = newRowId(), setId: Int64?, figNum: String?, itemKind: String,
        setNumber: String, name: String, theme: String, subtheme: String = "General",
        releaseYear: Int = 0, releaseMonth: Int = 0, pieces: Int = 0, minifigs: Int = 0,
        retailPrice: Int64?, status: String, imageUrl: String?,
        tombstoned: Bool = false, updatedAt: Int64, dirty: Bool
    ) {
        self.id = id; self.setId = setId; self.figNum = figNum; self.itemKind = itemKind
        self.setNumber = setNumber; self.name = name; self.theme = theme; self.subtheme = subtheme
        self.releaseYear = releaseYear; self.releaseMonth = releaseMonth
        self.pieces = pieces; self.minifigs = minifigs
        self.retailPrice = retailPrice; self.status = status; self.imageUrl = imageUrl
        self.tombstoned = tombstoned; self.updatedAt = updatedAt; self.dirty = dirty
    }
}

@Model
final class Sale: SyncableRow {
    @Attribute(.unique) var id: String
    var setId: Int64?
    var figNum: String?
    var itemKind: String
    var setNumber: String
    var name: String
    var theme: String
    var releaseYear: Int
    var releaseMonth: Int
    var imageUrl: String?
    var retailPrice: Int64?
    var quantity: Int
    var condition: String
    var pricePaid: Int64 // cost basis, in `currency`'s unit
    var salePrice: Int64 // in `currency`'s unit
    var currency: String
    var soldOn: String?
    var notes: String?
    var tombstoned: Bool
    var updatedAt: Int64
    var dirty: Bool

    init(
        id: String = newRowId(), setId: Int64?, figNum: String?, itemKind: String,
        setNumber: String, name: String, theme: String,
        releaseYear: Int = 0, releaseMonth: Int = 0, imageUrl: String?, retailPrice: Int64?,
        quantity: Int, condition: String, pricePaid: Int64, salePrice: Int64, currency: String = "USD",
        soldOn: String?, notes: String?,
        tombstoned: Bool = false, updatedAt: Int64, dirty: Bool
    ) {
        self.id = id; self.setId = setId; self.figNum = figNum; self.itemKind = itemKind
        self.setNumber = setNumber; self.name = name; self.theme = theme
        self.releaseYear = releaseYear; self.releaseMonth = releaseMonth
        self.imageUrl = imageUrl; self.retailPrice = retailPrice
        self.quantity = quantity; self.condition = condition
        self.pricePaid = pricePaid; self.salePrice = salePrice; self.currency = currency
        self.soldOn = soldOn; self.notes = notes
        self.tombstoned = tombstoned; self.updatedAt = updatedAt; self.dirty = dirty
    }
}

/// Client-generated row id. Lowercased to match Postgres' canonical uuid text form (and Android's
/// `UUID.randomUUID().toString()`), so a round-tripped id compares equal as a string.
func newRowId() -> String { UUID().uuidString.lowercased() }

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

enum UserDataStore {
    static let schema = Schema([CollectionCopy.self, WishlistItem.self, Sale.self])

    /// The app-wide container. Deliberately NO destructive fallback: resetting the store on a migration
    /// error would drop dirty (unpushed) rows while the pull cursor survives.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration("BrickWares", schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: config)
    }
}

// MARK: - Concrete fetches (see SyncableRow)

extension CollectionCopy {
    static func fetchDirty(in ctx: ModelContext) throws -> [CollectionCopy] {
        try ctx.fetch(FetchDescriptor<CollectionCopy>(predicate: #Predicate { $0.dirty }))
    }

    static func fetch(ids: [String], in ctx: ModelContext) throws -> [CollectionCopy] {
        try ctx.fetch(FetchDescriptor<CollectionCopy>(predicate: #Predicate { ids.contains($0.id) }))
    }

    static func fetchActive(in ctx: ModelContext) throws -> [CollectionCopy] {
        try ctx.fetch(FetchDescriptor<CollectionCopy>(predicate: #Predicate { !$0.tombstoned }))
    }
}

extension WishlistItem {
    static func fetchDirty(in ctx: ModelContext) throws -> [WishlistItem] {
        try ctx.fetch(FetchDescriptor<WishlistItem>(predicate: #Predicate { $0.dirty }))
    }

    static func fetch(ids: [String], in ctx: ModelContext) throws -> [WishlistItem] {
        try ctx.fetch(FetchDescriptor<WishlistItem>(predicate: #Predicate { ids.contains($0.id) }))
    }

    static func fetchActive(in ctx: ModelContext) throws -> [WishlistItem] {
        try ctx.fetch(FetchDescriptor<WishlistItem>(predicate: #Predicate { !$0.tombstoned }))
    }
}

extension Sale {
    static func fetchDirty(in ctx: ModelContext) throws -> [Sale] {
        try ctx.fetch(FetchDescriptor<Sale>(predicate: #Predicate { $0.dirty }))
    }

    static func fetch(ids: [String], in ctx: ModelContext) throws -> [Sale] {
        try ctx.fetch(FetchDescriptor<Sale>(predicate: #Predicate { ids.contains($0.id) }))
    }

    static func fetchActive(in ctx: ModelContext) throws -> [Sale] {
        try ctx.fetch(FetchDescriptor<Sale>(predicate: #Predicate { !$0.tombstoned }))
    }
}
