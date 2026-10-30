---
type: architecture
links:
  - rel: part-of
    to: CLAUDE.md
    note: CLAUDE.md points here before changing how reading, keys or sync work
  - rel: covers
    to: Sources
---

# Architecture

The reading unit is a link plus its discussion: an entry's page and its comments, shown in web
views. Everything below the UI is `LinkboyCore`, platform-neutral so an iPhone app can reuse it;
`Sources/Linkboy` is the AppKit shell. Each symbol's own docblock owns its detail; this file holds
what spans them.

## Core / app split

`LinkboyCore` imports Foundation, GRDB and Security only. Anything that needs AppKit or WebKit
sits in `Linkboy` and takes its decisions from a Core function, so the decision is unit-tested:
`KeyRouter.route` (whether a key is an action), `LinkPolicy` (where a navigation goes),
`KeyBindings.pageKeys` (what the in-page script listens for), `MarkAllPlan`, `Snapshot`.

## Data flow

Miniflux (`MinifluxClient`, native `/v1` API, API key in the Keychain via `CredentialStore`) is
the source of truth. `Store` (SQLite) holds entries and a pending-change queue, so the list and
navigation never wait on the network. A local read or star writes the store and the queue
immediately; `SyncEngine` pushes the queue, then pulls changes. A pending local change wins
until the server acknowledges it; otherwise server state wins.

## The snapshot rule

The list being read is a `Snapshot`: entry IDs frozen when the list is taken. Reading an item
marks it read but leaves it in the snapshot, so previous always returns to it. Sync never edits
the snapshot; arrivals only raise `newCount` and join on an explicit re-take.

## Mark all

Never bound to a key (`Action` has no such case). `MarkAllPlan.plan(for:store:)` lists the
snapshot's still-unread IDs, the confirmation states that count and scope, and the write is
`PUT /v1/entries` with exactly that ID list, never the server's mark-all. `UndoLedger` restores
exactly that set to unread.

## Keys

Navigation keys must work while a page has focus and must never fire while the user types in a
page. Two paths share one rule (unmodified keys belong to an editable element; ⌘/⌃/⌥ combos
always route):

- App-side: `KeyRouter.route` with the focus state the app reports.
- In-page: `FocusProbe`'s capturing listener runs in every frame, in linkboy's own content
  world, and posts a bound key to the app only when the deepest focused element (through open
  shadow roots) is not a text control. `KeyBindings.pageKeys` supplies the key names.

## Web views

Page, comments and prefetch viewers are all `WebViewer`, sharing the one persistent
`WKWebsiteDataStore.default()`, so logins survive relaunches. ⌘-click and new-window requests go
through `LinkPolicy` to the default browser, which has its own separate logins. `Prefetcher`
loads the next item's page and comments offscreen with that same construction; it loads only the
item's own two URLs (GET, no forms), and `Snapshot.prefetchTargets` picks them. Content
blocking is a `WKContentRuleList` built from a user-editable rule source (`ContentBlocking`).

## No animation

Nothing animates: no `NSAnimationContext` duration above zero, no `animator()` proxies, no
implicit layer animation. Controls hold their place in every state; an unavailable one is
disabled in place with a tooltip.
