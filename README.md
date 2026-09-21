# BrickWares for iOS

SwiftUI port of the BrickWares Android app (LEGO collection tracker, Vietnam-first, EN/VI). Same
Supabase backend, same data contract, native iOS feel. iOS 18+, Swift 6.2 toolchain (Xcode 26).

## Setup

1. Copy `BrickWares/Secrets.example.plist` → `BrickWares/Secrets.plist` and set `SUPABASE_ANON_KEY`
   (the hosted project's publishable key — `BRICKWARES_PROD_ANON_KEY` in the Android `local.properties`).
   Both `Secrets.plist` and `local.properties` are gitignored.
2. Open `BrickWares.xcodeproj`; the `supabase-swift` package resolves automatically.
3. Supabase dashboard (one-time): enable the **Apple** auth provider, and add
   `brickwares://auth-callback` to Auth → URL Configuration → Redirect URLs (Google sign-in uses the
   OAuth web sheet).

## Layout

```
BrickWares/
  App/          AppConfig, AppRouter (tabs + typed routes), RootView (shell, splash, toast)
  Models/       value types + pure logic: money rules, ValueAggregator, CollectionStats
  Persistence/  SwiftData @Models (the 3 synced user tables), SyncStateStore, prefs
  Services/     CatalogRepository (remote, read-only), ValueService, AuthService, SyncEngine
                (@ModelActor), CollectionService (the ONLY write path), CSV, feedback, alerts
  UI/           Theme tokens, shared components, one folder per screen
Config/         Info.plist additions + entitlements (outside the synced source folder)
scripts/gen_strings.py   regenerates Localizable.xcstrings from the Android strings.xml
```

Architecture in one paragraph: light MV (views bind to `@Query` + small `@Observable` services; only
Search has a screen model). SwiftData is the offline-first source of truth for the user's rows; the
catalog is never stored. Every write goes through `CollectionService`, lands locally first (dirty +
client `updatedAt`), then a debounced `SyncEngine` pushes by client UUID and pulls by the server
`server_updated_at` cursor with last-write-wins on the client timestamp and soft-delete tombstones.

## Localization

String keys are **shared with Android**. After changing copy in the Android `strings.xml`:

```bash
python3 scripts/gen_strings.py
```

iOS-only strings live in the `IOS_ONLY` dict in that script.

## Tests

Run serially — parallel testing boots extra simulator clones:

```bash
xcodebuild test -project BrickWares.xcodeproj -scheme BrickWares \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' \
  -parallel-testing-enabled NO
```

- `BrickWaresTests` — parity tests for the logic that must match Android exactly (money formatting,
  value aggregator, CSV round-trip, copy-merge and sale-proration rules) plus read-only live catalog
  checks (skipped when `Secrets.plist` is absent).
- `BrickWaresUITests` — signed-out walkthrough of every tab against the live catalog.
