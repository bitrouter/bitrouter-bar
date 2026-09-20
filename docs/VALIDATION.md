# Local acceptance evidence

Date: 2026-09-19  
Platform: macOS 26, arm64, Swift 6.2.4

This run used a local development build of BitRouter and an isolated temporary BitRouter home. The request used for the sample had already completed before UI validation; the UI checks did not issue another inference request.

## Verified behavior

- The panel showed **Codex — Today 16,864** from settled BitRouter metering data.
- Expanding Codex showed one opaque root-session row with **16,864** tokens. No conversation content was displayed.
- The associated Codex account moved from its pending state to an available **Weekly: 87% remaining** window.
- Manual Refresh completed and reset the visible update age to zero seconds.
- Closing and reopening the QA host retained the same app process and reloaded the live panel data.
- The app-only acceptance image is saved locally at `dist/acceptance-panel.png`. It contains aggregate usage and a generic account label, with no credentials, provider tokens, request text, or logs.

The accessibility automation environment could not bind directly to the transient status-item popover. Visual inspection therefore used a **DEBUG-only QA window hosting the exact same `PanelView` at the same 380 × 480 point size**. This proves the rendered content and controls, but it is not evidence that automated clicking of the actual menu-bar icon succeeded. Release builds compile out the QA window and screenshot hooks and remain menu-bar-only.

## Resource spot samples

These are short Activity Monitor-equivalent process samples, not a long-duration energy or leak measurement.

| State | PID | CPU samples | RSS samples |
| --- | ---: | --- | --- |
| Panel open | 49224 | 0.5%, 0.3%, 0.4% | 81,952 KiB, 81,712 KiB, 81,584 KiB |
| Panel closed | 49224 | 0.0%, 0.0%, 0.3% | 79,488 KiB, 79,488 KiB, 79,568 KiB |

The BitRouter daemon was left running. Only the BitRouter Bar process launched for QA was stopped afterward.

## Automated checks

`scripts/test.sh` covers the versioned JSON contract, fractional RFC 3339 timestamps, DST day bounds, pagination merge and deduplication, immediate child exit, bounded forced termination, structured errors, expired snapshots, incompatible schemas, malformed duplicate IDs, panel-close cancellation, refresh races, slow reads across poll intervals, and preservation of loaded pages across automatic poll intervals.

The release target builds successfully, and `scripts/package-app.sh` produces an arm64 ad hoc signed app that passes strict `codesign` verification.

The local candidate archive is `dist/BitRouter-Bar-0.1.0-macos-arm64.zip` with SHA-256 `c5b067d439150afd88656cff182e38481ea9e95c40fb73ca2d9d62add9a817cf`. It is an ad hoc signed verification artifact. Developer ID signing, notarization, and public release remain pending.
