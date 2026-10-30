---
type: architecture
links:
  - rel: covers
    to: Sources
  - rel: see-also
    to: README.md
    note: human-facing counterpart — what linkboy is and how to build it
---

# linkboy — agent notes

Fast, keyboard-driven macOS reader for link-aggregator feeds on Miniflux — each item's page and
its comments, in logged-in web views. Swift package, AppKit, macOS 14+. Early development (v0.1
in progress). The repo is public: tracked files carry no hostnames, usernames or machine paths.

## Layout

- `Sources/LinkboyCore/` — Foundation, GRDB and Security only; never AppKit, WebKit or SwiftUI.
  **Every unit test lives here.**
- `Sources/Linkboy/` — the AppKit executable (Sparkle for updates).
- `Tests/LinkboyCoreTests/` — XCTest, `swift test`.
- `Support/Info.plist` — bundle template; `just bundle` stamps `VERSION` into it.
- `Support/icon.svg` — icon master; `just icons` renders `AppIcon.icns` and `icon.png`.

## Invariants

- Bundle ID `com.lockyc.linkboy`, executable `Linkboy`, display name `linkboy`, Keychain service
  `com.lockyc.linkboy`; fixed from the first release.
- Miniflux native REST API (`/v1/…`, `X-Auth-Token`) only.
- No animations: no `NSAnimationContext` durations above 0, `animator()` proxies or implicit
  layer animations.
- Controls never move or disappear with state; unavailable means disabled in place with a tooltip.
- All web views share the one persistent `WKWebsiteDataStore.default()`.

## Build, test, verify, branches

- `just test`, `just gate`; `just run` builds and launches `build/linkboy.app`.
- Verify UI changes by running the app (`just run`) and confirming the window renders as intended.
- Branches: `main` + `dev`. Work lands on `dev`; a release fast-forwards `main` from `dev`.
- Version: the root `VERSION` file is the only source; `just bundle` stamps it into the bundle.
