# Architecture

The app is a Capacitor shell around the existing Svelte UI. Native protocol and
Bluetooth work lives in the `LEDUnionCore` Swift package. `LEDNativeBLE` exposes
typed operations and events to the WebView; it does not expose a Web Bluetooth
object or let the UI pick GATT characteristics.

```text
Svelte components -> typed LEDNativeBLE plugin -> DeviceManager
                                                   -> CommandQueue per device
                                                   -> ProtocolDriver -> BLETransport
                                                   -> LEDStore (atomic Codable JSON)
App Intents --------------------------------------^              |
                                                             scenes/groups/looks
```

`BLETransport` is main-actor isolated because CoreBluetooth delegates are
callback based. The queue is an actor and is the only writer for a connection.
RGB and brightness updates use coalescing keys; scene uploads and handshakes are
ordered commands. `LEDStore` is the shared source for UI and App Intents.

The PWA keeps its existing Web Bluetooth implementation for desktop/Android. The
native path is selected by Capacitor, so iOS never relies on Web Bluetooth.
