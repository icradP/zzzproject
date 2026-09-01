(function (root, factory) {
  "use strict";

  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  if (root && root.document) {
    root.zzzLoading = api.createBrowserLoading(root);
  }
})(typeof window !== "undefined" ? window : null, function () {
  "use strict";

  class ProgressTracker {
    constructor() {
      this.resources = new Map();
    }

    setExpected(resources) {
      for (const [key, total] of Object.entries(resources || {})) {
        const size = Number(total);
        if (!Number.isFinite(size) || size <= 0) continue;
        const current = this.resources.get(key) || {
          loaded: 0,
          total: 0,
          complete: false,
        };
        current.total = size;
        this.resources.set(key, current);
      }
    }

    update(key, loaded, total) {
      const current = this.resources.get(key) || {
        loaded: 0,
        total: 0,
        complete: false,
      };
      const nextLoaded = Number(loaded);
      const nextTotal = Number(total);
      if (Number.isFinite(nextLoaded) && nextLoaded >= 0) {
        current.loaded = Math.max(current.loaded, nextLoaded);
      }
      if (Number.isFinite(nextTotal) && nextTotal > 0) {
        current.total = nextTotal;
      }
      this.resources.set(key, current);
    }

    complete(key, loaded) {
      this.update(key, loaded, 0);
      const current = this.resources.get(key);
      current.complete = true;
      if (current.total > 0) current.loaded = current.total;
    }

    completeAll() {
      for (const key of this.resources.keys()) {
        this.complete(key, 0);
      }
    }

    snapshot() {
      let loaded = 0;
      let total = 0;
      let completed = 0;
      for (const resource of this.resources.values()) {
        total += resource.total;
        loaded +=
          resource.total > 0
            ? Math.min(resource.loaded, resource.total)
            : resource.loaded;
        if (resource.complete) completed += 1;
      }
      const measurable = total > 0;
      return {
        loaded,
        total,
        completed,
        resources: this.resources.size,
        measurable,
        percent: measurable ? Math.min(100, (loaded / total) * 100) : null,
      };
    }
  }

  function formatBytes(bytes) {
    let value = Math.max(0, Number(bytes) || 0);
    const units = ["B", "KB", "MB", "GB"];
    let index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    const precision = index === 0 ? 0 : value >= 10 ? 1 : 2;
    return `${value.toFixed(precision)} ${units[index]}`;
  }

  function selectedStartupPaths(navigatorValue) {
    const useChromiumCanvasKit =
      navigatorValue &&
      navigatorValue.vendor === "Google Inc." &&
      typeof ImageDecoder !== "undefined" &&
      typeof Intl.v8BreakIterator !== "undefined";
    const rendererRoot = useChromiumCanvasKit
      ? "canvaskit/chromium/"
      : "canvaskit/";
    return [
      "main.dart.js",
      `${rendererRoot}canvaskit.js`,
      `${rendererRoot}canvaskit.wasm`,
    ];
  }

  function createBrowserLoading(global) {
    const documentValue = global.document;
    const rootElement = documentValue.getElementById("app-loading");
    const stageElement = documentValue.getElementById("app-loading-stage");
    const detailElement = documentValue.getElementById("app-loading-detail");
    const progressElement = documentValue.getElementById(
      "app-loading-progress",
    );
    const bytesElement = documentValue.getElementById("app-loading-bytes");
    const percentElement = documentValue.getElementById(
      "app-loading-percent",
    );
    const networkElement = documentValue.getElementById(
      "app-loading-network",
    );
    const retryButton = documentValue.getElementById("app-loading-retry");
    const tracker = new ProgressTracker();
    const startupPaths = new Set(selectedStartupPaths(global.navigator));
    const initialFetch = global.fetch.bind(global);
    const loadKind =
      global.navigator.serviceWorker &&
      global.navigator.serviceWorker.controller
        ? "warm"
        : "cold";
    let buildVersion = "unknown";
    let entrypointObjectURL = null;
    let performanceObserver = null;
    let ready = false;
    let failed = false;

    function resourceKey(value) {
      let url;
      try {
        url = new URL(value, documentValue.baseURI);
      } catch (_) {
        return null;
      }
      const scope = new URL(".", documentValue.baseURI);
      if (url.origin !== scope.origin || !url.href.startsWith(scope.href)) {
        return null;
      }
      return url.href.slice(scope.href.length).split(/[?#]/, 1)[0];
    }

    function renderProgress() {
      if (!progressElement || !bytesElement || !percentElement) return;
      const progress = tracker.snapshot();
      if (!progress.measurable) {
        progressElement.classList.add("measuring");
        progressElement.removeAttribute("aria-valuenow");
        bytesElement.textContent =
          progress.loaded > 0
            ? `${formatBytes(progress.loaded)} loaded`
            : "Measuring download";
        percentElement.textContent = "";
        return;
      }
      const percent = Math.min(ready ? 100 : 99, progress.percent || 0);
      progressElement.classList.remove("measuring");
      progressElement.style.setProperty(
        "--loading-progress",
        String(percent / 100),
      );
      progressElement.setAttribute("aria-valuemin", "0");
      progressElement.setAttribute("aria-valuemax", "100");
      progressElement.setAttribute("aria-valuenow", String(Math.round(percent)));
      bytesElement.textContent = `${formatBytes(progress.loaded)} of ${formatBytes(progress.total)}`;
      percentElement.textContent = `${Math.round(percent)}%`;
    }

    function setStage(stage, detail) {
      if (stageElement) stageElement.textContent = stage;
      if (detailElement && detail !== undefined) {
        detailElement.textContent = detail;
      }
    }

    function setConnectivity() {
      if (!networkElement) return;
      networkElement.textContent = global.navigator.onLine
        ? ""
        : "Offline - using cached files where available";
    }

    function resourceStage(key) {
      if (key === "main.dart.js") {
        setStage("Downloading application", "Loading the client bundle");
      } else if (key.includes("canvaskit")) {
        setStage("Starting renderer", "Preparing graphics resources");
      }
    }

    function wrapTrackedResponse(key, response) {
      if (!startupPaths.has(key) || !response.ok) return response;
      const encoding = response.headers.get("content-encoding");
      const headerSize = Number(response.headers.get("content-length"));
      if (!encoding && Number.isFinite(headerSize) && headerSize > 0) {
        tracker.update(key, 0, headerSize);
        renderProgress();
      }
      resourceStage(key);
      if (!response.body || typeof ReadableStream === "undefined") {
        tracker.complete(key, headerSize);
        renderProgress();
        return response;
      }

      const reader = response.body.getReader();
      let loaded = 0;
      const stream = new ReadableStream({
        async pull(controller) {
          try {
            const result = await reader.read();
            if (result.done) {
              tracker.complete(key, loaded);
              renderProgress();
              controller.close();
              return;
            }
            loaded += result.value.byteLength;
            tracker.update(key, loaded, 0);
            renderProgress();
            controller.enqueue(result.value);
          } catch (error) {
            controller.error(error);
          }
        },
        cancel(reason) {
          return reader.cancel(reason);
        },
      });
      return new Response(stream, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers,
      });
    }

    global.fetch = async function trackedFetch(input, init) {
      const response = await initialFetch(input, init);
      const value = input instanceof Request ? input.url : input;
      const key = resourceKey(value);
      return key ? wrapTrackedResponse(key, response) : response;
    };

    const manifestPromise = initialFetch(
      new URL("startup-assets.json", documentValue.baseURI),
      { cache: "no-cache", credentials: "same-origin" },
    )
      .then((response) => {
        if (!response.ok) throw new Error("startup asset manifest unavailable");
        return response.json();
      })
      .then((manifest) => {
        buildVersion = String(manifest.version || "unknown").slice(0, 64);
        const selected = {};
        for (const path of startupPaths) {
          if (Number(manifest.startup?.[path]) > 0) {
            selected[path] = Number(manifest.startup[path]);
          }
        }
        tracker.setExpected(selected);
        renderProgress();
        return manifest;
      })
      .catch((error) => {
        console.warn("Unable to load startup asset sizes.", error);
        return null;
      });

    if (typeof PerformanceObserver !== "undefined") {
      try {
        performanceObserver = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            const key = resourceKey(entry.name);
            if (!key || !startupPaths.has(key)) continue;
            const loaded = entry.decodedBodySize || entry.encodedBodySize || 0;
            tracker.complete(key, loaded);
          }
          renderProgress();
        });
        performanceObserver.observe({ type: "resource", buffered: true });
      } catch (_) {
        // Resource timing observation is optional.
      }
    }

    async function prepareEntrypoint(path) {
      await manifestPromise;
      setStage("Downloading application", "Loading the client bundle");
      const response = await global.fetch(new URL(path, documentValue.baseURI), {
        cache: "default",
        credentials: "same-origin",
      });
      if (!response.ok) {
        throw new Error(`Application download failed (${response.status})`);
      }
      const blob = await response.blob();
      entrypointObjectURL = URL.createObjectURL(
        new Blob([blob], { type: "application/javascript" }),
      );
      return entrypointObjectURL;
    }

    function friendlyError(error) {
      if (!global.navigator.onLine) {
        return "Connect to the internet and try again.";
      }
      const message = String(error && error.message ? error.message : error);
      if (/fetch|network|download|load failed/i.test(message)) {
        return "The application files could not be downloaded.";
      }
      return "The application could not be started.";
    }

    function fail(error) {
      if (ready || failed) return;
      failed = true;
      console.error("ZZZ IM startup failed.", error);
      rootElement?.classList.add("failed");
      setStage("Could not start ZZZ IM", friendlyError(error));
      if (retryButton) retryButton.hidden = false;
    }

    function collectPerformance() {
      const scope = new URL(".", documentValue.baseURI);
      const resources = global.performance
        .getEntriesByType("resource")
        .filter((entry) => entry.name.startsWith(scope.href));
      const paints = global.performance.getEntriesByType("paint");
      const firstPaint = paints.find(
        (entry) => entry.name === "first-contentful-paint",
      );
      const navigation = global.performance.getEntriesByType("navigation")[0];
      const report = {
        version: buildVersion,
        load_kind: loadKind,
        navigation_type: String(navigation?.type || "navigate").slice(0, 24),
        interactive_ms: Math.max(0, Math.round(global.performance.now())),
        first_contentful_paint_ms: Math.max(
          0,
          Math.round(firstPaint?.startTime || 0),
        ),
        transfer_bytes: resources.reduce(
          (total, entry) => total + Math.max(0, entry.transferSize || 0),
          0,
        ),
        decoded_bytes: resources.reduce(
          (total, entry) => total + Math.max(0, entry.decodedBodySize || 0),
          0,
        ),
        cache_hits: resources.filter(
          (entry) => entry.transferSize === 0 && entry.decodedBodySize > 0,
        ).length,
        resource_count: resources.length,
        connection_type: String(
          global.navigator.connection?.effectiveType || "unknown",
        ).slice(0, 24),
      };

      try {
        const key = "zzz.im.performance.samples";
        const previous = JSON.parse(global.localStorage.getItem(key) || "[]");
        const samples = Array.isArray(previous) ? previous : [];
        samples.push({ ...report, recorded_at: new Date().toISOString() });
        global.localStorage.setItem(key, JSON.stringify(samples.slice(-20)));
      } catch (_) {
        // Private browsing may disable persistent storage.
      }

      const endpoint = documentValue.querySelector(
        'meta[name="zzz-performance-endpoint"]',
      )?.content;
      if (!endpoint) return;
      const body = JSON.stringify(report);
      const url = new URL(endpoint, global.location.origin);
      if (typeof global.navigator.sendBeacon === "function") {
        global.navigator.sendBeacon(
          url,
          new Blob([body], { type: "application/json" }),
        );
        return;
      }
      void initialFetch(url, {
        method: "POST",
        body,
        headers: { "Content-Type": "application/json" },
        keepalive: true,
      }).catch(() => {});
    }

    function complete() {
      if (ready) return;
      ready = true;
      tracker.completeAll();
      renderProgress();
      global.fetch = initialFetch;
      performanceObserver?.disconnect();
      global.clearTimeout(slowTimer);
      global.clearTimeout(retryTimer);
      global.removeEventListener("online", setConnectivity);
      global.removeEventListener("offline", setConnectivity);
      global.removeEventListener("error", handleWindowError);
      global.removeEventListener("unhandledrejection", handleRejection);
      global.setTimeout(collectPerformance, 0);
      if (entrypointObjectURL) {
        global.setTimeout(() => URL.revokeObjectURL(entrypointObjectURL), 0);
      }
    }

    function handleWindowError(event) {
      fail(event.error || event.message);
    }

    function handleRejection(event) {
      fail(event.reason);
    }

    retryButton?.addEventListener("click", () => global.location.reload());
    global.addEventListener("online", setConnectivity);
    global.addEventListener("offline", setConnectivity);
    global.addEventListener("error", handleWindowError);
    global.addEventListener("unhandledrejection", handleRejection);
    setConnectivity();
    renderProgress();

    const slowTimer = global.setTimeout(() => {
      if (!ready && !failed) {
        setStage("Still loading", "The network is slower than expected");
      }
    }, 12000);
    const retryTimer = global.setTimeout(() => {
      if (!ready && !failed && retryButton) retryButton.hidden = false;
    }, 20000);

    return {
      complete,
      fail,
      prepareEntrypoint,
      setStage,
    };
  }

  return {
    ProgressTracker,
    createBrowserLoading,
    formatBytes,
    selectedStartupPaths,
  };
});
