---
date: 2026-04-19
topic: In-app auto-update via Sparkle, wired to GitHub Releases
status: draft
---

# Auto-Update — Sparkle + GitHub Releases

## Background

theall currently has no version display and no update mechanism. Users have no way to tell which build they are running, and new releases (when they start shipping) would require hand-distributed installs. The closest reference point is the sibling project input0 (Tauri app), which shows `v{version}` in its sidebar footer, checks GitHub Releases on launch, and performs silent download + relaunch via Tauri's updater plugin. Users want the same behavioral flow for theall, adapted to its Swift/AppKit+SwiftUI stack.

Sparkle is the de-facto standard macOS auto-update framework, handles EdDSA signature verification, background downloads, and relaunch mechanics. It will be integrated with a fully custom `SPUUserDriver` implementation so all UI lives inside the existing Settings panel — matching the input0 experience rather than Sparkle's default NSAlert-style windows.

GitHub repository for releases: `https://github.com/AbadOrangeCat/TheALL` (not yet published at spec-write time).

## Goals

- Display `v{MARKETING_VERSION}` in the sidebar footer, left-aligned, clickable.
- Clicking the version number opens Settings scrolled to a new `Update` section.
- A red pulsing dot appears next to the version when an update is available.
- The Update section exposes a full update flow (check / download / install / skip / dismiss / retry) with all states visible inline — no modal windows.
- Auto-check on launch (3 s after `applicationDidFinishLaunching`) plus a 24 h background timer. Silent when no update; sets the red dot when one is found.
- Releases are published via GitHub Releases; Sparkle consumes a per-release `appcast.xml` asset.
- First release is `v0.1.0`, arm64-only, EdDSA-signed, ad-hoc code-signed (no Developer ID in v1).

## Non-Goals

- Developer ID code signing and notarization. Users will see a Gatekeeper warning on first install and must right-click → Open. Acceptable for v1; tracked as a later spec.
- x86_64 / Intel / universal binaries. arm64-only until a user asks.
- A beta/prerelease channel. Prereleases on GitHub are ignored entirely by the update check. Separate beta channel would use a different appcast URL in a future spec.
- Cumulative historical appcast (listing all prior versions). The appcast contains a single `<item>` pointing at the latest release. Users can browse older versions via the GitHub Releases page.
- Sparkle's default UI (`SPUStandardUserDriver`). All UI is custom.
- "Last-checked timestamp" UI. Sparkle stores it internally (`SULastCheckTime`) but it is not surfaced to users.
- Checking for updates in Debug builds. Skipped via `#if !DEBUG`.

## User-Visible Behavior

### Sidebar footer

Layout replaces the current gear-only footer in `TheAll/Sidebar/SidebarView.swift`:

```
v0.1.0 •                              [⚙]
```

- Version text on the left, taken from `Bundle.main.infoDictionary["CFBundleShortVersionString"]`, prefixed with `v`.
- Red pulsing dot appears **only** when `UpdateStore.hasUpdate == true`. Implemented as `Image(systemName: "circle.fill")` at 6 pt, `foregroundColor(theme.danger)`, with `.symbolEffect(.pulse)` — symbol-effect only applies to SF Symbols, so we use a filled-circle glyph rather than a `Circle()` shape. On macOS < 14 fallback: plain filled glyph without animation (no-op — project deployment target is 14.0).
- Version text wrapped in a `Button` style; clicking fires `NotificationCenter.default.post(name: .theAllOpenSettings, object: nil, userInfo: ["section": "update"])`.
- Gear icon remains on the right, fires the existing `.theAllOpenSettings` notification without `userInfo` (defaults to Appearance).

### Settings → Update section

New section added as the 5th tab in `Settings/SettingsTabBarView.swift`: order becomes `appearance | font | terminal | shell | update`.

UI states (driven by `UpdateStore.state`):

| State                        | UI                                                                                                                                             |
|------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| `.idle`                      | `Current version: {v}` (`theme.textSecondary`) + primary button `Check for Updates`                                                             |
| `.checking`                  | Primary button disabled, shows spinner + `Checking…`                                                                                           |
| `.upToDate`                  | Green check + `You're on the latest version.` Auto-transitions back to `.idle` after 3 s                                                        |
| `.updateAvailable(v, notes)` | Info card (border + bg `theme.accent` at low opacity): `Version {v} is available` / release notes in a `ScrollView` (max height 128 pt, `whitespace-pre-wrap` equivalent) / buttons `[Download & Install]` `[Skip This Version]` + small text link `Dismiss` |
| `.downloading(progress)`     | Progress bar + `Downloading… {pct}%`                                                                                                            |
| `.readyToInstall`            | Transient: `Installing & relaunching…` — Sparkle immediately quits and relaunches                                                              |
| `.error(message)`            | Red-bordered card (`theme.danger`): message + `[Retry]` button                                                                                  |

Release notes rendering: plain text, no Markdown parsing. Matches input0. The appcast delivers release notes as CDATA inside `<description>`; Sparkle hands them to the driver as a `String`. The UI preserves line breaks but does not interpret headings, lists, bold, etc.

### Automatic check

- On `applicationDidFinishLaunching`, a 3 s delay then `SparkleBridge.shared.checkForUpdates(silently: true)`. "Silently" means: if an update exists, set `UpdateStore.state = .updateAvailable(...)` (lights the sidebar red dot); if not, state stays `.idle`. No toast, no alert, no state churn in the Update section unless the user opens it.
- Sparkle's scheduler runs a follow-up check every 24 h (`SUScheduledCheckInterval = 86400`).
- Manual check (user clicks `Check for Updates`): fires immediately, no 3 s delay. Drives state through `.checking` → `.upToDate` / `.updateAvailable` / `.error`.
- Debug builds skip both the launch check and the 24 h scheduler: the Sparkle bridge is never initialized inside `#if !DEBUG`. The `Update` section in Settings still renders but shows `Current version: {v}` with `Check for Updates` disabled and a small `"(disabled in Debug builds)"` hint.

## Code Structure

### New directory `TheAll/Update/`

Follows the same pattern as `TheAll/Ghostty/` and `TheAll/Metadata/` — an external-dependency wrapper layer isolated from the rest of the app.

```
TheAll/Update/
├── UpdateState.swift        — enum UpdateState, with associated values for progress / version / notes / error
├── UpdateStore.swift        — @Observable, single source of truth (state, currentVersion, hasUpdate computed)
├── SparkleBridge.swift      — singleton, owns SPUUpdater, exposes checkForUpdates/download/install/skip/retry/dismiss
└── UpdateUserDriver.swift   — impl SPUUserDriver, maps Sparkle events → UpdateStore mutations (MainActor)
```

**Isolation rule** (project convention mirror): Sparkle APIs are only imported inside `SparkleBridge.swift` and `UpdateUserDriver.swift`. Other files read/write state via `UpdateStore` only.

### Data flow

```
Sparkle internal ─► UpdateUserDriver (SPUUserDriver)
                       │ (main-actor mutates)
                       ▼
                   UpdateStore (@Observable)
                       │ (SwiftUI observation)
                       ├─► SidebarView footer (red dot visibility)
                       └─► UpdateSectionView (main panel UI)

User action (click) ──► SparkleBridge.shared.{checkForUpdates | downloadAndInstall | installNow | skipVersion | dismiss | retry}
                            │
                            ▼
                        SPUUpdater APIs + driver reply handlers
```

### Modifications to existing files

- **`TheAllApp.swift`**: instantiate `UpdateStore` (singleton in `@State`), inject via `.environment(...)`. Inside `#if !DEBUG`, schedule the 3 s post-launch silent check. Sparkle is SwiftPM-imported but only used here and inside `Update/`.
- **`Settings/SettingsSection.swift`**: add `case update`, label `"Update"`.
- **`Settings/Sections/UpdateSectionView.swift`** (new): renders the 7 UI states.
- **`Settings/SettingsView.swift`**: extend `sectionBody` switch with the new case. Add `initialSection: SettingsSection? = nil` init parameter; the view's `@State private var section` is seeded from it via `init` (`_section = State(initialValue: initialSection ?? .appearance)`). When Settings is already open and the notification fires again, also observe `.theAllOpenSettings` inside `SettingsView` and update `section` to the new `userInfo["section"]` value (so re-clicking the version number from sidebar jumps to `.update` even if Settings is already visible).
- **`ContentView.swift`**: when handling `.theAllOpenSettings`, read `userInfo["section"]` as `String`, convert via `SettingsSection(rawValue:)`, and thread into `SettingsView(initialSection:)` on the next open. If Settings is already open, just re-post — `SettingsView` handles it internally per above.
- **`Sidebar/SidebarView.swift`**: footer replaced per §User-Visible Behavior. Takes `updateStore: UpdateStore` as a parameter (injected from `ContentView`).
- **`Theme/AppTheme.swift`**: reuse the existing `danger: NSColor` token (already defined for terminal status icons). Used for the pulsing dot, the `.error` card border, and the `Skip This Version` / destructive button affordances. No new token needed.

## Dependency Integration

### `project.yml`

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"

targets:
  TheAll:
    dependencies:
      - package: Sparkle
        product: Sparkle
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_KEY_SUFeedURL: "https://github.com/AbadOrangeCat/TheALL/releases/latest/download/appcast.xml"
        INFOPLIST_KEY_SUPublicEDKey: "REPLACE_WITH_SPARKLE_ED_PUBKEY"   # filled during First Release Bootstrap below, before any tag push
        INFOPLIST_KEY_SUEnableAutomaticChecks: "YES"
        INFOPLIST_KEY_SUScheduledCheckInterval: "86400"
```

After editing `project.yml`, run `xcodegen generate` once (pre-authorized in `CLAUDE.md` Agent Permissions).

### EdDSA key management

- Generate once locally: `Sparkle.framework/Versions/B/Resources/generate_keys`. Tool stores the private key in macOS Keychain.
- Public key: base64 string, hardcoded into `INFOPLIST_KEY_SUPublicEDKey` in `project.yml`. Can be committed (it is public).
- Private key: exported from Keychain once, added to the repository's GitHub Actions secrets as `SPARKLE_ED_PRIVATE_KEY`. Never committed, never echoed in logs.
- Key rotation: do not rotate. Rotating the key orphans all previously installed builds (they cannot verify the new signature → refuse to update). Treat the pair as permanent.

## Release Workflow

### `.github/workflows/release.yml` (new)

Trigger: push of a tag matching `v*.*.*`. Does not fire on branch pushes — avoids accidental releases, and respects the CLAUDE.md rule of not pushing to master.

Steps:

1. Checkout repository.
2. Run `./scripts/build-vendor.sh` to produce `Vendor/ghostty/lib/libghostty.a`.
3. Install XcodeGen (`brew install xcodegen`) and run `xcodegen generate`.
4. Build arm64 Release: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Release -arch arm64 build`.
5. Package: use `create-dmg` (Homebrew) to produce `theall-{version}-arm64.dmg` from the built `.app`.
6. Ad-hoc code-sign the `.app` inside the DMG (`codesign --force --deep --sign -` applied before packaging).
7. EdDSA-sign the DMG: `Sparkle/bin/sign_update theall-{version}-arm64.dmg` — produces a base64 signature and byte length, read from stdout.
8. Generate changelog for this release: `git-cliff --latest --strip all` — Markdown text.
9. Render `appcast.xml` from template (see below), substituting version, tag, signature, length, pubDate, and CDATA-wrapped changelog.
10. Publish: `gh release create v{version} theall-{version}-arm64.dmg appcast.xml --title "v{version}" --notes-file CHANGELOG.md`.

### `appcast.xml` template

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>theall</title>
    <item>
      <title>Version {VERSION}</title>
      <pubDate>{RFC_822_DATE}</pubDate>
      <description><![CDATA[{CHANGELOG_MARKDOWN}]]></description>
      <enclosure
        url="https://github.com/AbadOrangeCat/TheALL/releases/download/v{VERSION}/theall-{VERSION}-arm64.dmg"
        sparkle:version="{BUILD_NUMBER}"
        sparkle:shortVersionString="{VERSION}"
        sparkle:edSignature="{ED_SIGNATURE_BASE64}"
        length="{BYTE_LENGTH}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

The single-item channel is intentional — new releases overwrite, the GitHub Releases page carries history.

### Human release procedure

```bash
# Verify tests pass locally
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests

# Bump CURRENT_PROJECT_VERSION manually in project.yml, regenerate, commit
# (MARKETING_VERSION bumps when the release adds user-visible features)

# Tag + push — triggers the workflow
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

### First release bootstrap (one-time, pre-CI)

1. Run `generate_keys` locally, export keys.
2. Fill `INFOPLIST_KEY_SUPublicEDKey` in `project.yml`.
3. Add `SPARKLE_ED_PRIVATE_KEY` to GitHub repo secrets.
4. Merge the in-app Sparkle integration + workflow to master.
5. Tag `v0.1.0` and push.

## Error Handling

- Network failure (no connection, GitHub down, DNS failure) during check: `UpdateStore.state = .error(localizedDescription)`. User sees red card + Retry.
- Appcast parse failure (malformed XML, missing required fields): Sparkle reports `SPUUpdaterDelegate.updater(_:didAbortWithError:)` → state becomes `.error`. Same UI.
- EdDSA signature mismatch on downloaded DMG: Sparkle refuses to install, fires error callback → `.error("Signature verification failed")`. User sees red card; retry re-downloads.
- Download interrupted mid-flight: driver sees `SPUDownloadDriver` failure, `.error`; retry restarts the download from zero (no resume).
- Silent launch check failure: swallow — set state to `.error` without forcing any UI change. Sidebar dot stays off. The next manual check will show the error inline.

## Testing Strategy

### Unit tests (`TheAllTests/`)

- `UpdateStoreTests`: exhaustive state-transition coverage. Given event → assert next state. Cover all 7 states and their valid transitions (and assert illegal transitions are no-ops, not crashes).
- `UpdateUserDriverTests`: stub `SPUUserDriver` protocol call sequence (showNewUpdate / downloadProgress / readyToInstall / etc.), assert `UpdateStore` mutates correctly.
- `AppcastParsingTests`: feed hand-crafted appcast XML fixtures through Sparkle's `SUAppcast` parser (if exposed) or through our driver's resolved `SUAppcastItem`; assert version / signature / notes extraction.

### Manual QA (new section in `docs/testing.md`)

1. Set `MARKETING_VERSION=0.0.9` locally, build Release.
2. Install the 0.0.9 build over an existing `v0.1.0` install (or vice versa).
3. Launch the app. Within ~3 s, sidebar red dot lights.
4. Click the version number. Settings opens on the Update section showing `Version 0.1.0 is available` and the release notes.
5. Click `Download & Install`. Progress 0–100%, then app quits and relaunches. After relaunch, version shows `v0.1.0`; red dot is gone.
6. Repeat steps 1–3. Click `Skip This Version`. Red dot clears. Close app, reopen — red dot does **not** reappear for 0.1.0. Publish a 0.1.1 (test) release; red dot reappears for it.
7. Disconnect network, click `Check for Updates` manually. Red error card appears with a Retry button.

### Debug-build sanity

Verified by code inspection + a one-liner unit test: assert `SparkleBridge.shared` is a no-op stub in Debug builds (the class exposes an `isActive: Bool` returning `false` under `#if DEBUG`, `true` otherwise; test asserts `false` when running the test target). No live-network check needed.

## Documentation Updates

Same PR as the implementation:

- `CLAUDE.md` / `AGENTS.md`: add `Update/` to the Directory Structure tree; add a row to Common Tasks for "Tune auto-update behavior".
- `docs/architecture.md`: add an Update section describing the SparkleBridge / UserDriver / Store relationship and the data flow diagram.
- `docs/settings-reference.md`: document the Update section (no config keys, but list the Sparkle-managed keys `SULastCheckTime`, `SUSkippedMinorVersion`, etc., and note they live in `UserDefaults`, not theall's config file).
- `docs/testing.md`: the manual QA section above.
- `docs/build.md`: add a Release subsection covering the tag-push workflow, `generate_keys` bootstrap, and where to find the private key.
- Run `./scripts/check-doc-drift.sh` before committing.

## Open Items (deferred)

- Developer ID signing + notarization to drop the Gatekeeper first-open warning.
- Universal binary (add x86_64 slice).
- Beta channel with a second appcast URL.
- In-app "Release History" page showing all prior versions (would need cumulative appcast or on-demand GitHub Releases API fetch).
