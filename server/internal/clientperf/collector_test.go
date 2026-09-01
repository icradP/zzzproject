package clientperf

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCollectorSummarizesColdAndWarmTargets(t *testing.T) {
	collector := New(10)
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	reports := []Report{
		{LoadKind: "cold", InteractiveMS: 6000, FirstContentfulPaintMS: 1000, TransferBytes: 1000, CacheHits: 1, ResourceCount: 10},
		{LoadKind: "cold", InteractiveMS: 9000, FirstContentfulPaintMS: 2000, TransferBytes: 3000, CacheHits: 3, ResourceCount: 10},
		{LoadKind: "warm", InteractiveMS: 1500, FirstContentfulPaintMS: 500, TransferBytes: 500, CacheHits: 8, ResourceCount: 10},
	}
	for index, report := range reports {
		if err := collector.Record(report, now.Add(time.Duration(index)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}

	snapshot := collector.Snapshot()
	if snapshot.TotalSamples != 3 || snapshot.Cold.Samples != 2 || snapshot.Warm.Samples != 1 {
		t.Fatalf("unexpected sample counts: %#v", snapshot)
	}
	if snapshot.Cold.P50InteractiveMS != 6000 || snapshot.Cold.P95InteractiveMS != 9000 {
		t.Fatalf("unexpected cold percentiles: %#v", snapshot.Cold)
	}
	if snapshot.Cold.WithinTargetPercent != 50 || snapshot.Warm.WithinTargetPercent != 100 {
		t.Fatalf("unexpected target rates: cold=%v warm=%v", snapshot.Cold.WithinTargetPercent, snapshot.Warm.WithinTargetPercent)
	}
	if snapshot.Warm.ResourceCacheHitPercent != 80 {
		t.Fatalf("unexpected warm cache rate: %#v", snapshot.Warm)
	}
}

func TestCollectorHTTPValidationAndPrivacyBoundary(t *testing.T) {
	collector := New(2)
	valid := Report{
		Version: "build-one", LoadKind: "warm", NavigationType: "reload",
		InteractiveMS: 1200, FirstContentfulPaintMS: 400,
		TransferBytes: 512, DecodedBytes: 1024, CacheHits: 4, ResourceCount: 5,
		ConnectionType: "4g",
	}
	body, _ := json.Marshal(valid)
	request := httptest.NewRequest(http.MethodPost, "/client-performance", bytes.NewReader(body))
	request.RemoteAddr = "192.0.2.1:1234"
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	collector.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("valid report status=%d body=%s", response.Code, response.Body.String())
	}

	unknown := append(body[:len(body)-1], []byte(`,"user_id":"alice"}`)...)
	request = httptest.NewRequest(http.MethodPost, "/client-performance", bytes.NewReader(unknown))
	request.RemoteAddr = "192.0.2.2:1234"
	response = httptest.NewRecorder()
	collector.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("identity field status=%d", response.Code)
	}

	request = httptest.NewRequest(http.MethodPost, "/client-performance", bytes.NewReader(body))
	request.RemoteAddr = "192.0.2.3:1234"
	request.Header.Set("Sec-Fetch-Site", "cross-site")
	response = httptest.NewRecorder()
	collector.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("cross-site status=%d", response.Code)
	}
}

func TestCollectorRetentionIsBounded(t *testing.T) {
	collector := New(2)
	for index := int64(1); index <= 3; index++ {
		if err := collector.Record(Report{
			LoadKind: "cold", InteractiveMS: index * 1000,
		}, time.Unix(index, 0)); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := collector.Snapshot()
	if snapshot.TotalSamples != 3 || snapshot.RetainedSamples != 2 || snapshot.Cold.P50InteractiveMS != 2000 {
		t.Fatalf("unexpected retained snapshot: %#v", snapshot)
	}
}

func TestCollectorRateStateIsBounded(t *testing.T) {
	collector := New(1)
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	for index := 0; index < maxRateClients; index++ {
		if !collector.allow(fmt.Sprintf("192.0.2.%d", index), now) {
			t.Fatalf("client %d was rejected before the limiter reached capacity", index)
		}
	}
	if collector.allow("198.51.100.1", now) {
		t.Fatal("new client was accepted after rate state reached capacity")
	}
	if len(collector.rates) != maxRateClients {
		t.Fatalf("rate state grew beyond its bound: %d", len(collector.rates))
	}
}
