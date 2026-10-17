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
text = package.read_text()
dependency = '.package(path: "../../../Sources/LEDNativeBLEPlugin"),'
if dependency not in text:
    text = text.replace(
        '.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "8.5.3")',
        '.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "8.5.3"),\n        ' + dependency
    )
product = '.product(name: "LEDNativeBLEPlugin", package: "LEDNativeBLEPlugin")'
if product not in text:
    text = text.replace(
        '.product(name: "Cordova", package: "capacitor-swift-pm")',
        '.product(name: "Cordova", package: "capacitor-swift-pm"),\n                ' + product
    )
text = text.replace('platforms: [.iOS(.v15)]', 'platforms: [.iOS(.v17)]')
text = text.replace('platforms: [.iOS(.v18)]', 'platforms: [.iOS(.v17)]')
package.write_text(text)

scene_text = scene.read_text()
if 'import LEDNativeBLEPlugin' not in scene_text:
    scene_text = scene_text.replace('import Capacitor\n', 'import Capacitor\nimport LEDNativeBLEPlugin\n')
old = 'window?.rootViewController = CAPBridgeViewController()'
new = 'let bridge = CAPBridgeViewController()\n        bridge.bridge?.registerPluginInstance(LEDNativeBLEPlugin())\n        window?.rootViewController = bridge'
scene_text = scene_text.replace(old, new)
scene.write_text(scene_text)
PY

/usr/libexec/PlistBuddy -c 'Add :NSBluetoothAlwaysUsageDescription string LED Union uses Bluetooth to control your lights.' ios/App/App/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string LED Union uses the microphone for the audio-reactive lighting mode.' ios/App/App/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes array' ios/App/App/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes:0 string bluetooth-central' ios/App/App/Info.plist 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
project = Path('ios/App/App.xcodeproj/project.pbxproj')
if project.exists():
    text = project.read_text()
    text = text.replace('PRODUCT_BUNDLE_IDENTIFIER = com.company.app;', 'PRODUCT_BUNDLE_IDENTIFIER = fun.fuckmmw.ledunion;')
    text = text.replace('IPHONEOS_DEPLOYMENT_TARGET = 15.0;', 'IPHONEOS_DEPLOYMENT_TARGET = 18.0;')
    text = text.replace('MARKETING_VERSION = 1.0;', 'MARKETING_VERSION = 1.0.0;')
    project.write_text(text)
PY
