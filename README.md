# Claude Usage

A native macOS menu bar app with a futuristic HUD that shows the **same session
(5h) and weekly (7d) usage as Claude Code's `/usage`** — read live from
Anthropic's API.

- **Menu bar:** a dual-ring icon (outer = session, inner = week) + a compact `59·20` readout.
- **Click** for a frosted dark HUD with two animated neon gauge rings, reset countdowns, and a per-model breakdown on Max plans.

## How it works

`/usage` calls `GET /api/oauth/usage` with the OAuth token Claude Code keeps in
the macOS Keychain (`Claude Code-credentials`). This app reads that token
**read-only** (never refreshes/rotates it) and calls the same endpoint, so the
numbers are the real server-side percentages — not an estimate.

Polls every 2 min, caches the last result to disk, and backs off on HTTP 429.

## Build & run

```sh
./build.sh
open build/ClaudeUsage.app
```

Requires the Swift toolchain (Xcode / Command Line Tools); no other dependencies.

It registers itself as a **login item** on first launch — toggle with the `⏻`
glyph in the HUD (cyan = on). Keep the `.app` in a stable location, or move it to
`/Applications` and launch once from there.

## Files

- `Sources/main.swift` — the whole app (Keychain read, usage fetch, animated HUD)
- `Info.plist` — `LSUIElement` menu-bar-only bundle
- `build.sh` — compiles with `swiftc`, ad-hoc signs, assembles the `.app`
