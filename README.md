# ZZZ IM

A Flutter-based instant messaging client styled after Zenless Zone Zero. It supports the bundled ZZZ Server protocol and [OneBot v11](https://github.com/botuniverse/onebot-11) backends such as [NapCatQQ](https://github.com/NapNeko/NapCatQQ) and [LLOneBot](https://github.com/LLOneBot/LLOneBot).

## Features

- **OneBot v11 protocol** — Full SDK with forward/reverse WebSocket, HTTP, and HTTP POST event server
- **Persistent chat history** — SQLite-backed message store with media cache
- **Rich media support** — Images, voice, video, emoji reactions, reply quotes
- **iOS PWA client** — Installable from Safari without an Apple Developer account
- **Web Push** — VAPID notifications without an APNs or FCM dependency
- **ZZZ Server** — Go WebSocket server with memory, SQLite, or PostgreSQL storage
- **Multi-source inbox** — Client-managed connection profiles with source-aware message routing
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

Then add one or more profiles in **Settings** → **Connections**. Desktop
clients can keep ZZZ Server and QQ/NoneBot profiles enabled at the same time;
the inbox labels each conversation by source and routes replies back to it.
Existing single-connection settings are migrated automatically.

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
flutter build web --release \
  --base-href /zzzproject/ \
  --dart-define=ZZZ_SERVER_URL=wss://im.example.com/ws
```

The server endpoint is build-time configuration and is not shown or editable
on the login page. For GitHub Actions, set the repository Actions variable
`ZZZ_SERVER_URL`; local builds fall back to `ws://localhost:8080/ws`.

Web Push on iOS requires iOS 16.4 or later, HTTPS, and installation to the Home Screen. The GitHub Actions workflow tests Flutter and Go on pull requests and deploys the PWA after a successful push to `master`. Deploying the Go server requires a separate HTTPS/WSS hosting target.

The ZZZ Server is intentionally platform-agnostic. It owns only ZZZ users,
devices, conversations, messages, media, and Web Push subscriptions. QQ and
other external platforms connect directly from supported clients through
local adapters; the server does not store or manage those platform tokens.
Because iOS suspends PWA WebSockets in the background, background push is
available for ZZZ Server messages, while client-only external sources resume
when the PWA returns to the foreground.

## Architecture

```
lib/
├── src/
│   ├── app/          # App entry & wiring
│   ├── im/
│   │   ├── adapters/ # Source registry, aggregate routing, ZZZ and OneBot adapters
│   │   ├── data/     # Connection profiles, SQLite store, media cache, configs
│   │   ├── models/   # ImMessage, ImConversation, ImUser
│   │   ├── pages/    # Settings, home page
│   │   └── widgets/  # Chat bubbles, conversation list, member panel
│   ├── theme/        # ZZZColors & styling
│   └── widgets/      # Shared components (ZzzPanel, ZzzTextInput, etc.)
└── packages/
    └── onebot_flutter/  # Standalone OneBot v11 Dart/Flutter SDK
```

```text
Flutter client
├── CompositeImRepository
│   ├── ZZZ Server profile -> HTTPS/WSS -> platform-agnostic ZZZ Server
│   └── NoneBot profile    -> OneBot WS -> QQ (desktop only)
└── Future client adapters can be registered without changing the server
```

## Credits

This project is based on **[ZZZ-Chat](https://github.com/AKindWorld/ZZZ-Chat)** by [AKindWorld](https://github.com/AKindWorld) — a beautiful ZZZ-themed chat simulator. We've extended it with a complete OneBot protocol integration, persistent storage, and full IM functionality.

Special thanks to:
- [botuniverse/onebot-11](https://github.com/botuniverse/onebot-11) — OneBot v11 protocol specification
- [NapNeko/NapCatQQ](https://github.com/NapNeko/NapCatQQ) — OneBot implementation for QQ

## License

MIT
