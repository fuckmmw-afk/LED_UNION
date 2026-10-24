import AppIntents

/// App Shortcuts must be declared in the app module itself: the metadata processor
/// ignores providers compiled into Swift packages. The intents stay in the package.
struct LEDUnionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnLEDOnIntent(),
                    phrases: ["Включи свет в \(.applicationName)", "Turn on lights in \(.applicationName)"],
                    shortTitle: "Включить", systemImageName: "lightbulb.fill")
        AppShortcut(intent: TurnLEDOffIntent(),
                    phrases: ["Выключи свет в \(.applicationName)", "Turn off lights in \(.applicationName)"],
                    shortTitle: "Выключить", systemImageName: "lightbulb.slash")
        AppShortcut(intent: ToggleLEDIntent(),
                    phrases: ["Переключи свет в \(.applicationName)", "Toggle lights in \(.applicationName)"],
                    shortTitle: "Переключить", systemImageName: "power")
        AppShortcut(intent: SetLEDColorIntent(),
                    phrases: ["Сделай \(\.$color) свет в \(.applicationName)",
                              "Поменяй цвет в \(.applicationName)",
                              "Set \(\.$color) light in \(.applicationName)"],
                    shortTitle: "Цвет", systemImageName: "paintpalette.fill")
        AppShortcut(intent: SetLEDBrightnessIntent(),
                    phrases: ["Измени яркость в \(.applicationName)", "Set brightness in \(.applicationName)"],
                    shortTitle: "Яркость", systemImageName: "sun.max.fill")
        AppShortcut(intent: StartLEDEffectIntent(),
                    phrases: ["Запусти эффект в \(.applicationName)",
                              "Start an effect in \(.applicationName)"],
                    shortTitle: "Эффект", systemImageName: "sparkles")
        AppShortcut(intent: ApplyLEDSceneIntent(),
                    phrases: ["Включи сцену \(\.$scene) в \(.applicationName)",
                              "Примени сцену в \(.applicationName)",
                              "Apply a scene in \(.applicationName)"],
                    shortTitle: "Сцена", systemImageName: "theatermasks.fill")
    }
}
