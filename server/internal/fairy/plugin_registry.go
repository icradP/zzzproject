package fairy

const ZZZProfilePluginID = "zzz-profile"

type PluginDescriptor struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Description    string `json:"description"`
	Command        string `json:"command"`
	DefaultEnabled bool   `json:"default_enabled"`
}

type PluginStatus struct {
	PluginDescriptor
	Enabled bool `json:"enabled"`
}

var builtinPluginDescriptors = []PluginDescriptor{
	{
		ID:             ZZZProfilePluginID,
		Name:           "ZZZ public profile",
		Description:    "Read-only public profile lookup through the configured ZZZ data endpoint.",
		Command:        "/zzz <UID>",
		DefaultEnabled: true,
	},
	{
		ID:             ContextMemoryPluginID,
		Name:           "Conversation context memory",
		Description:    "Keeps explicitly triggered conversation context in the Fairy process scope.",
		Command:        "/fairy memory on|off",
		DefaultEnabled: true,
	},
	{
		ID:             FactMemoryPluginID,
		Name:           "Fact memory",
		Description:    "Optional source-linked fact memory, disabled per conversation by default.",
		Command:        "/fairy facts on|off",
		DefaultEnabled: true,
	},
	{
		ID:             SelfCognitionPluginID,
		Name:           "Self cognition",
		Description:    "Provides Fairy identity and capability-boundary prompt context.",
		Command:        "Prompt capability",
		DefaultEnabled: true,
	},
}

func BuiltinPluginStatuses(cfg Config) []PluginStatus {
	statuses := make([]PluginStatus, 0, len(builtinPluginDescriptors))
	for _, descriptor := range builtinPluginDescriptors {
		statuses = append(statuses, PluginStatus{
			PluginDescriptor: descriptor,
			Enabled:          cfg.IsPluginEnabled(descriptor.ID),
		})
	}
	return statuses
}

func NewBuiltinPlugins(cfg Config) []Plugin {
	return []Plugin{NewZZZPlugin(cfg)}
}

const (
	ContextMemoryPluginID = "context-memory"
	FactMemoryPluginID    = "fact-memory"
	SelfCognitionPluginID = "self-cognition"
)

func knownPlugin(id string) bool {
	_, ok := pluginDescriptorByID(id)
	return ok
}

func pluginDescriptorByID(id string) (PluginDescriptor, bool) {
	for _, descriptor := range builtinPluginDescriptors {
		if descriptor.ID == id {
			return descriptor, true
		}
	}
	return PluginDescriptor{}, false
}
