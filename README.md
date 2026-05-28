# ZZZ IM

A Flutter-based instant messaging client with [OneBot v11](https://github.com/botuniverse/onebot-11) protocol support, styled after Zenless Zone Zero. Connect to [NapCatQQ](https://github.com/NapNeko/NapCatQQ), [LLOneBot](https://github.com/LLOneBot/LLOneBot), or any OneBot-compatible bot backend.

## Features

- **OneBot v11 protocol** — Full SDK with forward/reverse WebSocket, HTTP, and HTTP POST event server
- **Persistent chat history** — SQLite-backed message store with media cache
- **Rich media support** — Images, voice, video, emoji reactions, reply quotes
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
