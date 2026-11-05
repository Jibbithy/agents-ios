# Agents

A native iOS app for chatting with self-hosted AI agents. It supports text and voice conversations, photo attachments, wake word detection, widgets and Live Activities, and approving agent actions from your phone.

Built with SwiftUI, AVFoundation, ActivityKit, WidgetKit and App Intents. Includes 403 unit tests.

**This is a portfolio project.** The app connects to a personal agent server that isn't in this repo, so it can't hold conversations without one. The wake word model isn't included either.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cp signing.yml.example signing.yml
xcodegen generate
open Agents.xcodeproj
```

Set your own Apple team in `signing.yml` to run it on a device.

## Run the tests

```bash
xcodebuild test -scheme Agents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

Change the simulator name to one you have installed.

## License

[MIT](LICENSE)

Third-party packages are covered by their own licenses.
