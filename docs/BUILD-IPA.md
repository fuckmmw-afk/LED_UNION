# Build an unsigned IPA

The GitHub Actions workflow `.github/workflows/ios-unsigned.yml` runs the web
checks, creates the Capacitor iOS shell, links the local Swift packages, runs
Swift tests, and builds a generic arm64 iPhoneOS app with signing disabled.

For a local macOS build:

```sh
npm ci
npm run build:ios
bash tools/configure-ios-spm.sh
swift test
xcodebuild -project ios/App/App.xcodeproj -scheme App -sdk iphoneos \
  -destination 'generic/platform=iOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Package `Payload/Application.app` into an IPA only after checking the bundle id,
minimum OS, arm64 Mach-O, embedded frameworks, resources and App Intents. An
unsigned IPA needs a signing service such as SideStore/ESign before installation.
