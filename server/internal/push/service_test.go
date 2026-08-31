package push

import "testing"

func TestNormalizeVAPIDSubscriber(t *testing.T) {
	tests := map[string]string{
		"mailto:admin@icrad.ltd": "admin@icrad.ltd",
		"admin@icrad.ltd":        "admin@icrad.ltd",
		"https://icrad.ltd/push": "https://icrad.ltd/push",
		" mailto:ops@icrad.ltd ": "ops@icrad.ltd",
	}

	for input, want := range tests {
		t.Run(input, func(t *testing.T) {
			if got := normalizeVAPIDSubscriber(input); got != want {
				t.Fatalf("normalizeVAPIDSubscriber(%q) = %q, want %q", input, got, want)
			}
		})
	}
}
