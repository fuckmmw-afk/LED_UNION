# BLE capability matrix

| Family | Service / write | Core status | Physical status |
|---|---|---|---|
| MELK / ELK | FFF0 / FFF3 | RGB, power, brightness, speed, effects, scenes | RGB transport confirmed for MELK-OF21 9D; remaining commands need a strip test |
| LEDBLE / DMX / CAR | FFE0 / FFE1 | Existing builders migrated; layouts retained | Confirmed only where the original project says so |
| LEDSMART / LEDSUN / LEDLIKE / LEDPHO | FFE0 / FFE1 | Existing builders migrated | Requires device matrix tests |
| BLEDIM | FFF0 / FFF1 | Variable packet and checksum driver | Requires hardware test |

Capabilities are derived from the advertised name and selected driver. W/CCT is
not shown for an RGB-only controller. MELK does not claim individual LED
addressing. Notification/state query remains diagnostic until a real device
returns a reliable response.

Native BLE uses the restoration identifier `fun.fuckmmw.ledunion.ble`. iOS can
restore a process for CoreBluetooth events, but a user force-quitting the app is
not promised a relaunch.
