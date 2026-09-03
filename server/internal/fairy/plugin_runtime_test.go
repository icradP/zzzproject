package fairy

import (
	"context"
	"strings"
	"testing"
)

type pluginRuntimeTestModule struct {
	manifest PluginManifest
	register func(*PluginContext) error
	started  *int
	stopped  *int
}

func (m *pluginRuntimeTestModule) Manifest() PluginManifest { return m.manifest }

func (m *pluginRuntimeTestModule) Register(_ context.Context, scope *PluginContext) error {
	if m.register != nil {
		return m.register(scope)
	}
	return nil
}

func (m *pluginRuntimeTestModule) Start(context.Context) error {
	if m.started != nil {
		*m.started++
	}
	return nil
}

func (m *pluginRuntimeTestModule) Stop(context.Context) error {
	if m.stopped != nil {
		*m.stopped++
	}
	return nil
}

func TestPluginHostDependenciesCapabilitiesHooksAndReload(t *testing.T) {
	providerStarted, providerStopped := 0, 0
	consumerStarted, consumerStopped, hookCalls := 0, 0, 0
	providerFactory := func() PluginModule {
		return &pluginRuntimeTestModule{
			manifest: PluginManifest{
				ID: "provider", Name: "Provider", Version: "1.2.0", APIVersion: 1,
				Components: []PluginComponent{PluginComponentService}, Provides: []string{"test.value"},
				Isolation: PluginIsolationInProcess, Reloadable: true, DefaultEnabled: true,
			},
			register: func(scope *PluginContext) error { return scope.ProvideCapability("test.value", "ready") },
			started:  &providerStarted, stopped: &providerStopped,
		}
	}
	consumerFactory := func() PluginModule {
		return &pluginRuntimeTestModule{
			manifest: PluginManifest{
				ID: "consumer", Name: "Consumer", Version: "1.0.0", APIVersion: 1,
				Components: []PluginComponent{PluginComponentHook}, Requires: []string{"test.value"},
				Dependencies: []PluginDependency{{ID: "provider", MinVersion: "1.1.0"}},
				Isolation:    PluginIsolationInProcess, Reloadable: true, DefaultEnabled: true,
			},
			register: func(scope *PluginContext) error {
				value, ok := scope.Capability("test.value")
				if !ok || value != "ready" {
					return context.Canceled
				}
				return scope.On(PluginHookBeforePrompt, func(context.Context, *PluginEvent) error {
					hookCalls++
					return nil
				})
			},
			started: &consumerStarted, stopped: &consumerStopped,
		}
	}

	host, err := NewPluginHost(context.Background(), testConfig(t), nil, consumerFactory, providerFactory)
	if err != nil {
		t.Fatal(err)
	}
	if providerStarted != 1 || consumerStarted != 1 {
		t.Fatalf("plugin start order failed provider=%d consumer=%d", providerStarted, consumerStarted)
	}
	if err := host.Emit(context.Background(), &PluginEvent{Name: PluginHookBeforePrompt}); err != nil || hookCalls != 1 {
		t.Fatalf("first hook emit calls=%d err=%v", hookCalls, err)
	}
	if err := host.Unload(context.Background(), "provider"); err == nil || !strings.Contains(err.Error(), "required by consumer") {
		t.Fatalf("loaded dependency was removable: %v", err)
	}
	if err := host.Reload(context.Background(), "consumer"); err != nil {
		t.Fatal(err)
	}
	if consumerStarted != 2 || consumerStopped != 1 {
		t.Fatalf("reload lifecycle started=%d stopped=%d", consumerStarted, consumerStopped)
	}
	if err := host.Emit(context.Background(), &PluginEvent{Name: PluginHookBeforePrompt}); err != nil || hookCalls != 2 {
		t.Fatalf("reloaded hook was duplicated or missing calls=%d err=%v", hookCalls, err)
	}
	if err := host.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if providerStopped != 1 || consumerStopped != 2 {
		t.Fatalf("close lifecycle provider=%d consumer=%d", providerStopped, consumerStopped)
	}
	if _, exists := host.capabilities.get("test.value"); exists {
		t.Fatal("unloaded plugin capability remained visible")
	}
}

func TestPluginHostRejectsDependencyCyclesAndUndeclaredComponents(t *testing.T) {
	factory := func(id, dependency string) PluginFactory {
		return func() PluginModule {
			return &pluginRuntimeTestModule{manifest: PluginManifest{
				ID: id, Name: id, Version: "1.0.0", APIVersion: 1,
				Dependencies: []PluginDependency{{ID: dependency}}, Isolation: PluginIsolationInProcess,
			}}
		}
	}
	if _, err := NewPluginHost(context.Background(), testConfig(t), nil, factory("one", "two"), factory("two", "one")); err == nil {
		t.Fatal("plugin dependency cycle was accepted")
	}

	module := &pluginRuntimeTestModule{
		manifest: PluginManifest{
			ID: "limited", Name: "Limited", Version: "1.0.0", APIVersion: 1,
			Isolation: PluginIsolationInProcess, DefaultEnabled: true,
		},
		register: func(scope *PluginContext) error {
			return scope.RegisterMemory("hidden-memory", struct{}{})
		},
	}
	host, err := NewPluginHost(context.Background(), testConfig(t), nil, func() PluginModule { return module })
	if err == nil || host == nil {
		t.Fatalf("undeclared component registration host=%v err=%v", host, err)
	}
	statuses := host.Statuses()
	if len(statuses) != 1 || statuses[0].State != "failed" || statuses[0].Error != "startup_failed" {
		t.Fatalf("failed plugin status = %#v", statuses)
	}

	duplicate := &pluginRuntimeTestModule{
		manifest: PluginManifest{
			ID: "duplicate", Name: "Duplicate", Version: "1.0.0", APIVersion: 1,
			Components:     []PluginComponent{PluginComponentMemory},
			DefaultEnabled: true,
		},
		register: func(scope *PluginContext) error {
			if err := scope.RegisterMemory("memory", struct{}{}); err != nil {
				return err
			}
			return scope.RegisterMemory("memory", struct{}{})
		},
	}
	duplicateHost, err := NewPluginHost(context.Background(), testConfig(t), nil, func() PluginModule { return duplicate })
	if err == nil || duplicateHost == nil || duplicateHost.Statuses()[0].State != "failed" {
		t.Fatalf("duplicate registration host=%v err=%v", duplicateHost, err)
	}
}

func TestPluginHostInstallsIsolationRunnerBeforeStartup(t *testing.T) {
	module := &pluginRuntimeTestModule{manifest: PluginManifest{
		ID: "process-plugin", Name: "Process plugin", Version: "1.0.0", APIVersion: 1,
		Isolation: PluginIsolationProcess, DefaultEnabled: true,
	}}
	host, err := NewPluginHostWithRunners(
		context.Background(),
		testConfig(t),
		nil,
		map[PluginIsolation]PluginRunner{PluginIsolationProcess: InProcessPluginRunner{}},
		func() PluginModule { return module },
	)
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close(context.Background())
	if !host.Running("process-plugin") {
		t.Fatalf("process plugin status = %#v", host.Statuses())
	}

	defaultIsolation := &pluginRuntimeTestModule{manifest: PluginManifest{
		ID: "default-isolation", Name: "Default isolation", Version: "1.0.0", APIVersion: 1,
		DefaultEnabled: true,
	}}
	defaultHost, err := NewPluginHost(context.Background(), testConfig(t), nil, func() PluginModule { return defaultIsolation })
	if err != nil {
		t.Fatal(err)
	}
	defer defaultHost.Close(context.Background())
	if status := defaultHost.Statuses()[0]; status.Isolation != PluginIsolationInProcess || status.State != "running" {
		t.Fatalf("default isolation status = %#v", status)
	}
}

func TestPluginHostUsesManifestDefaultUntilConfigurationOverridesIt(t *testing.T) {
	module := &pluginRuntimeTestModule{manifest: PluginManifest{
		ID: "opt-in", Name: "Opt in", Version: "1.0.0", APIVersion: 1,
		Isolation: PluginIsolationInProcess, DefaultEnabled: false,
	}}
	factory := func() PluginModule { return module }
	host, err := NewPluginHost(context.Background(), testConfig(t), nil, factory)
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close(context.Background())
	if status := host.Statuses()[0]; status.State != "disabled" || status.Enabled {
		t.Fatalf("manifest-disabled plugin status = %#v", status)
	}

	cfg := testConfig(t)
	cfg.PluginEnabled = clonePluginSettings(cfg.PluginEnabled)
	cfg.PluginEnabled["opt-in"] = true
	enabledHost, err := NewPluginHost(context.Background(), cfg, nil, factory)
	if err != nil {
		t.Fatal(err)
	}
	defer enabledHost.Close(context.Background())
	if status := enabledHost.Statuses()[0]; status.State != "running" || !status.Enabled {
		t.Fatalf("configured plugin status = %#v", status)
	}
}

func TestBuiltinMemoryAndSelfCognitionPluginsAreRegistered(t *testing.T) {
	cfg := testConfig(t)
	contexts := NewContextStore(cfg.ContextTTL, cfg.ContextMessages)
	host, err := NewPluginHost(context.Background(), cfg, nil, BuiltinPluginFactories(contexts, nil)...)
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close(context.Background())

	statuses := host.Statuses()
	if len(statuses) != 3 {
		t.Fatalf("builtin plugin statuses = %#v", statuses)
	}
	sections := host.PromptSections(context.Background())
	if len(sections) != 1 || sections[0].ID != "self_cognition" || !strings.Contains(sections[0].Content, "bounded AI friend") {
		t.Fatalf("self cognition sections = %#v", sections)
	}
	if capability, ok := host.capabilities.get("memory.context"); !ok || capability != contexts {
		t.Fatalf("context memory capability = %#v, %v", capability, ok)
	}

	disabledConfig := cfg
	disabledConfig.PluginEnabled = clonePluginSettings(cfg.PluginEnabled)
	disabledConfig.PluginEnabled[SelfCognitionPluginID] = false
	disabledHost, err := NewPluginHost(context.Background(), disabledConfig, nil, BuiltinPluginFactories(contexts, nil)...)
	if err != nil {
		t.Fatal(err)
	}
	defer disabledHost.Close(context.Background())
	if sections := disabledHost.PromptSections(context.Background()); len(sections) != 0 {
		t.Fatalf("disabled self cognition sections = %#v", sections)
	}
}
