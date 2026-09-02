package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/icradp/zzz-im-server/internal/fairy"
)

func main() {
	os.Exit(run())
}

func run() int {
	cfg, err := fairy.ConfigFromEnv()
	if err != nil {
		log.Printf("[fairy] configuration error: %v", err)
		return 1
	}
	signalContext, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	state, err := fairy.OpenStateStoreWithDefaults(cfg.StateFile, cfg.GroupDefault, cfg.GroupSoftDefault)
	if err != nil {
		log.Printf("[fairy] open state: %v", err)
		return 1
	}
	trace, err := fairy.OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		log.Printf("[fairy] open trace store: %v", err)
		return 1
	}
	defer func() {
		if err := trace.Close(); err != nil {
			log.Printf("[fairy] close trace store: %v", err)
		}
	}()
	facts, err := fairy.OpenSQLiteFactMemoryStore(cfg.FactDB)
	if err != nil {
		log.Printf("[fairy] open fact-memory store: %v", err)
		return 1
	}
	defer func() {
		if err := facts.Close(); err != nil {
			log.Printf("[fairy] close fact-memory store: %v", err)
		}
	}()
	var model fairy.Model
	if cfg.ModelEnabled() {
		modelRouter, routerErr := fairy.NewModelRouter(cfg, trace)
		if routerErr != nil {
			log.Printf("[fairy] initialize model router: %v", routerErr)
			return 1
		}
		model = modelRouter
		log.Printf(
			"[fairy] AI model router enabled (%d providers, %d models), rollout %s (%d allowlisted accounts), daily limit %d",
			len(cfg.ModelProviders), len(cfg.ModelDefinitions), cfg.EffectiveAIRolloutMode(), len(cfg.AIAllowedUsers), cfg.ModelDailyLimit,
		)
	} else if cfg.ModelConfigured() {
		log.Printf("[fairy] AI model routing is configured; production replies are disabled")
	} else {
		log.Printf("[fairy] AI model is not configured; command plugins remain available")
	}
	externalTools := fairy.StartExternalToolManager(signalContext, cfg.ExternalToolProviders)
	defer func() {
		if err := externalTools.Close(); err != nil {
			log.Printf("[fairy] close external tool providers")
		}
	}()
	log.Printf("[fairy] external tool providers initialized (%d tools)", len(externalTools.Tools()))
	engine := fairy.NewEngineWithExternalTools(cfg, state, model, trace, facts, externalTools.Tools(), fairy.NewBuiltinPlugins(cfg)...)
	runner := fairy.NewRunner(cfg, engine, trace)
	configManager := fairy.NewConfigManager(cfg)
	runtimeInspector := fairy.NewRuntimeInspector(engine, runner, trace, facts).WithExternalTools(externalTools)

	ctx, stopRunner := context.WithCancel(signalContext)
	defer stopRunner()
	var restartRequested atomic.Bool
	healthServer := startHealthServer(signalContext, cfg, runner, configManager, runtimeInspector, func() {
		restartRequested.Store(true)
		stopRunner()
	})
	if healthServer != nil {
		defer func() {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = healthServer.Shutdown(shutdownCtx)
		}()
	}
	if err := runner.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Printf("[fairy] stopped: %v", err)
		return 1
	}
	if restartRequested.Load() {
		return 75
	}
	return 0
}

func startHealthServer(ctx context.Context, cfg fairy.Config, runner *fairy.Runner, configManager *fairy.ConfigManager, runtime fairy.AdminRuntime, restart func()) *http.Server {
	if cfg.HealthAddr == "" {
		return nil
	}
	mux := http.NewServeMux()
	registerProbeHandlers(mux, runner.Connected, runner.Ready)
	if cfg.AdminToken != "" {
		adminAPI := fairy.NewAdminAPIWithRuntimeContext(ctx, configManager, cfg.AdminToken, runner.Connected, restart, runtime)
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

func registerProbeHandlers(mux *http.ServeMux, connected, ready func() bool) {
	mux.HandleFunc("/health", probeHandler(false, connected, ready))
	mux.HandleFunc("/ready", probeHandler(true, connected, ready))
}

func probeHandler(requireReady bool, connected, ready func() bool) http.HandlerFunc {
	return func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet && request.Method != http.MethodHead {
			response.Header().Set("Allow", "GET, HEAD")
			http.Error(response, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		isConnected := connected()
		isReady := ready()
		status := "ok"
		if !isConnected {
			status = "connecting"
		} else if !isReady {
			status = "draining"
		}
		response.Header().Set("Content-Type", "application/json")
		response.Header().Set("Cache-Control", "no-store")
		if requireReady && !isReady {
			response.WriteHeader(http.StatusServiceUnavailable)
		}
		if request.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(response).Encode(map[string]interface{}{
			"status":    status,
			"connected": isConnected,
			"ready":     isReady,
		})
	}
}
