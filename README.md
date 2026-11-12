<img src="Support/icon.png" alt="linkboy" width="128" height="128">

# linkboy

[![Release](https://img.shields.io/github/v/release/lockyc/linkboy?sort=semver&label=release)](https://github.com/lockyc/linkboy/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-555)
![Swift](https://img.shields.io/badge/swift-6-F05138?logo=swift&logoColor=white)
[![License](https://img.shields.io/github/license/lockyc/linkboy)](LICENSE)

A fast, keyboard-driven macOS reader for link-aggregator feeds (Lobsters, Hacker News) on
[Miniflux](https://miniflux.app). Each item is its linked page plus its comments, in logged-in web
views, so you can vote and reply without leaving the app. No animations, and the list never
reorders under you: items you have read stay in place until you refresh.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lockyc/linkboy/main/install.sh | bash
```

Needs macOS 14 or later. The installer downloads the latest release, checks that it is signed and
notarized, and installs `/Applications/linkboy.app`. linkboy then updates itself
(**linkboy → Check for Updates…** checks now).

## First run

linkboy needs a Miniflux server, 2.0.49 or later, and an API key: in Miniflux, **Settings → API
Keys → Create a new API key**. linkboy asks for the server URL and key on first launch and keeps
the key in the Keychain. The server must be `https://`; plain `http://` is accepted only for a
local server (`localhost`, a `.local` name or an IP address).

## Features

- **Page and comments.** Each item opens as its linked page; `c` flips to its comments. Pages and
  comments are prefetched, so moving through the list doesn't wait on the network.
- **Unread or starred**, with unread narrowable to one category, from the menu above the list.
- **Single pane or side by side** — the page and its comments one at a time, or next to each
  other. Settings also sets the list's width, font size and density.
- **Content blocking.** Settings → Content Blocking edits WebKit content-blocking rules (JSON,
  saved to `~/Library/Application Support/linkboy/content-rules.json`) applied to every page. A
  list that fails to compile leaves the previous rules active and says why.
- **Mark All as Read** (Item menu) asks first, naming the count, and `⌘Z` undoes it.
- **The mouse** — side buttons go back and forward in the view under the pointer, and ⌘-click
  opens a link in your default browser.

| Key | Action |
|---|---|
| `j` / `k` | Next / previous item |
| `c` | Toggle page / comments |
| `s` | Star |
| `u` | Mark read / unread |
| `o` | Open in the default browser |
| `⌘[` / `⌘]` | Back / forward in the focused view (fixed) |
| `⌘R` | Sync now (fixed) |

`j`, `k`, `c`, `s`, `u` and `o` are rebindable in Settings, and work while a web page has focus
except when you're typing in one of its fields.

## Status

In use, `0.x`. What's next: [docs/FOLLOWUPS.md](docs/FOLLOWUPS.md).

## Development

Needs Xcode's Swift 6 toolchain and [`just`](https://github.com/casey/just).

```bash
git clone https://github.com/lockyc/linkboy && cd linkboy
just test     # unit tests
just gate     # build, tests, shellcheck
just run      # build and launch build/linkboy.app
```

How it's built: [docs/architecture.md](docs/architecture.md). Conventions and the release process:
[CLAUDE.md](CLAUDE.md).

## License

MIT — see [LICENSE](LICENSE).
