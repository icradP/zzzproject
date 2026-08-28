# ZZZ IM

A Flutter-based instant messaging client styled after Zenless Zone Zero. It supports the bundled ZZZ Server protocol and [OneBot v11](https://github.com/botuniverse/onebot-11) backends such as [NapCatQQ](https://github.com/NapNeko/NapCatQQ) and [LLOneBot](https://github.com/LLOneBot/LLOneBot).

## Features

- **OneBot v11 protocol** — Full SDK with forward/reverse WebSocket, HTTP, and HTTP POST event server
- **Persistent chat history** — SQLite-backed message store with media cache
- **Rich media support** — Images, voice, video, emoji reactions, reply quotes
- **iOS PWA client** — Installable from Safari without an Apple Developer account
- **Web Push** — VAPID notifications without an APNs or FCM dependency
- **ZZZ Server** — Go WebSocket server with memory, SQLite, or PostgreSQL storage
- **Contact & group management** — Friend list, group member list, avatar caching
- **Customizable UI** — ZZZ-style animated backgrounds, configurable backdrop text, animation toggles
- **Storage control** — Configurable media/database directories with data migration
- **Desktop-first** — Windows support via `sqflite_common_ffi`

## Getting Started

```bash
# Clone
git clone https://github.com/icradp/zzzproject
cd zzzproject

# Install dependencies
flutter pub get

# Run on Windows
flutter run -d windows
```

Then configure your OneBot connection in **Settings** → **Connection** (point it at your NapCatQQ / LLOneBot WebSocket endpoint).

## PWA and ZZZ Server

Generate a VAPID key pair and start the server:

```bash
cd server
go run ./cmd/vapid

export ZZZ_VAPID_PUBLIC_KEY='<generated public key>'
export ZZZ_VAPID_PRIVATE_KEY='<generated private key>'
export ZZZ_VAPID_SUBJECT='mailto:admin@example.com'
go run ./cmd/server -addr :8080
```

Build the PWA for GitHub Pages:

```bash
flutter build web --release --base-href /zzzproject/
```

Web Push on iOS requires iOS 16.4 or later, HTTPS, and installation to the Home Screen. The GitHub Actions workflow tests Flutter and Go on pull requests and deploys the PWA after a successful push to `master`. Deploying the Go server requires a separate HTTPS/WSS hosting target.

## Architecture

```
lib/
├── src/
│   ├── app/          # App entry & wiring
│   ├── im/
│   │   ├── adapters/ # OneBot protocol adapter (NoneBotSource)
│   │   ├── data/     # SQLite store, media cache, configs
│   │   ├── models/   # ImMessage, ImConversation, ImUser
│   │   ├── pages/    # Settings, home page
│   │   └── widgets/  # Chat bubbles, conversation list, member panel
│   ├── theme/        # ZZZColors & styling
│   └── widgets/      # Shared components (ZzzPanel, ZzzTextInput, etc.)
└── packages/
    └── onebot_flutter/  # Standalone OneBot v11 Dart/Flutter SDK
```

## Credits

This project is based on **[ZZZ-Chat](https://github.com/AKindWorld/ZZZ-Chat)** by [AKindWorld](https://github.com/AKindWorld) — a beautiful ZZZ-themed chat simulator. We've extended it with a complete OneBot protocol integration, persistent storage, and full IM functionality.

Special thanks to:
- [botuniverse/onebot-11](https://github.com/botuniverse/onebot-11) — OneBot v11 protocol specification
- [NapNeko/NapCatQQ](https://github.com/NapNeko/NapCatQQ) — OneBot implementation for QQ

## License

MIT
