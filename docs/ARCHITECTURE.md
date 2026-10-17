# Architecture

The iOS target is a native SwiftUI application. `LEDUnionApp` owns the root
scene and screens; it calls `DeviceManager` and never loads a WebView. The
Svelte/TypeScript app remains the desktop/PWA fallback and is not part of the
iOS launch path.

```text
SwiftUI screens -> NativeAppModel -> DeviceManager
                                      -> CommandQueue per device
                                      -> ProtocolDriver -> BLETransport
                                      -> LEDStore (atomic Codable JSON)
App Intents -------------------------^              |
                                                   scenes/groups/looks
```

`BLETransport` is main-actor isolated because CoreBluetooth delegates are
callback based. It discovers all writable characteristics and selects the
protocol-declared UUID (FFF3 for MELK, FFE1 for FFE0 families, FFF1 for
BLEDIM) before releasing `connect()`. The queue is the only writer for a
connection and reports write failures to the native UI. RGB and brightness
updates use coalescing keys; scene uploads and handshakes remain ordered.

The Capacitor bridge is retained only as a desktop/PWA compatibility target and
is not linked into the native iOS launch scene.
