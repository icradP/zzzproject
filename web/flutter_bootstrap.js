{{flutter_js}}
{{flutter_build_config}}

const appServiceWorkerVersion = {{flutter_service_worker_version}};
const loading = window.zzzLoading;

function markFlutterReady() {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      loading?.complete();
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
    registration.installing || registration.waiting || registration.active;
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

async function startApplication() {
  try {
    if (loading) {
      const entrypoint = await loading.prepareEntrypoint("main.dart.js");
      for (const build of _flutter.buildConfig.builds) {
        if (build.compileTarget === "dart2js") build.mainJsPath = entrypoint;
      }
    }
    loading?.setStage("Starting renderer", "Preparing graphics resources");
    await _flutter.loader.load({
      config: {
        canvasKitBaseUrl: "canvaskit/",
      },
      onEntrypointLoaded: async (engineInitializer) => {
        try {
          loading?.setStage("Initializing client", "Opening your workspace");
          const appRunner = await engineInitializer.initializeEngine();
          loading?.setStage("Almost ready", "Starting ZZZ IM");
          await appRunner.runApp();
          markFlutterReady();
          void registerAppServiceWorker();
        } catch (error) {
          loading?.fail(error);
          throw error;
        }
      },
    });
  } catch (error) {
    loading?.fail(error);
  }
}

void startApplication();
