package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	adminserver "github.com/icradp/zzz-im-server/internal/admin"
	"github.com/icradp/zzz-im-server/internal/clientperf"
	"github.com/icradp/zzz-im-server/internal/gateway"
	"github.com/icradp/zzz-im-server/internal/media"
	pushservice "github.com/icradp/zzz-im-server/internal/push"
	"github.com/icradp/zzz-im-server/internal/store"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dbDriver := flag.String("driver", "memory", "Storage driver: memory, sqlite, postgres")
	dbDSN := flag.String("dsn", "", "Database DSN (for sqlite: file path, for postgres: connection string)")
	redisAddr := flag.String("redis", "", "Redis address (e.g. localhost:6379)")
	redisPassword := flag.String("redis-password", "", "Redis password")
	accessToken := flag.String("access-token", os.Getenv("ZZZ_ACCESS_TOKEN"), "shared access token for test deployments")
	inviteCode := flag.String("invite-code", os.Getenv("ZZZ_INVITE_CODE"), "invite code required for account registration")
	adminToken := flag.String("admin-token", os.Getenv("ZZZ_ADMIN_TOKEN"), "token required to access the admin console")
	adminPublicPath := flag.String("admin-public-path", envOrDefault("ZZZ_ADMIN_PUBLIC_PATH", "/admin"), "public URL path used for admin session cookies")
	vapidPublicKey := flag.String("vapid-public-key", os.Getenv("ZZZ_VAPID_PUBLIC_KEY"), "VAPID public key")
	vapidPrivateKey := flag.String("vapid-private-key", os.Getenv("ZZZ_VAPID_PRIVATE_KEY"), "VAPID private key")
	vapidSubject := flag.String("vapid-subject", envOrDefault("ZZZ_VAPID_SUBJECT", "mailto:admin@localhost"), "VAPID contact URI")
	mediaDir := flag.String("media-dir", envOrDefault("ZZZ_MEDIA_DIR", "zzz_media"), "directory for uploaded media")
	flag.Parse()

	var db store.Store
	var err error

	switch *dbDriver {
	case "memory":
		log.Println("[server] using in-memory store")
		db = store.NewMemoryStore()

	case "sqlite":
		dsn := *dbDSN
		if dsn == "" {
			dsn = "zzz_im.db"
		}
		log.Printf("[server] using SQLite store: %s", dsn)
		db, err = store.NewSQLiteStore(dsn)
		if err != nil {
			log.Fatalf("[server] failed to initialize SQLite store: %v", err)
		}

	case "postgres":
		dsn := *dbDSN
		if dsn == "" {
			dsn = "postgres://postgres:postgres@localhost:5432/zzz_im?sslmode=disable"
		}
		log.Printf("[server] using PostgreSQL store")
		db, err = store.NewPostgresStore(dsn)
		if err != nil {
			log.Fatalf("[server] failed to initialize PostgreSQL store: %v", err)
		}

	default:
		log.Fatalf("[server] unknown driver: %s (use: memory, sqlite, postgres)", *dbDriver)
	}
	defer db.Close()

	// Initialize Redis cache (optional).
	var cache *store.RedisCache
	if *redisAddr != "" {
		log.Printf("[server] connecting to Redis: %s", *redisAddr)
		cache, err = store.NewRedisCache(*redisAddr, *redisPassword, 0)
		if err != nil {
			log.Printf("[server] warning: failed to connect to Redis: %v (continuing without cache)", err)
		} else {
			defer cache.Close()
			log.Println("[server] Redis connected")
		}
	}

	// Initialize gateway.
	pushSender := pushservice.NewService(*vapidPublicKey, *vapidPrivateKey, *vapidSubject)
	gw := gateway.NewGateway(db, pushSender)
	gw.SetAccessToken(*accessToken)
	gw.SetInviteCode(*inviteCode)
	mediaStore, err := media.NewLocalStore(*mediaDir, db)
	if err != nil {
		log.Fatalf("[server] failed to initialize media storage: %v", err)
	}
	gw.SetMediaUploader(mediaStore)

	// Routes.
	performanceCollector := clientperf.New(500)
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	mux.Handle("/client-performance", performanceCollector)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.Handle("/files/", mediaStore)
	if strings.TrimSpace(*adminToken) != "" {
		adminConsole := adminserver.New(adminserver.Config{
			Store:         db,
			Media:         mediaStore,
			Registration:  gw,
			Performance:   performanceCollector,
			AdminToken:    *adminToken,
			PublicPath:    *adminPublicPath,
			StorageDriver: *dbDriver,
			PushEnabled:   pushSender.Enabled(),
			StartedAt:     time.Now(),
		})
		mux.Handle("/admin/", adminConsole)
		log.Printf("[server] admin console: enabled at %s", *adminPublicPath)
	} else {
		log.Println("[server] admin console: disabled (set ZZZ_ADMIN_TOKEN)")
	}

	log.Printf("[server] listening on %s", *addr)
	displayAddr := *addr
	if strings.HasPrefix(displayAddr, ":") {
		displayAddr = "localhost" + displayAddr
	}
	log.Printf("[server] WebSocket endpoint: ws://%s/ws", displayAddr)
	log.Printf("[server] storage driver: %s", *dbDriver)
	log.Printf("[server] media directory: %s", *mediaDir)
	if cache != nil {
		log.Println("[server] Redis cache: enabled")
	} else {
		log.Println("[server] Redis cache: disabled")
	}
	if pushSender.Enabled() {
		log.Println("[server] Web Push: enabled")
	} else {
		log.Println("[server] Web Push: disabled (set ZZZ_VAPID_PUBLIC_KEY and ZZZ_VAPID_PRIVATE_KEY)")
	}
	if *accessToken != "" {
		log.Println("[server] shared-token authentication: enabled")
	} else {
		log.Println("[server] shared-token authentication: disabled (development mode)")
	}
	if gw.RegistrationEnabled() {
		log.Println("[server] invite-only registration: enabled")
	} else {
		log.Println("[server] registration: disabled (set ZZZ_INVITE_CODE)")
	}

	if err := http.ListenAndServe(*addr, mux); err != nil {
		log.Fatalf("[server] failed to start: %v", err)
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
