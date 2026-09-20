# Local acceptance evidence

This records the original 0.1.0 popover. For the replacement native menu, see [NATIVE_MENU_REVIEW.md](NATIVE_MENU_REVIEW.md).

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

After final verification, both the temporary acceptance daemon and the QA app were stopped. The pre-existing installed BitRouter daemon was left running.

## Automated checks

`scripts/test.sh` covers the versioned JSON contract, fractional RFC 3339 timestamps, DST day bounds, pagination merge and deduplication, immediate child exit, bounded forced termination, structured errors, expired snapshots, incompatible schemas, malformed duplicate IDs, panel-close cancellation, refresh races, slow reads across poll intervals, and preservation of loaded pages across automatic poll intervals.

The release target builds successfully, and `scripts/package-app.sh` produces an arm64 ad hoc signed app that passes strict `codesign` verification.

The local candidate archive is `dist/BitRouter-Bar-0.1.0-macos-arm64.zip` with SHA-256 `4591044efe0843d3cb5d8441e902db020a1c70e093e8bf27a0e28943c4530e56`. It is an ad hoc signed verification artifact. Developer ID signing, notarization, and public release remain pending.

## Backend verification

The companion backend is committed separately in BitRouter as `80dc808d` on `codex/bitrouter-bar-mvp`. The UI uses schema version 1 rather than depending on that commit; the currently installed older BitRouter binary does not yet provide this command.

- `cargo nextest run --all-features --no-fail-fast -j 4`: **3,477 passed, 22 skipped** by repository configuration.
- `cargo clippy --all-features --all-targets -- -D warnings`: passed.
- `cargo fmt -- --check` and `git diff --check`: passed.
- Workspace doc tests: **5 passed, 1 ignored**; strict workspace rustdoc also passed.
- The routed HTTP → settlement → owner IPC → `bro panel` integration test passed. Coverage includes complete totals beyond display pagination, normalized cache/reasoning counts, shared-account attribution, unknown account isolation, snapshot stability, and quota error/stale handling.

The real request was run through the native Codex ACP harness and returned `OK`. Its settled client and root-session totals matched at 16,864 tokens. A final backend recheck returned the same usage and a current Codex weekly quota of 86% (the earlier UI sample was 87%; account quota changes with other usage). Reset semantics remain unknown and are labelled accordingly.

The user selected the current Codex account for first acceptance and explicitly accepted Claude quota being unavailable. No working Claude OAuth credential was present for a live quota check; no Claude quota support is claimed. Historical rows without credential-selection evidence remain account-unknown.

This is a local arm64 candidate, not a public release. Actual transient menu-bar clicking was not automated, and physical sleep/wake plus a long-running energy/leak soak remain manual follow-up checks. Those limits are separate from the passed live data and contract tests.
