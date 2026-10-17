# Protocol porting

The TypeScript builders in `src/lib/protocol` remain the parity reference. A Swift
driver must produce the same bytes for the same model and must not infer a new
command from a similarly named controller.

1. Add a value-type driver in `Sources/LEDUnionCore/ProtocolDrivers.swift`.
2. Add fixture tests under `Tests/LEDUnionCore` for red, green, blue, purple,
   boundaries and the family envelope.
3. Run the Java/TypeScript differential harness for the existing family.
4. Record whether a capability is protocol-derived or physically confirmed in
   `docs/BLE-CAPABILITIES.md`.

For MELK-OF21 9D the first frame is fixed: `7e 07 05 03 rr gg bb 10 ef`.
Write without response is used with a 5 ms minimum gap. A command that has not
been observed on the target hardware remains an experimental diagnostic action.
