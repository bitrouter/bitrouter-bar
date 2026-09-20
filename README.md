# BitRouter Bar

BitRouter Bar is a small native macOS menu bar companion for a local BitRouter installation. Its single popover shows settled token usage for today by client, root sessions on expansion, and account quota states supplied by BitRouter.

The reviewed MVP scope and acceptance criteria live in [docs/MVP.md](docs/MVP.md).
Recorded local acceptance evidence and its limits live in [docs/VALIDATION.md](docs/VALIDATION.md).

This repository contains only the UI client. It never opens BitRouter's database, reads provider credentials, refreshes OAuth tokens, or manages the daemon.

## Requirements

- macOS 14 or newer
- Swift 6.2 for source builds
- A BitRouter version that supports the versioned `bro panel` command

The app finds `bro` in `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.local/bin`, `$HOME/.cargo/bin`, or the app process's `PATH`. Tests and development runs may set `BITROUTER_BAR_BRO_PATH` to an absolute executable path. The app starts `bro` directly without a login shell.

## Build and test

```sh
scripts/test.sh
swift build -c release
```

Create an ad hoc signed local app bundle:

```sh
scripts/package-app.sh
open "dist/BitRouter Bar.app"
```

`scripts/run-app.sh` packages a debug build and opens it. The app is an accessory process, so it appears only in the menu bar. Use the popover's Quit button or Command-Q to exit.

## Data contract

While the popover is open, the app runs:

```text
bro panel --since <RFC3339> --until <RFC3339> --session-limit 100 --session-offset <N>
```

The bounds are the current local natural day and therefore account for daylight-saving changes. Refresh replaces usage totals with the backend result. “Load more sessions” keeps the same bounds, requests the next offset, and appends sessions after deduplicating their opaque IDs. Client totals always come from the backend's complete aggregate.

The process is cancelled when the popover closes, times out after eight seconds, and accepts at most 1 MiB from each output stream. A previous successful result remains visible with a stale marker after a later failure. Arbitrary command stderr is never rendered.

## Packaging

Local bundles are ad hoc signed for direct verification. The manual **Package candidate** workflow builds and uploads an ad hoc signed zip as a CI artifact; it does not publish a release. Developer ID signing, notarization, versioning, and release publication should be added when distribution begins.

Quota support is only complete when the local BitRouter backend maps the actual selected upstream account and returns verified quota windows. Mock data is useful for UI tests but does not satisfy the product acceptance criteria.

Licensed under Apache-2.0. See [LICENSE](LICENSE).
