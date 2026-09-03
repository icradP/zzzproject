package fairy

import (
	"context"
	"time"
)

type RuntimeBehaviorStatus struct {
	GroupSoftTrigger string `json:"group_soft_trigger"`
	FocusTTLSeconds  int64  `json:"focus_ttl_seconds"`
	CooldownSeconds  int64  `json:"soft_cooldown_seconds"`
	ExpressionStyle  string `json:"expression_style"`
}

type RuntimeModelQuotaStatus struct {
	DailyLimit int `json:"daily_limit"`
	Used       int `json:"used"`
	Remaining  int `json:"remaining"`
}

type RuntimeTaskModelQuotaStatus struct {
	TaskID     string `json:"task_id"`
	DailyLimit int    `json:"daily_limit"`
	Used       int    `json:"used"`
	Remaining  int    `json:"remaining"`
}

type RuntimeToolStatus struct {
	Name          string `json:"name"`
	Enabled       bool   `json:"enabled"`
	PolicyAllowed bool   `json:"policy_allowed"`
	Risk          string `json:"risk"`
	Concurrency   string `json:"concurrency"`
	Idempotency   string `json:"idempotency"`
	TimeoutMillis int64  `json:"timeout_millis"`
}

type RuntimeFactMemoryStatus struct {
	Available     bool `json:"available"`
	Facts         int  `json:"facts"`
	StoredScopes  int  `json:"stored_scopes"`
	EnabledScopes int  `json:"enabled_scopes"`
}

type RuntimeZZZAccountStatus struct {
	Available     bool `json:"available"`
	BoundAccounts int  `json:"bound_accounts"`
	ValidAccounts int  `json:"valid_accounts"`
	CachedRecords int  `json:"cached_gacha_records"`
}

type RuntimeBehaviorExperienceStatus struct {
	Configured   int  `json:"configured"`
	Enabled      int  `json:"enabled"`
	AutoLearning bool `json:"auto_learning"`
}

type RuntimeOutboundDeliveryStatus struct {
	Delivered      uint64 `json:"delivered"`
	RetryAttempts  uint64 `json:"retry_attempts"`
	Failed         uint64 `json:"failed"`
	OutcomeUnknown uint64 `json:"outcome_unknown"`
}

type RuntimeFeedbackStatus struct {
	Available    bool    `json:"available"`
	WindowHours  int     `json:"window_hours"`
	RatedOutputs int     `json:"rated_outputs"`
	Positive     int     `json:"positive"`
	Negative     int     `json:"negative"`
	PositiveRate float64 `json:"positive_rate"`
}

type RuntimeStatus struct {
	Behavior              RuntimeBehaviorStatus           `json:"behavior"`
	Scheduler             SchedulerStats                  `json:"scheduler"`
	ModelQuota            RuntimeModelQuotaStatus         `json:"model_quota"`
	TaskModelQuotas       []RuntimeTaskModelQuotaStatus   `json:"task_model_quotas"`
	Tools                 []RuntimeToolStatus             `json:"tools"`
	Trace                 TraceRuntimeStats               `json:"trace_24h"`
	TraceAvailable        bool                            `json:"trace_available"`
	FactMemory            RuntimeFactMemoryStatus         `json:"fact_memory"`
	ZZZAccounts           RuntimeZZZAccountStatus         `json:"zzz_accounts"`
	BehaviorExperiences   RuntimeBehaviorExperienceStatus `json:"behavior_experiences"`
	OutboundDelivery      RuntimeOutboundDeliveryStatus   `json:"outbound_delivery"`
	Feedback              RuntimeFeedbackStatus           `json:"feedback_24h"`
	ExternalToolProviders []ExternalToolProviderStatus    `json:"external_tool_providers"`
	Plugins               []PluginRuntimeStatus           `json:"plugins"`
}

type AdminRuntime interface {
	ApplyBehaviorConfig(Config)
	Snapshot(context.Context) RuntimeStatus
}

// AgentDiagnosticRunner is optional so older embedders can keep implementing
// AdminRuntime without exposing a model test capability.
type AgentDiagnosticRunner interface {
	RunAgentDiagnostic(context.Context, string) (AgentDiagnosticResult, error)
}

type DecisionChainAdminRuntime interface {
	DecisionChains(context.Context, int) ([]DecisionChain, error)
}

type RuntimeInspector struct {
	engine        *Engine
	runner        *Runner
	trace         TraceStore
	facts         FactMemoryStore
	externalTools *ExternalToolManager
}

func (r *RuntimeInspector) WithExternalTools(manager *ExternalToolManager) *RuntimeInspector {
	if r != nil {
		r.externalTools = manager
	}
	return r
}

func NewRuntimeInspector(engine *Engine, runner *Runner, trace TraceStore, facts ...FactMemoryStore) *RuntimeInspector {
	var factStore FactMemoryStore
	if len(facts) > 0 {
		factStore = facts[0]
	}
	return &RuntimeInspector{engine: engine, runner: runner, trace: trace, facts: factStore}
}

func (r *RuntimeInspector) ApplyBehaviorConfig(cfg Config) {
	if r != nil && r.engine != nil {
		r.engine.ApplyBehaviorConfig(cfg)
	}
}

func (r *RuntimeInspector) RunAgentDiagnostic(ctx context.Context, caseID string) (AgentDiagnosticResult, error) {
	if r == nil || r.engine == nil {
		return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
	}
	return r.engine.RunAgentDiagnostic(ctx, caseID)
}

func (r *RuntimeInspector) DecisionChains(ctx context.Context, limit int) ([]DecisionChain, error) {
	if r == nil {
		return nil, nil
	}
	reader, ok := r.trace.(DecisionChainReader)
	if !ok {
		return nil, nil
	}
	return reader.ListDecisionChains(ctx, limit)
}

func (r *RuntimeInspector) Snapshot(ctx context.Context) RuntimeStatus {
	status := RuntimeStatus{
		Tools: make([]RuntimeToolStatus, 0),
		Trace: TraceRuntimeStats{
			WindowHours: 24, GateActions: make(map[string]int), GateReasons: make(map[string]int),
			ModelHealth: make([]TraceModelHealthStats, 0), RecentFailures: make([]TraceRecentFailure, 0),
		},
		TaskModelQuotas: make([]RuntimeTaskModelQuotaStatus, 0),
	}
	if r == nil {
		return status
	}
	if r.engine != nil {
		behavior := r.engine.BehaviorConfig()
		status.Behavior = RuntimeBehaviorStatus{
			GroupSoftTrigger: string(behavior.GroupSoftDefault),
			FocusTTLSeconds:  int64(behavior.FocusTTL / time.Second),
			CooldownSeconds:  int64(behavior.SoftCooldown / time.Second),
			ExpressionStyle:  string(behavior.ExpressionStyle),
		}
		if r.engine.state != nil {
			now := r.engine.now()
			used, remaining := r.engine.state.ModelQuotaStatus(now, r.engine.cfg.ModelDailyLimit)
			status.ModelQuota = RuntimeModelQuotaStatus{
				DailyLimit: r.engine.cfg.ModelDailyLimit, Used: used, Remaining: remaining,
			}
			for _, task := range r.engine.cfg.ModelTasks {
				limit := r.engine.modelTaskDailyLimit(task.ID)
				taskUsed, taskRemaining := r.engine.state.TaskModelQuotaStatus(now, task.ID, limit)
				status.TaskModelQuotas = append(status.TaskModelQuotas, RuntimeTaskModelQuotaStatus{
					TaskID: task.ID, DailyLimit: limit, Used: taskUsed, Remaining: taskRemaining,
				})
			}
		}
		status.BehaviorExperiences.Configured = len(r.engine.cfg.BehaviorExperiences)
		for _, experience := range r.engine.cfg.BehaviorExperiences {
			if experience.Enabled {
				status.BehaviorExperiences.Enabled++
			}
		}
		if r.engine.pluginHost != nil {
			status.Plugins = r.engine.pluginHost.Statuses()
		}
		if r.engine.tools != nil && r.engine.tools.registry != nil {
			for _, spec := range r.engine.tools.registry.List() {
				status.Tools = append(status.Tools, RuntimeToolStatus{
					Name: spec.Name, Enabled: true,
					PolicyAllowed: r.engine.tools.registry.PolicyAllows(spec.Name, r.engine.tools.policy),
					Risk:          string(spec.Risk), Concurrency: string(spec.Concurrency), Idempotency: string(spec.Idempotency),
					TimeoutMillis: int64(spec.Timeout / time.Millisecond),
				})
			}
		}
	}
	if r.runner != nil {
		status.Scheduler = r.runner.Stats()
		outbound := r.runner.OutboundStats()
		status.OutboundDelivery = RuntimeOutboundDeliveryStatus(outbound)
	}
	if reader, ok := r.trace.(TraceStatsReader); ok {
		stats, err := reader.RuntimeStats(ctx, time.Now().Add(-24*time.Hour))
		if err == nil {
			status.Trace = stats
			status.TraceAvailable = true
		}
	}
	if reader, ok := r.trace.(FeedbackStatsReader); ok {
		stats, err := reader.FeedbackStats(ctx, time.Now().Add(-24*time.Hour))
		if err == nil {
			status.Feedback = RuntimeFeedbackStatus{
				Available: true, WindowHours: stats.WindowHours, RatedOutputs: stats.RatedOutputs,
				Positive: stats.Positive, Negative: stats.Negative, PositiveRate: stats.PositiveRate,
			}
		}
	}
	factStore := r.facts
	if r.engine != nil {
		pluginStore, pluginAvailable := r.engine.factMemory()
		if pluginAvailable {
			factStore = pluginStore
		} else {
			factStore = nil
		}
	}
	if factStore != nil {
		stats, err := factStore.Stats(ctx, time.Now())
		if err == nil {
			status.FactMemory.Available = true
			status.FactMemory.Facts = stats.Facts
			status.FactMemory.StoredScopes = stats.Scopes
			if r.engine != nil && r.engine.state != nil {
				status.FactMemory.EnabledScopes = r.engine.state.FactMemoryEnabledScopeCount()
			}
		}
	}
	if r.engine != nil && r.engine.pluginHost != nil {
		for _, command := range r.engine.pluginHost.Commands() {
			plugin, ok := command.(*ZZZAccountPlugin)
			if !ok {
				continue
			}
			stats, err := plugin.Stats(ctx)
			if err == nil {
				status.ZZZAccounts = RuntimeZZZAccountStatus{
					Available: true, BoundAccounts: stats.BoundAccounts,
					ValidAccounts: stats.ValidAccounts, CachedRecords: stats.CachedRecords,
				}
			}
			break
		}
	}
	status.ExternalToolProviders = r.externalTools.Status()
	return status
}
