# Device test matrix

| Test | MELK-OF21 9D | LEDBLE/DMX | BLEDIM | Evidence |
|---|---:|---:|---:|---|
| scan and connect | required | required | required | iPhone log |
| RGB red/green/blue/purple | required | required | required | photo/video |
| reconnect after disconnect | required | required | required | diagnostics |
| power/brightness/speed | required | required | required | physical response |
| hardware effects/scenes | required | family-dependent | family-dependent | selected frame + photo |
| software effects timing | required | required | required | queue timing |
| groups and scenes | required | required | required | UI recording |
| microphone permission/audio reaction | required | n/a | n/a | permission state + log |
| Shortcuts foreground/background | required | required | required | Shortcuts result |
| force-quit/restoration | observe | observe | observe | iOS restoration log |
| ESign install and launch | required | required | required | signed install |

Protocol-derived behavior can be validated in CI. Rows marked required need an
iPhone and the named physical controller before release claims are updated.
