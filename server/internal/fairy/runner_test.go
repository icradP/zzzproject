package fairy

import (
	"testing"
	"time"
)

func TestNextReconnectDelayUsesExponentialBackoff(t *testing.T) {
	minimum := 2 * time.Second
	maximum := 30 * time.Second
	cases := []struct {
		name    string
		current time.Duration
		want    time.Duration
	}{
		{name: "first retry", current: minimum, want: 4 * time.Second},
		{name: "middle retry", current: 8 * time.Second, want: 16 * time.Second},
		{name: "clamped at maximum", current: 20 * time.Second, want: maximum},
		{name: "never below minimum", current: time.Second, want: minimum},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := nextReconnectDelay(testCase.current, minimum, maximum); got != testCase.want {
				t.Fatalf("nextReconnectDelay(%s) = %s, want %s", testCase.current, got, testCase.want)
			}
		})
	}
}

func TestReconnectDelayResetsAfterEstablishedSession(t *testing.T) {
	current := 20 * time.Second
	minimum := 2 * time.Second
	if got := reconnectDelayAfterSession(current, minimum, true); got != minimum {
		t.Fatalf("healthy session delay = %s, want %s", got, minimum)
	}
	if got := reconnectDelayAfterSession(current, minimum, false); got != current {
		t.Fatalf("failed dial delay = %s, want %s", got, current)
	}
	if got := nextReconnectDelay(time.Duration(1<<63-1), minimum, time.Duration(1<<63-1)); got != time.Duration(1<<63-1) {
		t.Fatalf("overflow guard delay = %s, want maximum", got)
	}
}
