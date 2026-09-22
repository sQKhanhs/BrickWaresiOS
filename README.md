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

## Build variants

Two schemes, mirroring the Android `prod` / `dev` flavors:

| Scheme | Config | Backend | Bundle id | Captcha |
|---|---|---|---|---|
| **BrickWares** | Debug / Release | prod Supabase (from `Secrets.plist`) | `com.SenniApp.BrickWares` | Turnstile |
| **BrickWares Dev** | Dev | **local** Supabase (CLI + Docker) | `com.SenniApp.BrickWares.dev` | off |

Pick the scheme from Xcode's toolbar. The bundle ids differ, so the dev app installs **side by side** with prod.

**Run the Dev variant against local Supabase:**

1. Start the local stack on the Mac: `supabase start` (serves `http://127.0.0.1:54321` and prints the local
   publishable key — already hardcoded as `AppConfig.devSupabaseAnonKey`, identical on every machine).
2. Select the **BrickWares Dev** scheme and run on the **Simulator** — it reaches the Mac's `127.0.0.1`
   directly (there is no `10.0.2.2` alias like the Android emulator).
3. The Dev build targets `http://127.0.0.1:54321`, uses the local key, and skips the captcha gate (local
   GoTrue has captcha off). `NSAllowsLocalNetworking` in `Config/Info.plist` permits the cleartext HTTP.

**On a physical device** the phone can't reach the Mac's `127.0.0.1`: in the *BrickWares Dev* scheme →
Run → Arguments, enable the `BRICKWARES_DEV_SUPABASE_URL` env var and set it to `http://<mac-LAN-IP>:54321`.
The local stack must bind `0.0.0.0` (`[api] host` in `supabase/config.toml`) and the Mac firewall must allow
TCP 54321. Apple/Google sign-in also need those providers configured in the local `config.toml`; email + OTP
work out of the box (the CLI captures mail in its Inbucket/Mailpit inbox).

`DEV_LOCAL` (a `SWIFT_ACTIVE_COMPILATION_CONDITIONS` flag on the `Dev` configuration) gates all of the above
in `AppConfig` — prod builds never compile the local-Supabase branch.

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
