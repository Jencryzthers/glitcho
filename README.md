# Glitcho

Glitcho is a native macOS SwiftUI app for Twitch with a clean, focused interface, a custom sidebar, and a native playback pipeline.

## Why this project

Twitch retired its native macOS application. In my use case, the Electron client and browser playback path were frequently unstable, which motivated a native alternative. This project preserves the essential Twitch experience while routing playback through a macOS‑native player and maintaining a clean, distraction‑free interface. The focus is reliability and polish, with additional features planned over time.

## Features

- Native macOS interface with custom sidebar, search, and following list
- Embedded Twitch viewing experience with reduced web chrome
- Streamlink-based native playback via AVPlayer
- Profile section and account actions
- Focus on stability and a clean UI

## Requirements

- macOS 13 or later
- Streamlink CLI available at `/opt/homebrew/bin/streamlink` (default Homebrew path on Apple Silicon)

## Installation

Release assets are provided as a zipped `.app` bundle. Download the latest `Glitcho-vX.Y.Z-macOS.zip`, unzip it, and move `Glitcho.app` to `/Applications`.

If macOS Gatekeeper blocks the first launch, right‑click the app and choose **Open**, or remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine Glitcho.app
```

## Build and Run (from source)

```bash
./Scripts/make_app.sh
open Build/Glitcho.app
```

The app bundle is created at `Build/Glitcho.app`.

## Usage

1. Launch the app and sign in to Twitch (optional but required for Following).
2. Select a channel from **Following** or use search.
3. Use the native player view for playback.

## Configuration

- Version: update `APP_VERSION` and `APP_BUILD` in `Scripts/make_app.sh`
- Minimum macOS version: update `LSMinimumSystemVersion` in `Scripts/make_app.sh`
- UI customization: `Sources/Glitcho/ContentView.swift`
- Streamlink path: update `process.executableURL` in `Sources/Glitcho/StreamlinkPlayer.swift` if needed
- About window content: `Sources/Glitcho/App.swift`

## Known limitations

- Twitch DOM changes can break layout tweaks and Following list scraping.
- Following may appear empty until you visit the Twitch “Following” page once.
- Some channels require authentication to play.
- Streamlink must be installed and reachable at the configured path.

## Privacy

The app does not add additional analytics or telemetry. Twitch web content may collect data according to Twitch’s own policies.

## Troubleshooting

- **App does not launch**: re-run `./Scripts/make_app.sh` and confirm the build completes.
- **Gatekeeper warning**: right‑click and choose **Open**, or run the `xattr` command above.
- **Stream does not load**: confirm the channel is live, then reload (Cmd+R).
- **Following list is empty**: sign in, visit the Twitch “Following” page once, then wait a few seconds.
- **Streamlink not found**: ensure Streamlink is installed and adjust the path in `StreamlinkPlayer.swift`.
- **UI layout issues**: Twitch DOM changes can require selector updates in `Sources/Glitcho/WebViewStore.swift`.

## Development and contributing

- Prerequisites: Xcode Command Line Tools and Swift 5.9+
- Build using the script in `Scripts/make_app.sh`
- Keep changes focused; add notes to `CHANGELOG.md` for user‑visible updates

## Architecture overview

- `Sources/Glitcho/App.swift`: app entry point and About window
- `Sources/Glitcho/ContentView.swift`: sidebar layout and main UI structure
- `Sources/Glitcho/WebViewStore.swift`: WKWebView setup, styling injection, Following list and profile scraping
- `Sources/Glitcho/StreamlinkPlayer.swift`: Streamlink URL extraction and AVPlayer playback

## Legal and Attribution

Glitcho is an unofficial application and is not affiliated with, endorsed by, or associated with Twitch Interactive, Inc. or Amazon.com, Inc. “Twitch” and the Twitch logo are trademarks of Twitch Interactive, Inc.

## License

MIT License. The license applies to the code of this application. All Twitch trademarks and content remain the property of their respective owners.
