package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/icradp/zzz-im-server/internal/fairy"
)

func main() {
	cfg, err := fairy.ConfigFromEnv()
	if err != nil {
		log.Fatalf("[fairy] configuration error: %v", err)
	}
	state, err := fairy.OpenStateStore(cfg.StateFile, cfg.GroupDefault)
	if err != nil {
		log.Fatalf("[fairy] open state: %v", err)
	}
	var model fairy.Model
	if cfg.ModelEnabled() {
		model = fairy.NewCompatibleModel(cfg)
		log.Printf("[fairy] AI model enabled (%s), daily limit %d", cfg.ModelName, cfg.ModelDailyLimit)
	} else {
		log.Printf("[fairy] AI model is not configured; command plugins remain available")
	}
	engine := fairy.NewEngine(cfg, state, model, fairy.NewBuiltinPlugins(cfg)...)
	runner := fairy.NewRunner(cfg, engine)
	configManager := fairy.NewConfigManager(cfg)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	healthServer := startHealthServer(cfg, runner, configManager)
	if healthServer != nil {
		defer func() {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = healthServer.Shutdown(shutdownCtx)
		}()
	}
	if err := runner.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatalf("[fairy] stopped: %v", err)
	}
}

func startHealthServer(cfg fairy.Config, runner *fairy.Runner, configManager *fairy.ConfigManager) *http.Server {
	if cfg.HealthAddr == "" {
		return nil
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet && request.Method != http.MethodHead {
			response.Header().Set("Allow", "GET, HEAD")
			http.Error(response, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		connected := runner.Connected()
		response.Header().Set("Content-Type", "application/json")
		response.Header().Set("Cache-Control", "no-store")
		if !connected {
			response.WriteHeader(http.StatusServiceUnavailable)
		}
		if request.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(response).Encode(map[string]interface{}{
			"status":    map[bool]string{true: "ok", false: "connecting"}[connected],
			"connected": connected,
		})
	})
	if cfg.AdminToken != "" {
		adminAPI := fairy.NewAdminAPI(configManager, cfg.AdminToken, runner.Connected, func() {
			time.Sleep(300 * time.Millisecond)
			os.Exit(75)
		})
		mux.Handle("/admin/", adminAPI)
		log.Printf("[fairy] local admin API enabled")
	}
	server := &http.Server{
		Addr:              cfg.HealthAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	go func() {
		log.Printf("[fairy] health endpoint listening on %s", cfg.HealthAddr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("[fairy] health endpoint stopped: %v", err)
		}
	}()
	return server
}
