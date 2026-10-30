You are installing or updating **linkboy** — a keyboard-driven macOS reader for Miniflux link feeds.

## 1. Check the Mac

```bash
sw_vers -productVersion
```

linkboy needs macOS 14 or later. On an older Mac, say so and stop.

## 2. Install

From a linkboy checkout (`[ -f install.sh ] && [ -f Package.swift ]`), ask with AskUserQuestion:
- **Latest release** (recommended): `bash install.sh`
- **This checkout's code**: `just install`

Outside a checkout, run `curl -fsSL https://raw.githubusercontent.com/lockyc/linkboy/main/install.sh | bash`.

If the installer needs `sudo`, the user types their password in this session: suggest `! <the command>`.

## 3. Check it is running

```bash
pgrep -x Linkboy && /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/linkboy.app/Contents/Info.plist
```

Expect a process id and the installed version.

## 4. Done

Report the version. On first launch linkboy asks for a Miniflux server URL and an API key (Miniflux → Settings → API Keys). It updates itself; **linkboy → Check for Updates…** checks now.
