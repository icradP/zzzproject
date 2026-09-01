"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  ProgressTracker,
  formatBytes,
  selectedStartupPaths,
} = require("../web/loading.js");

test("ProgressTracker combines measured startup resources", () => {
  const tracker = new ProgressTracker();
  tracker.setExpected({ "main.dart.js": 100, "canvaskit.wasm": 300 });
  tracker.update("main.dart.js", 40);
  let snapshot = tracker.snapshot();
  assert.equal(snapshot.loaded, 40);
  assert.equal(snapshot.total, 400);
  assert.equal(snapshot.percent, 10);

  tracker.complete("main.dart.js", 100);
  tracker.complete("canvaskit.wasm", 300);
  snapshot = tracker.snapshot();
  assert.equal(snapshot.loaded, 400);
  assert.equal(snapshot.percent, 100);
  assert.equal(snapshot.completed, 2);
});

test("ProgressTracker completes pending resources when the app is ready", () => {
  const tracker = new ProgressTracker();
  tracker.setExpected({ "main.dart.js": 100, "canvaskit.wasm": 300 });
  tracker.update("main.dart.js", 75);

  tracker.completeAll();

  const snapshot = tracker.snapshot();
  assert.equal(snapshot.loaded, 400);
  assert.equal(snapshot.percent, 100);
  assert.equal(snapshot.completed, 2);
});

test("formatBytes keeps loading labels compact", () => {
  assert.equal(formatBytes(0), "0 B");
  assert.equal(formatBytes(1024), "1.00 KB");
  assert.equal(formatBytes(5 * 1024 * 1024), "5.00 MB");
});

test("selectedStartupPaths chooses the compatible CanvasKit build", () => {
  const defaults = selectedStartupPaths({ vendor: "Apple Computer, Inc." });
  assert.ok(defaults.includes("canvaskit/canvaskit.wasm"));
  assert.ok(!defaults.includes("canvaskit/chromium/canvaskit.wasm"));
});
