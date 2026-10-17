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
