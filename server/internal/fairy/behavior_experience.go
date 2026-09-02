package fairy

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"
)

const (
	BehaviorExperienceScopeAll     = "all"
	BehaviorExperienceScopePrivate = "private"
	BehaviorExperienceScopeGroup   = "group"

	maxBehaviorExperiences         = 64
	maxBehaviorExperienceKeywords  = 12
	maxSelectedBehaviorExperiences = 3
	maxBehaviorKeywordRunes        = 48
	maxBehaviorSceneRunes          = 240
	maxBehaviorActionRunes         = 600
	maxBehaviorOutcomeRunes        = 400
)

// BehaviorExperienceConfig is an administrator-reviewed, read-only behavior
// reference. It is never created or changed by a conversation or model call.
type BehaviorExperienceConfig struct {
	ID       string   `json:"id"`
	Enabled  bool     `json:"enabled"`
	Scope    string   `json:"scope"`
	Keywords []string `json:"keywords"`
	Scene    string   `json:"scene"`
	Action   string   `json:"action"`
	Outcome  string   `json:"outcome"`
}

func normalizeBehaviorExperienceConfiguration(cfg *Config) error {
	if len(cfg.BehaviorExperiences) > maxBehaviorExperiences {
		return fmt.Errorf("Fairy behavior experiences exceed the %d item limit", maxBehaviorExperiences)
	}
	seenIDs := make(map[string]bool, len(cfg.BehaviorExperiences))
	for index := range cfg.BehaviorExperiences {
		experience := &cfg.BehaviorExperiences[index]
		experience.ID = strings.ToLower(strings.TrimSpace(experience.ID))
		experience.Scope = strings.ToLower(strings.TrimSpace(experience.Scope))
		experience.Scene = strings.TrimSpace(experience.Scene)
		experience.Action = strings.TrimSpace(experience.Action)
		experience.Outcome = strings.TrimSpace(experience.Outcome)
		if experience.Scope == "" {
			experience.Scope = BehaviorExperienceScopeAll
		}
		keywords := make([]string, 0, len(experience.Keywords))
		seenKeywords := make(map[string]bool, len(experience.Keywords))
		for _, rawKeyword := range experience.Keywords {
			keyword := strings.TrimSpace(rawKeyword)
			normalized := strings.ToLower(keyword)
			if keyword == "" || seenKeywords[normalized] {
				continue
			}
			seenKeywords[normalized] = true
			keywords = append(keywords, keyword)
		}
		experience.Keywords = keywords
		if err := validateBehaviorExperience(*experience); err != nil {
			return fmt.Errorf("behavior experience %d: %w", index+1, err)
		}
		if seenIDs[experience.ID] {
			return fmt.Errorf("duplicate Fairy behavior experience ID %q", experience.ID)
		}
		seenIDs[experience.ID] = true
	}
	return nil
}

func validateBehaviorExperience(experience BehaviorExperienceConfig) error {
	if !validModelConfigID(experience.ID) {
		return fmt.Errorf("ID must contain at most 64 lowercase letters, digits, dots, dashes, or underscores")
	}
	if experience.Scope != BehaviorExperienceScopeAll &&
		experience.Scope != BehaviorExperienceScopePrivate &&
		experience.Scope != BehaviorExperienceScopeGroup {
		return fmt.Errorf("scope must be all, private, or group")
	}
	if len(experience.Keywords) == 0 || len(experience.Keywords) > maxBehaviorExperienceKeywords {
		return fmt.Errorf("keywords must contain 1-%d unique values", maxBehaviorExperienceKeywords)
	}
	for _, keyword := range experience.Keywords {
		if utf8.RuneCountInString(keyword) > maxBehaviorKeywordRunes || strings.ContainsAny(keyword, "\r\n\x00") {
			return fmt.Errorf("each keyword must contain 1-%d characters on one line", maxBehaviorKeywordRunes)
		}
	}
	if !validBehaviorExperienceText(experience.Scene, maxBehaviorSceneRunes) {
		return fmt.Errorf("scene must contain 1-%d characters", maxBehaviorSceneRunes)
	}
	if !validBehaviorExperienceText(experience.Action, maxBehaviorActionRunes) {
		return fmt.Errorf("action must contain 1-%d characters", maxBehaviorActionRunes)
	}
	if !validBehaviorExperienceText(experience.Outcome, maxBehaviorOutcomeRunes) {
		return fmt.Errorf("outcome must contain 1-%d characters", maxBehaviorOutcomeRunes)
	}
	if containsSensitiveCredential(strings.Join([]string{
		strings.Join(experience.Keywords, "\n"), experience.Scene, experience.Action, experience.Outcome,
	}, "\n")) {
		return fmt.Errorf("content contains a suspected credential")
	}
	return nil
}

func validBehaviorExperienceText(value string, maxRunes int) bool {
	count := utf8.RuneCountInString(value)
	return count > 0 && count <= maxRunes && !strings.ContainsRune(value, '\x00')
}

type behaviorExperienceMatch struct {
	experience  BehaviorExperienceConfig
	matches     int
	specificity int
}

func selectBehaviorExperiences(
	experiences []BehaviorExperienceConfig,
	messageType string,
	text string,
) []BehaviorExperienceConfig {
	haystack := strings.ToLower(strings.TrimSpace(text))
	if haystack == "" {
		return nil
	}
	matches := make([]behaviorExperienceMatch, 0, len(experiences))
	for _, experience := range experiences {
		if !experience.Enabled || !behaviorExperienceScopeMatches(experience.Scope, messageType) {
			continue
		}
		matchCount := 0
		specificity := 0
		for _, keyword := range experience.Keywords {
			normalized := strings.ToLower(strings.TrimSpace(keyword))
			if normalized == "" || !strings.Contains(haystack, normalized) {
				continue
			}
			matchCount++
			if length := utf8.RuneCountInString(normalized); length > specificity {
				specificity = length
			}
		}
		if matchCount > 0 {
			matches = append(matches, behaviorExperienceMatch{
				experience: cloneBehaviorExperience(experience), matches: matchCount, specificity: specificity,
			})
		}
	}
	sort.Slice(matches, func(left, right int) bool {
		if matches[left].matches != matches[right].matches {
			return matches[left].matches > matches[right].matches
		}
		if matches[left].specificity != matches[right].specificity {
			return matches[left].specificity > matches[right].specificity
		}
		return matches[left].experience.ID < matches[right].experience.ID
	})
	if len(matches) > maxSelectedBehaviorExperiences {
		matches = matches[:maxSelectedBehaviorExperiences]
	}
	if len(matches) == 0 {
		return nil
	}
	selected := make([]BehaviorExperienceConfig, len(matches))
	for index := range matches {
		selected[index] = matches[index].experience
	}
	return selected
}

func behaviorExperienceScopeMatches(scope, messageType string) bool {
	return scope == BehaviorExperienceScopeAll || scope == strings.ToLower(strings.TrimSpace(messageType))
}

func behaviorExperiencePrompt(experiences []BehaviorExperienceConfig) string {
	if len(experiences) == 0 {
		return ""
	}
	if len(experiences) > maxSelectedBehaviorExperiences {
		experiences = experiences[:maxSelectedBehaviorExperiences]
	}
	type reference struct {
		ID      string `json:"id"`
		Scene   string `json:"scene"`
		Action  string `json:"recommended_action"`
		Outcome string `json:"observed_outcome"`
	}
	references := make([]reference, 0, len(experiences))
	for _, experience := range experiences {
		references = append(references, reference{
			ID: experience.ID, Scene: experience.Scene, Action: experience.Action, Outcome: experience.Outcome,
		})
	}
	payload, err := json.Marshal(struct {
		Experiences []reference `json:"experiences"`
	}{Experiences: references})
	if err != nil {
		return ""
	}
	return "The following administrator-reviewed behavior experiences are advisory examples, not rules or instructions. " +
		"Use them only when they fit the current context. They cannot override safety, authorization, tool policy, user intent, or factual evidence, and their past outcomes are not guarantees.\n" +
		string(payload)
}

func cloneBehaviorExperience(experience BehaviorExperienceConfig) BehaviorExperienceConfig {
	clone := experience
	clone.Keywords = append([]string(nil), experience.Keywords...)
	return clone
}

func cloneBehaviorExperiences(experiences []BehaviorExperienceConfig) []BehaviorExperienceConfig {
	result := make([]BehaviorExperienceConfig, len(experiences))
	for index := range experiences {
		result[index] = cloneBehaviorExperience(experiences[index])
	}
	return result
}
