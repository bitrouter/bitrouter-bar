# Native menu candidate 0.1.1

The reviewed design is implemented as a real AppKit `NSStatusItem` and `NSMenu`. The fixed-height popover, large header/buttons, inline session expansion, and DEBUG mirror window have been removed.

- Client rows open native session submenus. Values use compact notation (16,864 → 16.9K), with exact values in tooltips and accessibility text.
- Quota rows are small read-only views with a thin indicator and compact remaining value. Actual backend labels such as `Codex · Weekly · primary` become `Weekly quota`. Single unambiguous account names are hidden; multiple, shared, and unknown accounts remain distinguishable.
- Stale usage is muted; the status row preserves the last-update age. Failed pagination has a separate status and does not invalidate the already loaded usage.
- Refresh and Quit use native commands and keyboard shortcuts. Explicit Refresh and Load More finish one read after native dismissal. The next opening preserves newly loaded pages; manual refresh, a later opening, and midnight resume fresh totals.
- Parent items and submenus retain identity while data updates. Existing client order stays stable during tracking. Old cached items are pruned while the menu is closed.

## Verification

`scripts/test.sh` passed, including pure formatting, process cancellation, page preservation/midnight, both native close/action callback orders, and tests of the actual `NSMenu` object hierarchy and command selectors. The tests verify async snapshot rendering, submenu-close isolation, native shortcuts, stable submenu identity, nonzero compact quota frames, accessible text, and Load More after dismissal.

Release build, strict ad hoc signature verification, and archive integrity checks passed. The candidate is `dist/BitRouter-Bar-0.1.1-macos-arm64.zip`.

SHA-256: `ddaebf0f27f3b599bbcf85e06a96dab0cc5ba1dcd0713daabf786ecca783c63e`

Automated computer use could not bind to the accessory app's transient menu. Actual pointer/keyboard interaction during menu tracking, visual appearance, and VoiceOver output remain manual review checks; no replacement window is used as evidence for the new UI.

## Disconnection fix

The earlier review screenshot exposed a reproducible backend defect: closing a panel CLI before reading its IPC response caused a broken pipe to escape the accept loop and stop the whole daemon. BitRouter commit `e3a91642` isolates individual connection errors and preserves explicit Stop semantics even when the caller disconnects.

A regression verifies abandoned panel reads, malformed requests, and abandoned Stop acknowledgements. All **3,478 backend tests passed**, with **22 configured skips**. Strict all-targets Clippy, formatting, and diff checks passed. The patched review daemon also survived **20 real abandoned IPC reads**, then answered Status with the same PID.

## Review launch

The candidate is launched through macOS Launch Services with the isolated review home and the compatible `bro` binary. The review daemon uses `bro start` so it is detached. Both are deliberately left running for review; the pre-existing installed BitRouter service is unchanged. This does not add daemon management to the app.

Public release, Developer ID signing, and notarization remain pending.
