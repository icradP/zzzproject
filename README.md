# ZZZ IM

A Flutter-based instant messaging client styled after Zenless Zone Zero. It supports the bundled ZZZ Server protocol and [OneBot v11](https://github.com/botuniverse/onebot-11) backends such as [NapCatQQ](https://github.com/NapNeko/NapCatQQ) and [LLOneBot](https://github.com/LLOneBot/LLOneBot).

## Features

- **OneBot v11 protocol** — Full SDK with forward/reverse WebSocket, HTTP, and HTTP POST event server
- **Persistent chat history** — SQLite-backed message store with media cache
- **Rich media support** — Images, voice, video, emoji reactions, reply quotes
- **iOS PWA client** — Installable from Safari without an Apple Developer account
- **Web Push** — VAPID notifications without an APNs or FCM dependency
- **ZZZ Server** — Go WebSocket server with memory, SQLite, or PostgreSQL storage
- **Account profiles** — Password accounts, persistent expiring sessions, editable nicknames and avatars
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
export ZZZ_ACCESS_TOKEN='<shared test-environment token>'
go run ./cmd/server -addr :8080
```

For a small HTTPS test deployment, build and run the hardened container with
`deploy/zzz-im/deploy.sh`, then install `deploy/zzz-im/nginx.conf`. The script
stores SQLite data and uploaded media under `/var/lib/zzz-im`, and generates
VAPID credentials plus a shared test token in `/etc/zzz-im/server.env`. The Go
port binds only to `127.0.0.1:18080`; Nginx is the public HTTPS/WSS boundary.

Users register and sign in with account-specific passwords. Passwords are
bcrypt-hashed; opaque 90-day sessions are stored by SHA-256 digest so a server
restart does not sign out every device. The shared token remains only for
legacy test clients and should be disabled for untrusted deployments.

To serve the PWA from the same `icrad.ltd` origin, build with a root base path,
package `build/web`, and activate it with the versioned deployment script:

```bash
flutter build web --release --base-href / --no-web-resources-cdn \
  --dart-define=ZZZ_SERVER_URL=wss://icrad.ltd/im/ws
tar -czf /tmp/zzz-pwa.tar.gz -C build/web .
sudo ./deploy/zzz-im/deploy-pwa.sh /tmp/zzz-pwa.tar.gz <release-id>
```

Each release is stored below `/srv/www/zzz-im/releases`; `current` is switched
atomically, so rollback only requires repointing that symlink and reloading is
not needed for ordinary PWA updates.

The custom Web bootstrap keeps CanvasKit on the application origin and starts
the versioned `app-sw.js` cache after the first Flutter frame. Web Push remains
isolated in `push-sw.js` under the narrower `/push/` service-worker scope.

If the target host cannot reach Docker Hub, cross-compile static Linux amd64
binaries into `dist/` and run `deploy/zzz-im/deploy-native.sh`. The included
systemd unit runs the service as the dedicated `zzz-im` user with a read-only
system view and write access limited to `/var/lib/zzz-im`.

```bash
mkdir -p dist
cd server
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC=x86_64-linux-musl-gcc \
  go build -trimpath \
  -ldflags='-s -w -linkmode external -extldflags "-static"' \
  -o ../dist/zzz-im-server-linux-amd64 ./cmd/server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags='-s -w' \
  -o ../dist/zzz-im-vapid-linux-amd64 ./cmd/vapid
cd ..
sudo ./deploy/zzz-im/deploy-native.sh
```

Build the PWA for GitHub Pages:

```bash
flutter build web --release \
  --base-href /zzzproject/ \
  --no-web-resources-cdn \
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
