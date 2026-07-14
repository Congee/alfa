# 06 — Code Quality Standards

The bar is deliberately high. These are enforced expectations, not aspirations.

## Language & concurrency

- **Swift 6 language mode**, strict concurrency `complete`. No regressions to `minimal`/`targeted`.
- **Warnings are errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`). Fix, don't suppress.
- No `@unchecked Sendable`, `nonisolated(unsafe)`, force-unwrap of external data, or `try!` in shipping code without a
  one-line comment justifying why it is safe. Prefer making the unsafe case impossible.
- Concurrency state lives in `actor`s; UI is `@MainActor`. Values crossing boundaries are `Sendable`.

## Structure

- Pure protocol logic (`SonyProtocol`) stays free of CoreBluetooth/CoreLocation and Foundation-only where possible.
- Dependency direction is one-way: `App → AlfaGeotag → SonyBLE → SonyProtocol`.
- Public API is the minimum necessary; default to `internal`. Document every `public` symbol.

## Testing

- Framework: **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- Every pure encoder/decoder/parser in `SonyProtocol` has tests, including the documented worked examples and edge
  cases (negative coordinates, no-tz variant, malformed advertisement input).
- I/O layers get tests behind protocol seams (fake peripheral/central) where practical; never require real hardware in
  unit tests. Real-hardware validation is a documented manual procedure (see `05-battery-strategy.md`).
- `cd AlfaKit && swift test` must pass on the host with no device.

## Style & tooling

- **SwiftFormat** for formatting, **SwiftLint** for linting (configs at repo root once added). CI runs both.
- Naming: Apple API Design Guidelines. Bytes are `[UInt8]`; hex literals grouped to match the protocol tables in
  `03-ble-protocol.md`.
- Comments explain *why* and cite protocol offsets/sources; they never narrate *what* the next line does.

## Git & CI

- Small, focused commits; imperative subject lines. Never commit the generated `Alfa.xcodeproj`, `.build/`, or any
  firmware blob.
- `git push --force-with-lease` only, never `--force`. No `git reset --hard`.
- CI (Phase 1): `swift test` (host) + `xcodegen` + `xcodebuild build` (simulator) + SwiftLint/SwiftFormat checks.

## Reverse-engineering hygiene

- Clean-room: use only publicly documented protocol facts (cited in `07-references.md`); no decompiled Sony code and no
  Sony trademarks/assets in the app.
- Mark every low-confidence protocol fact (🔴/🟡) in code comments and never let one become a silent test oracle until
  verified on the A7R V.
