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
- **Independent Fairy bot** — Ordinary ZZZ account with private/group triggers, bounded context, plugins, quotas, and optional model provider
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
export ZZZ_INVITE_CODE='<account-registration invite code>'
go run ./cmd/server -addr :8080
```

For a small HTTPS test deployment, build and run the hardened container with
`deploy/zzz-im/deploy.sh`, then install `deploy/zzz-im/nginx.conf`. The script
stores SQLite data and uploaded media under `/var/lib/zzz-im`, and generates
VAPID credentials, an invite code, and a shared test token in
`/etc/zzz-im/server.env`. The Go port binds only to `127.0.0.1:18080`; Nginx is
the public HTTPS/WSS boundary.

Users register with the deployment's invite code and then sign in with
account-specific passwords. Registration is disabled when `ZZZ_INVITE_CODE`
is empty. Passwords are bcrypt-hashed; opaque 90-day sessions are stored by
SHA-256 digest so a server restart does not sign out every device. The shared
token remains only for legacy test clients and should be disabled for
untrusted deployments.

To serve the PWA from the same `icrad.ltd` origin, build with a root base path,
package `build/web`, and activate it with the versioned deployment script:

```bash
flutter build web --release --base-href / --no-web-resources-cdn \
  --dart-define=ZZZ_SERVER_URL=wss://icrad.ltd/im/ws
node tool/generate_web_asset_manifest.mjs build/web
tar -czf /tmp/zzz-pwa.tar.gz -C build/web .
sudo ./deploy/zzz-im/deploy-pwa.sh /tmp/zzz-pwa.tar.gz <release-id>
```

Each release is stored below `/srv/www/zzz-im/releases`; `current` is switched
atomically, so rollback only requires repointing that symlink and reloading is
not needed for ordinary PWA updates.

The server admin console is available at `/im/admin/` when
`ZZZ_ADMIN_TOKEN` is configured. The token is exchanged for a 12-hour,
HttpOnly admin session and is never stored by the page. The console exposes
service statistics, user and password management, groups, conversations,
message moderation, uploaded-media preview and deletion, and runtime
registration controls. It also proxies Fairy's loopback-only management API
for model, context, quota, personality, and registered-plugin settings. Model
API keys are write-only and never returned to the browser. Password resets can
revoke stored account sessions; media deletion removes both metadata and local
bytes. Invitation-code changes made there last until the server restarts;
update `ZZZ_INVITE_CODE` in `/etc/zzz-im/server.env` for a persistent change.

The custom Web bootstrap keeps CanvasKit on the application origin, shows
measured startup download progress, and starts the versioned `app-sw.js` cache
after the first Flutter frame. The generated `startup-assets.json` contains
content hashes so an app upgrade can retain unchanged cached files and fetch
only changed shell resources. Web Push remains isolated in `push-sw.js` under
the narrower `/push/` service-worker scope.

After Flutter becomes interactive, the PWA reports anonymous startup timing,
resource transfer totals, and an approximate cache-hit count to
`/im/client-performance`. Reports contain no account or message data. The
server keeps at most 500 samples in memory, clears them on restart, and exposes
only cold/warm aggregates in the authenticated admin overview. The targets are
8 seconds for a cold start and 2 seconds for a cache-backed warm start; compare
results using a fixed device, browser, network profile, and cache state.

Native production releases are built and pushed from the local workstation.
The release entrypoint checks out the committed `HEAD` in a temporary local
workspace, runs Go tests, cross-compiles static Linux x86_64 artifacts, boots
the server with a temporary SQLite database inside a Linux container, and only
then uploads binaries to the host. The production server never receives source
code or a compiler. Remote installation backs up the current binaries,
environment, and systemd units and restores them if either service fails its
health check.

```bash
# Build and run the Linux x86_64 SQLite smoke test locally.
./deploy/zzz-im/release-native.sh build

# After HEAD is pushed and CI/CD succeeds, upload artifacts and deploy.
./deploy/zzz-im/release-native.sh deploy root@server.example
```

The local machine needs Go, Docker, and `x86_64-linux-musl-gcc` (provided by
Homebrew `musl-cross` on macOS). `deploy` also requires the target commit to be
the remote `master` head with a successful `CI/CD` workflow. Generated binaries
remain available in `dist/`. The lower-level `deploy-native.sh` and
`deploy-fairy-native.sh` scripts are invoked remotely by the release entrypoint;
they are not production build commands.

Build the PWA for GitHub Pages:

```bash
flutter build web --release \
  --base-href /zzzproject/ \
  --no-web-resources-cdn \
  --dart-define=ZZZ_SERVER_URL=wss://im.example.com/ws
node tool/generate_web_asset_manifest.mjs build/web
```

The server endpoint is build-time configuration and is not shown or editable
on the login page. For GitHub Actions, set the repository Actions variable
`ZZZ_SERVER_URL`; local builds fall back to `ws://localhost:8080/ws`.

Web Push on iOS requires iOS 16.4 or later, HTTPS, and installation to the Home Screen. The GitHub Actions workflow tests Flutter and Go on pull requests and deploys the PWA after a successful push to `master`. Deploying the Go server requires a separate HTTPS/WSS hosting target.

Fairy runs as a separate process and ordinary ZZZ account. Its plugin registry
and service boundaries follow the MaiBot-inspired roadmap without loading
arbitrary uploaded code from the admin console. Build and deploy it
after the IM server; the deployment script provisions an isolated system user,
state directory, password, systemd unit, and local health endpoint. Model
credentials are optional and remain in Fairy-owned private configuration. See
[`docs/FAIRY.md`](docs/FAIRY.md) for commands, privacy limits, configuration,
and deployment instructions.

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
