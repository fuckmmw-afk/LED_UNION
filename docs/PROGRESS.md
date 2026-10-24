# Progress

## 2026-10-17

- Imported the MIT LED Union source repository and preserved `LICENSE` and source
  notices.
- Added `LEDUnionCore` Swift package models, MELK/FFE0/BLEDIM drivers, CoreBluetooth
  transport, command queue, color/effects engines, persistence and diagnostics.
- Added App Intents/Shortcuts target with device, scene and effect entities.
- Added Capacitor configuration, typed `LEDNativeBLE` API and native plugin shell.
- Added macOS GitHub Actions unsigned arm64 IPA workflow and local Swift Package
  bridge configuration for Capacitor 8.
- Added architecture, protocol, capability, build, delivery and device-test docs.
- Physical iPhone/MELK validation and VPS publication remain pending because this
  Linux runner has no Xcode, Swift toolchain, iPhone or VPS credentials.
- GitHub fork creation and protected VPS deployment require credentials for the
  destination accounts; the local repository and CI artifacts are ready for that
  handoff.

- Replaced the iOS WebView launch path with a native SwiftUI target (`LEDUnionApp`) covering device scan/connect, RGB controls, brightness, power, effects and diagnostics.
- Fixed GATT writes to retain every discovered writable characteristic and wait for the driver-declared UUID before reporting a connection. Queue write failures now reach the UI.

## 2026-10-25

- Connection rework: one `LEDRuntime` (single CBCentralManager) shared by the UI and
  App Intents; waits for Bluetooth power-on; 12 s connect timeout with three
  attempts; write-characteristic fallback; write-without-response flow control;
  automatic reconnection with 2–30 s backoff after an unexpected disconnect and when
  Bluetooth comes back. Previously a single lost link left the device failing every
  command until the app was relaunched.
- Native FFE0 frames now match the TypeScript builders byte for byte (effects,
  speed and several power frames were wrong). `tools/difftest/emit_swift_fixtures.ts`
  generates `Tests/LEDUnionCore/TSFrameFixtures.swift`; effect tables are generated
  into `Sources/LEDUnionCore/EffectTables.swift` by `tools/gen-effects.py`.
- Native UI: visible connection phases with progress, live colour/brightness,
  white/CCT, speed, full built-in effect tables, phone-side effects, microphone
  mode, scenes, rename/forget/auto-connect, shareable log.
- Shortcuts: intents run in the background, default to all devices, return a
  dialog. The AppShortcutsProvider moved to the app target because Xcode 16 does
  not extract it from a Swift package (the previous IPA had zero App Shortcuts).
- Still unverified on hardware: everything except the LEDBLE-00 colour path.
