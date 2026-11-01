<img src="Support/icon.png" alt="linkboy" width="128" height="128">

# linkboy

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-555)
![Swift](https://img.shields.io/badge/swift-6-F05138?logo=swift&logoColor=white)
[![License](https://img.shields.io/github/license/lockyc/linkboy)](LICENSE)

A fast, keyboard-driven macOS reader for link-aggregator feeds (Lobsters, Hacker News) on
[Miniflux](https://miniflux.app). Each item is its linked page plus its comments, in logged-in web
views, so you can vote and reply without leaving the app. No animations, and the list never
reorders under you: items you have read stay in place until you refresh.

## Requirements

- macOS 14 or later.
- Miniflux 2.0.49 or later (the first with the `changed_after` entries filter) and an API key:
  in Miniflux, **Settings → API Keys → Create a new API key**. linkboy asks for the server URL and
  key on first launch and keeps the key in the Keychain. The server must be `https://`; plain
  `http://` is accepted only for a local server (`localhost`, a `.local` name or an IP address).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lockyc/linkboy/main/install.sh | bash
```

Installs the notarized app to `/Applications/linkboy.app`. It updates itself afterwards
(**linkboy → Check for Updates…**).

## Keyboard

| Key | Action |
|---|---|
| `j` / `k` | Next / previous item |
| `c` | Toggle page / comments |
| `s` | Star |
| `u` | Mark read / unread |
| `o` | Open in the default browser |
| `⌘[` / `⌘]` | Back / forward in the focused view (fixed) |
| `⌘R` | Sync now (fixed) |

`j`, `k`, `c`, `s`, `u` and `o` are rebindable in Settings and work while a web page has focus,
except when you are typing in one of its fields. Mouse side buttons go back and forward in the view
under the pointer, and ⌘-click opens a link in the default browser. **Item → Mark All as Read…** has
no key: it asks first, naming the count, and `⌘Z` undoes it.

## Status

Pre-1.0 and not yet released; the first release will be v0.1.0.

## Build & test

Needs Xcode's Swift 6 toolchain and [`just`](https://github.com/casey/just).

```bash
just test     # unit tests
just gate     # build + tests + shellcheck
just run      # build and launch build/linkboy.app
```
