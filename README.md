<img src="Support/icon.png" alt="linkboy" width="128" height="128">

# linkboy

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-555)
![Swift](https://img.shields.io/badge/swift-6-F05138?logo=swift&logoColor=white)
[![License](https://img.shields.io/github/license/lockyc/linkboy)](LICENSE)

Fast, keyboard-driven macOS reader for link-aggregator feeds on Miniflux — each item's page and
its comments, in logged-in web views.

**Status:** early development (v0.1 in progress). Not yet released.

## Build & test

Needs Xcode's Swift 6 toolchain and [`just`](https://github.com/casey/just).

```bash
just test     # unit tests
just gate     # build + tests
just run      # build and launch build/linkboy.app
```
