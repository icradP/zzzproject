"use strict";

const workerUrl = new URL(self.location.href);
const version = workerUrl.searchParams.get("v") || "development";
const cachePrefix = "zzz-im-app-";
const cacheName = `${cachePrefix}${version}`;
const scopeUrl = new URL(self.registration.scope);
const manifestPath = "startup-assets.json";
const shellResources = [
  "index.html",
  "loading.js",
  "flutter_bootstrap.js",
  "main.dart.js",
  "manifest.json",
  manifestPath,
  "push_client.js",
  "assets/AssetManifest.bin",
  "assets/AssetManifest.bin.json",
  "assets/FontManifest.json",
  "assets/fonts/MaterialIcons-Regular.otf",
  "assets/packages/cupertino_icons/assets/CupertinoIcons.ttf",
  "assets/assets/font/inpinhongmengti.ttf",
  "assets/assets/images/bg_chat_with_pattern_dark_2.png",
  "icons/Icon-192.png",
  "icons/Icon-512.png",
];
const networkFirstResources = new Set([
  "index.html",
  "loading.js",
  "flutter_bootstrap.js",
  "main.dart.js",
  "manifest.json",
  "startup-assets.json",
]);

function scopedUrl(path) {
  return new URL(path, scopeUrl).href;
}

function relativePath(url) {
  if (!url.href.startsWith(scopeUrl.href)) return null;
  return url.href.slice(scopeUrl.href.length).split(/[?#]/, 1)[0];
}

async function cacheResponse(cache, path) {
  const url = new URL(path, scopeUrl);
  if (url.origin !== scopeUrl.origin || !url.href.startsWith(scopeUrl.href)) {
    return;
  }
  const response = await fetch(new Request(url, { cache: "no-cache" }));
  if (response.ok) await cache.put(url, response);
}

async function readManifest(cache) {
  const response = await cache.match(scopedUrl(manifestPath));
  if (!response) return null;
  try {
    const manifest = await response.json();
    return manifest && typeof manifest.resources === "object" ? manifest : null;
  } catch (_) {
    return null;
  }
}

async function fetchManifest() {
  const response = await fetch(
    new Request(scopedUrl(manifestPath), { cache: "no-cache" }),
  );
  if (!response.ok) {
    throw new Error(`Startup asset manifest unavailable (${response.status})`);
  }
  const manifest = await response.clone().json();
  if (!manifest || typeof manifest.resources !== "object") {
    throw new Error("Startup asset manifest is invalid");
  }
  return { manifest, response };
}

function sameResource(previousManifest, nextManifest, path) {
  const previous = previousManifest?.resources?.[path];
  const next = nextManifest?.resources?.[path];
  return Boolean(
    previous &&
      next &&
      previous.bytes === next.bytes &&
      typeof previous.sha256 === "string" &&
      previous.sha256 === next.sha256,
  );
}

async function seedUnchangedResources(cache, nextManifest) {
  const keys = await caches.keys();
  const previousKey = keys.find(
    (key) => key.startsWith(cachePrefix) && key !== cacheName,
  );
  if (!previousKey) return;
  const previous = await caches.open(previousKey);
  const previousManifest = await readManifest(previous);
  if (!previousManifest) return;
  await Promise.allSettled(
    Object.keys(nextManifest.resources).map(async (path) => {
      if (!sameResource(previousManifest, nextManifest, path)) return;
      const url = scopedUrl(path);
      const cached = await previous.match(url);
      if (cached) await cache.put(url, cached);
    }),
  );
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(cacheName);
      const { manifest, response } = await fetchManifest();
      await seedUnchangedResources(cache, manifest);
      await cache.put(scopedUrl(manifestPath), response);
      await Promise.allSettled(
        shellResources
          .filter((path) => path !== manifestPath)
          .map(async (path) => {
            if (!(await cache.match(scopedUrl(path)))) {
              await cacheResponse(cache, path);
            }
          }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((key) => key.startsWith(cachePrefix) && key !== cacheName)
          .map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("message", (event) => {
  if (event.data?.type !== "cache-urls" || !Array.isArray(event.data.urls)) {
    return;
  }
  event.waitUntil(
    (async () => {
      const cache = await caches.open(cacheName);
      await Promise.allSettled(
        event.data.urls.map((path) => cacheResponse(cache, path)),
      );
    })(),
  );
});

function keepWorkerAlive(event, promise) {
  event.waitUntil(promise.catch(() => {}));
}

async function networkFirst(request, fallbackPath) {
  const cache = await caches.open(cacheName);
  try {
    return await fetch(request);
  } catch (_) {
    return (
      (await cache.match(request)) ||
      (await cache.match(scopedUrl(fallbackPath))) ||
      Response.error()
    );
  }
}

async function staleWhileRevalidate(event, request) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  const update = fetch(request)
    .then(async (response) => {
      if (response.ok) await cache.put(request, response.clone());
      return response;
    })
    .catch(() => null);
  keepWorkerAlive(event, update);
  return cached || (await update) || Response.error();
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== scopeUrl.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request, "index.html"));
    return;
  }

  const path = relativePath(url);
  if (path === null || path.startsWith("im/") || path.startsWith("files/")) {
    return;
  }
  if (networkFirstResources.has(path)) {
    event.respondWith(networkFirst(request, path));
    return;
  }
  if (
    path.startsWith("assets/") ||
    path.startsWith("canvaskit/") ||
    path.startsWith("icons/") ||
    /\.(?:js|json|png|svg|wasm|woff2?|ttf|otf)$/.test(path)
  ) {
    event.respondWith(staleWhileRevalidate(event, request));
  }
});
