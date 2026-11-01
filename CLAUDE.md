---
type: architecture
links:
  - rel: covers
    to: Sources
  - rel: see-also
    to: README.md
    note: human-facing counterpart — what linkboy is and how to build it
  - rel: see-also
    to: docs/FOLLOWUPS.md
    note: deliberately deferred work
---

# linkboy — agent notes

Fast, keyboard-driven macOS reader for link-aggregator feeds on Miniflux — each item's page and
its comments, in logged-in web views. Swift package, AppKit, macOS 14+. Pre-1.0, unreleased until
v0.1.0. The repo is public: tracked files carry no hostnames, usernames or machine paths. Read
[docs/architecture.md](docs/architecture.md) before changing reading, keys, sync or web views.

**What's next:** `docs/FOLLOWUPS.md` — deliberately deferred work.

## Layout

- `Sources/LinkboyCore/` — Foundation, GRDB and Security only; never AppKit, WebKit or SwiftUI.
  Every decision the unit tests cover lives here; the AppKit target has no tests.
- `Sources/Linkboy/` — the AppKit executable (Sparkle for updates).
- `Tests/LinkboyCoreTests/` — XCTest, `swift test`.
- `Support/Info.plist` — bundle template; `just bundle` stamps `VERSION` into it.
- `Support/icon.svg` — icon master; `just icons` renders `AppIcon.icns` and `icon.png`.
- `install.sh` — the curl-pipeable installer (latest release's `linkboy.zip`, team ID and
  notarization checked); `.claude/commands/linkboy/install.md` drives it.

## Invariants

- Bundle ID `com.lockyc.linkboy`, executable `Linkboy`, display name `linkboy`, Keychain service
  `com.lockyc.linkboy`; fixed from the first release.
- Miniflux native REST API (`/v1/…`, `X-Auth-Token`) only.
- No animations; controls never move or disappear with state (unavailable means disabled in place
  with a tooltip); all web views share one persistent data store — see the architecture doc.

## Build, test, verify, branches

- `just test`, `just gate`; `just run` builds and launches `build/linkboy.app`.
- Verify UI changes by running the app (`just run`) and confirming the window renders as intended.
- Branches: `main` + `dev`. Work lands on `dev`; a release fast-forwards `main` from `dev`
  (`git merge --ff-only dev`). Docs-only changes may land on `main` and are forward-merged into
  `dev` immediately.
- Version: the root `VERSION` file is the only source; `just bundle` stamps it into the bundle. A
  release tags `v<VERSION>` and publishes a GitHub release with notes, `linkboy.zip` and the
  Sparkle `appcast.xml` that `SUFeedURL` reads. The release interface: `just gate`, `VERSION`,
  `just bundle` (signs with `APPLE_SIGNING_IDENTITY`, hardened runtime, nested Sparkle helpers
  re-signed; ad-hoc without it), the `app` and `info_plist` variables, `just sparkle-bin`.
