"use strict";

const workerUrl = new URL(self.location.href);
const version = workerUrl.searchParams.get("v") || "development";
const cachePrefix = "zzz-im-app-";
const cacheName = `${cachePrefix}${version}`;
const scopeUrl = new URL(self.registration.scope);
const shellResources = [
  "index.html",
  "flutter_bootstrap.js",
  "main.dart.js",
  "manifest.json",
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
  "flutter_bootstrap.js",
  "main.dart.js",
  "manifest.json",
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

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(cacheName);
      await Promise.allSettled(
        shellResources.map((path) => cacheResponse(cache, path)),
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

async function networkFirst(request, fallbackPath) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  } catch (_) {
    return (
      (await cache.match(request)) ||
      (await cache.match(scopedUrl(fallbackPath))) ||
      Response.error()
    );
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  const update = fetch(request)
    .then(async (response) => {
      if (response.ok) await cache.put(request, response.clone());
      return response;
    })
    .catch(() => null);
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
    event.respondWith(staleWhileRevalidate(request));
  }
});
