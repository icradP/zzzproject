{{flutter_js}}
{{flutter_build_config}}

const appServiceWorkerVersion = {{flutter_service_worker_version}};

function markFlutterReady() {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      document.documentElement.classList.add("flutter-ready");
      window.setTimeout(() => {
        document.getElementById("app-loading")?.remove();
      }, 240);
    });
  });
}

function cacheRendererAssets(registration) {
  const supportsChromiumCanvasKit =
    navigator.vendor === "Google Inc." &&
    typeof ImageDecoder !== "undefined" &&
    typeof Intl.v8BreakIterator !== "undefined";
  const rendererRoot = supportsChromiumCanvasKit
    ? "canvaskit/chromium/"
    : "canvaskit/";
  const message = {
    type: "cache-urls",
    urls: [`${rendererRoot}canvaskit.js`, `${rendererRoot}canvaskit.wasm`],
  };
  const worker =
    registration.active || registration.waiting || registration.installing;
  if (!worker) return;
  if (worker.state === "activated") {
    worker.postMessage(message);
    return;
  }
  worker.addEventListener("statechange", () => {
    if (worker.state === "activated") worker.postMessage(message);
  });
}

async function registerAppServiceWorker() {
  if (!("serviceWorker" in navigator)) return;
  try {
    const workerUrl = new URL("app-sw.js", document.baseURI);
    workerUrl.searchParams.set("v", appServiceWorkerVersion);
    const registration = await navigator.serviceWorker.register(workerUrl);
    cacheRendererAssets(registration);
  } catch (error) {
    console.warn("Unable to register the app service worker.", error);
  }
}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine();
    await appRunner.runApp();
    markFlutterReady();
    void registerAppServiceWorker();
  },
});
