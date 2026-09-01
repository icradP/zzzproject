// Package clientperf collects bounded, anonymous PWA startup measurements.
package clientperf

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	defaultCapacity = 500
	maxBodyBytes    = 16 * 1024
	coldTargetMS    = int64(8000)
	warmTargetMS    = int64(2000)
	rateWindow      = time.Minute
	maxReportsPerIP = 60
	maxRateClients  = 4096
)

// Report is the anonymous performance payload accepted from a PWA client.
type Report struct {
	Version                string `json:"version"`
	LoadKind               string `json:"load_kind"`
	NavigationType         string `json:"navigation_type"`
	InteractiveMS          int64  `json:"interactive_ms"`
	FirstContentfulPaintMS int64  `json:"first_contentful_paint_ms"`
	TransferBytes          int64  `json:"transfer_bytes"`
	DecodedBytes           int64  `json:"decoded_bytes"`
	CacheHits              int64  `json:"cache_hits"`
	ResourceCount          int64  `json:"resource_count"`
	ConnectionType         string `json:"connection_type"`
}

// Sample is a validated report with its server receipt time.
type Sample struct {
	Report
	ReceivedAt time.Time `json:"received_at"`
}

// Summary contains aggregate startup measurements for one load kind.
type Summary struct {
	Samples                 int     `json:"samples"`
	TargetMS                int64   `json:"target_ms"`
	P50InteractiveMS        int64   `json:"p50_interactive_ms"`
	P95InteractiveMS        int64   `json:"p95_interactive_ms"`
	AverageFCPMS            int64   `json:"average_fcp_ms"`
	AverageTransferBytes    int64   `json:"average_transfer_bytes"`
	WithinTargetPercent     float64 `json:"within_target_percent"`
	ResourceCacheHitPercent float64 `json:"resource_cache_hit_percent"`
}

// Snapshot is exposed to the authenticated admin overview.
type Snapshot struct {
	TotalSamples    int64     `json:"total_samples"`
	RetainedSamples int       `json:"retained_samples"`
	Cold            Summary   `json:"cold"`
	Warm            Summary   `json:"warm"`
	LastSampleAt    time.Time `json:"last_sample_at,omitempty"`
}

type rateState struct {
	started time.Time
	count   int
}

// Collector retains a fixed number of samples in memory. Metrics reset when
// the server restarts and never contain account, message, or IP data.
type Collector struct {
	mu       sync.Mutex
	samples  []Sample
	capacity int
	next     int
	total    int64
	rates    map[[sha256.Size]byte]rateState
	rateSalt [sha256.Size]byte
}

// New creates a bounded collector. Non-positive capacity uses a safe default.
func New(capacity int) *Collector {
	if capacity <= 0 {
		capacity = defaultCapacity
	}
	collector := &Collector{
		capacity: capacity,
		samples:  make([]Sample, 0, capacity),
		rates:    make(map[[sha256.Size]byte]rateState),
	}
	_, _ = rand.Read(collector.rateSalt[:])
	return collector
}

// Record validates and retains a report.
func (c *Collector) Record(report Report, receivedAt time.Time) error {
	if err := normalizeReport(&report); err != nil {
		return err
	}
	if receivedAt.IsZero() {
		receivedAt = time.Now()
	}
	sample := Sample{Report: report, ReceivedAt: receivedAt}

	c.mu.Lock()
	defer c.mu.Unlock()
	c.total++
	if len(c.samples) < c.capacity {
		c.samples = append(c.samples, sample)
		return nil
	}
	c.samples[c.next] = sample
	c.next = (c.next + 1) % c.capacity
	return nil
}

// Snapshot returns aggregate values without exposing individual clients.
func (c *Collector) Snapshot() Snapshot {
	c.mu.Lock()
	samples := append([]Sample(nil), c.samples...)
	total := c.total
	c.mu.Unlock()

	var last time.Time
	cold := make([]Sample, 0, len(samples))
	warm := make([]Sample, 0, len(samples))
	for _, sample := range samples {
		if sample.ReceivedAt.After(last) {
			last = sample.ReceivedAt
		}
		if sample.LoadKind == "warm" {
			warm = append(warm, sample)
		} else {
			cold = append(cold, sample)
		}
	}
	return Snapshot{
		TotalSamples:    total,
		RetainedSamples: len(samples),
		Cold:            summarize(cold, coldTargetMS),
		Warm:            summarize(warm, warmTargetMS),
		LastSampleAt:    last,
	}
}

func summarize(samples []Sample, target int64) Summary {
	result := Summary{Samples: len(samples), TargetMS: target}
	if len(samples) == 0 {
		return result
	}
	interactive := make([]int64, 0, len(samples))
	var fcpTotal, transferTotal, hits, resources, within int64
	for _, sample := range samples {
		interactive = append(interactive, sample.InteractiveMS)
		fcpTotal += sample.FirstContentfulPaintMS
		transferTotal += sample.TransferBytes
		hits += sample.CacheHits
		resources += sample.ResourceCount
		if sample.InteractiveMS <= target {
			within++
		}
	}
	sort.Slice(interactive, func(i, j int) bool { return interactive[i] < interactive[j] })
	result.P50InteractiveMS = percentile(interactive, 0.50)
	result.P95InteractiveMS = percentile(interactive, 0.95)
	result.AverageFCPMS = fcpTotal / int64(len(samples))
	result.AverageTransferBytes = transferTotal / int64(len(samples))
	result.WithinTargetPercent = roundPercent(float64(within) / float64(len(samples)) * 100)
	if resources > 0 {
		result.ResourceCacheHitPercent = roundPercent(float64(hits) / float64(resources) * 100)
	}
	return result
}

func percentile(values []int64, percentile float64) int64 {
	if len(values) == 0 {
		return 0
	}
	index := int(math.Ceil(float64(len(values))*percentile)) - 1
	if index < 0 {
		index = 0
	}
	if index >= len(values) {
		index = len(values) - 1
	}
	return values[index]
}

func roundPercent(value float64) float64 {
	return math.Round(value*10) / 10
}

func normalizeReport(report *Report) error {
	report.Version = strings.TrimSpace(report.Version)
	report.LoadKind = strings.ToLower(strings.TrimSpace(report.LoadKind))
	report.NavigationType = strings.ToLower(strings.TrimSpace(report.NavigationType))
	report.ConnectionType = strings.ToLower(strings.TrimSpace(report.ConnectionType))
	if report.Version == "" {
		report.Version = "unknown"
	}
	if len(report.Version) > 64 || len(report.NavigationType) > 24 || len(report.ConnectionType) > 24 {
		return errors.New("performance metadata is too long")
	}
	if report.LoadKind != "cold" && report.LoadKind != "warm" {
		return errors.New("load_kind must be cold or warm")
	}
	if report.InteractiveMS <= 0 || report.InteractiveMS > 10*60*1000 {
		return errors.New("interactive_ms is out of range")
	}
	if report.FirstContentfulPaintMS < 0 || report.FirstContentfulPaintMS > 10*60*1000 {
		return errors.New("first_contentful_paint_ms is out of range")
	}
	if report.TransferBytes < 0 || report.TransferBytes > 2*1024*1024*1024 ||
		report.DecodedBytes < 0 || report.DecodedBytes > 2*1024*1024*1024 {
		return errors.New("resource bytes are out of range")
	}
	if report.ResourceCount < 0 || report.ResourceCount > 10000 ||
		report.CacheHits < 0 || report.CacheHits > report.ResourceCount {
		return errors.New("resource counts are out of range")
	}
	return nil
}

// ServeHTTP accepts same-site JSON reports with bounded request and rate limits.
func (c *Collector) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if site := strings.ToLower(strings.TrimSpace(r.Header.Get("Sec-Fetch-Site"))); site == "cross-site" {
		http.Error(w, "cross-site report rejected", http.StatusForbidden)
		return
	}
	if !c.allow(clientIP(r), time.Now()) {
		w.Header().Set("Retry-After", "60")
		http.Error(w, "report rate exceeded", http.StatusTooManyRequests)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var report Report
	if err := decoder.Decode(&report); err != nil {
		http.Error(w, "invalid performance report", http.StatusBadRequest)
		return
	}
	if err := ensureJSONEnd(decoder); err != nil {
		http.Error(w, "invalid performance report", http.StatusBadRequest)
		return
	}
	if err := c.Record(report, time.Now()); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func ensureJSONEnd(decoder *json.Decoder) error {
	var extra interface{}
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("multiple JSON values")
	}
	return err
}

func (c *Collector) allow(ip string, now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.rates) >= maxRateClients {
		for key, value := range c.rates {
			if now.Sub(value.started) >= rateWindow {
				delete(c.rates, key)
			}
		}
	}
	key := c.rateKey(ip)
	state, exists := c.rates[key]
	if !exists && len(c.rates) >= maxRateClients {
		return false
	}
	if state.started.IsZero() || now.Sub(state.started) >= rateWindow {
		state = rateState{started: now}
	}
	state.count++
	c.rates[key] = state
	return state.count <= maxReportsPerIP
}

func (c *Collector) rateKey(ip string) [sha256.Size]byte {
	hash := sha256.New()
	_, _ = hash.Write(c.rateSalt[:])
	_, _ = hash.Write([]byte(ip))
	var key [sha256.Size]byte
	copy(key[:], hash.Sum(nil))
	return key
}

func clientIP(r *http.Request) string {
	if value := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(value) != nil {
		return value
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}
