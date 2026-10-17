# LED Union development rules

## Scope

LED Union keeps the MIT licence and the original copyright notices. Do not copy
vendor applications, proprietary assets or source code. Protocol facts may be
implemented only from the documented builders, device observation and the
differential fixtures in `tools/difftest/`.

## Boundaries

- `Sources/LEDUnionCore` owns CoreBluetooth, protocol selection, frame builders,
  pacing, coalescing, cancellation, persistence and diagnostics.
- `Sources/LEDUnionIntents` owns App Intents and Shortcuts. Intents call the core;
  they never call JavaScript or the WebView.
- Svelte/TypeScript owns screens and presentation state. On iOS it calls the
  `LEDNativeBLE` Capacitor plugin. Web Bluetooth remains a desktop/PWA fallback.
- All shared models are `Codable`/`Sendable` and independent of SwiftUI and Svelte.

## Protocol rules

MELK-OF21 9D uses service `FFF0`, write `FFF3`, notify `FFF4`, write without
response, and the confirmed RGB frame `7E 07 05 03 RR GG BB 10 EF`. Keep the
frame tests for red, green, blue, purple and boundary values. Never present an
unconfirmed command as physically verified. CCT/W is exposed only when the
driver capability match permits it; individual LED addressing is not claimed
for MELK. New protocol work requires a fixture and a differential test.

## Build and delivery

The supported CI target is iOS 18.0+, bundle id `fun.fuckmmw.ledunion`, arm64,
unsigned. Run `npm test`, `npm run check`, `npm run build`, `swift test` and the
IPA structure checks before delivery. The workflow must use
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. Do not put deployment
secrets in URLs. VPS publication must upload to a temporary file, verify the
checksum, then atomically rename it and run `nginx -t` before reload.

## Unsupported claims

The iOS microphone mode analyses the microphone input with AVAudioEngine. It does
not capture Spotify, Apple Music or system audio. BLE background restoration is
best effort and force-quit relaunch is not guaranteed by iOS. Keep these limits
visible in UI and documentation.
