(function () {
  "use strict";

  function isSupported() {
    return (
      window.isSecureContext &&
      "serviceWorker" in navigator &&
      "PushManager" in window &&
      "Notification" in window
    );
  }

  function permission() {
    return isSupported() ? Notification.permission : "unsupported";
  }

  function serviceWorkerUrl(path) {
    return new URL(path, document.baseURI).href;
  }

  async function registration() {
    if (!isSupported()) {
      throw new Error("Web Push is not supported in this browser.");
    }
    return navigator.serviceWorker.register(serviceWorkerUrl("push-sw.js"), {
      scope: serviceWorkerUrl("push/"),
    });
  }

  function decodeApplicationServerKey(value) {
    const padding = "=".repeat((4 - (value.length % 4)) % 4);
    const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/");
    const raw = window.atob(base64);
    return Uint8Array.from(raw, (character) => character.charCodeAt(0));
  }

  async function currentSubscription() {
    if (!isSupported()) return null;
    const worker = await registration();
    const subscription = await worker.pushManager.getSubscription();
    return subscription ? JSON.stringify(subscription.toJSON()) : null;
  }

  async function subscribe(publicKey) {
    const result = await Notification.requestPermission();
    if (result !== "granted") return null;

    const worker = await registration();
    const existing = await worker.pushManager.getSubscription();
    if (existing) return JSON.stringify(existing.toJSON());

    const subscription = await worker.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: decodeApplicationServerKey(publicKey),
    });
    return JSON.stringify(subscription.toJSON());
  }

  async function unsubscribe() {
    if (!isSupported()) return;
    const worker = await registration();
    const subscription = await worker.pushManager.getSubscription();
    if (subscription) await subscription.unsubscribe();
  }

  window.zzzPush = {
    isSupported,
    permission,
    currentSubscription,
    subscribe,
    unsubscribe,
  };
})();
