#!/usr/bin/env bash
set -euo pipefail

package="ios/App/CapApp-SPM/Package.swift"
scene="ios/App/App/SceneDelegate.swift"
test -f "$package"
test -f "$scene"

python3 - "$package" "$scene" <<'PY'
from pathlib import Path
import sys

package = Path(sys.argv[1])
scene = Path(sys.argv[2])
text = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapApp-SPM",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CapApp-SPM", targets: ["CapApp-SPM"])
    ],
    dependencies: [
        .package(path: "../../../")
    ],
    targets: [
        .target(
            name: "CapApp-SPM",
            dependencies: [
                .product(name: "LEDUnionApp", package: "LED_UNION"),
                .product(name: "LEDUnionIntents", package: "LED_UNION")
            ]
        )
    ]
)
"""
package.write_text(text)

scene_text = """import SwiftUI
import UIKit
import LEDUnionApp

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let model = NativeAppModel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        NativeAppModel.refreshShortcuts = { LEDUnionShortcuts.updateAppShortcutParameters() }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: NativeRootView(model: model))
        self.window = window
        window.makeKeyAndVisible()
    }
}
"""
scene.write_text(scene_text)
PY

/usr/libexec/PlistBuddy -c 'Add :NSBluetoothAlwaysUsageDescription string LED Union uses Bluetooth to control your lights.' ios/App/App/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string LED Union uses the microphone for the audio-reactive lighting mode.' ios/App/App/Info.plist 2>/dev/null || true
if ! /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' ios/App/App/Info.plist 2>/dev/null | grep -q bluetooth-central; then
  /usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes array' ios/App/App/Info.plist 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes:0 string bluetooth-central' ios/App/App/Info.plist
fi

python3 - <<'PY'
from pathlib import Path
project = Path('ios/App/App.xcodeproj/project.pbxproj')
if project.exists():
    text = project.read_text()
    text = text.replace('PRODUCT_BUNDLE_IDENTIFIER = com.company.app;', 'PRODUCT_BUNDLE_IDENTIFIER = fun.fuckmmw.ledunion;')
    text = text.replace('IPHONEOS_DEPLOYMENT_TARGET = 15.0;', 'IPHONEOS_DEPLOYMENT_TARGET = 18.0;')
    text = text.replace('MARKETING_VERSION = 1.0;', 'MARKETING_VERSION = 1.0.0;')
    # Capacitor may re-add its web resources during cap sync. The native launch
    # scene must not package or load the Svelte/WebView bundle.
    web_markers = ('config.xml', 'capacitor.config.json', 'public in Resources', 'path = public;')
    text = '\n'.join(line for line in text.splitlines() if not any(marker in line for marker in web_markers)) + '\n'
    project.write_text(text)
PY
