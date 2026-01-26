# Glitcho

A standalone macOS SwiftUI app for ad-free Twitch streaming with a beautiful glass-style UI.

## ✨ Features

### 🎨 Beautiful Glass UI
- Modern glass-morphic design with backdrop blur effects
- Custom sidebar with improved navigation
- Smooth animations and hover effects
- Profile section with avatar display
- Live channel indicators with badges

### 🚫 Enhanced Ad Blocking
- **Network-level blocking** : Blocks ad domains and tracking requests
- **CSS filtering** : Hides ad elements and overlays
- **M3U8 playlist filtering** : Removes ad segments from video streams
- **Real-time monitoring** : Continuously removes ad elements
- **Multi-layer protection** : Inspired by uBlock Origin filtering rules

### 📺 Twitch Integration
- Clean, immersive viewing experience (no Twitch navigation bars)
- Following live channels sidebar
- Search functionality
- Auto-login support
- Transparent background integration

## 🏗️ Build

### Build a .app bundle

```bash
./Scripts/make_app.sh
```

The app bundle is created at `Build/Glitcho.app`.

### Development build

```bash
swift build
```

## 🐛 About the Name

**Glitcho** combines "Glitch" (the iconic Twitch mascot style) and "-o" for a unique, memorable name that evokes the Twitch experience without using their trademark.

## 📝 Notes

- **Version**: Update `APP_VERSION` (and optionally `APP_BUILD`) in `Scripts/make_app.sh`
- **Minimum macOS version**: To change, edit `LSMinimumSystemVersion` in `Scripts/make_app.sh`
- **Ad blocking**: Client-side implementation with multi-layer filtering
- **UI customization**: All glass effects and colors can be modified in `ContentView.swift`

## ⚠️ Disclaimer

**Glitcho** is an **unofficial application** created by independent developers.

- This application is **not affiliated with, endorsed by, or associated with** Twitch Interactive, Inc. or Amazon.com, Inc.
- "Twitch" and the Twitch logo are **trademarks** of Twitch Interactive, Inc.
- This app uses Twitch's public services in compliance with their Terms of Service
- For full legal information, see [DISCLAIMER.md](DISCLAIMER.md)

## 📄 License

MIT License

**Note**: The MIT license applies only to the code of this application. All Twitch trademarks and content remain the property of their respective owners.
