"use strict";

self.addEventListener("push", (event) => {
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({
        type: "window",
        includeUncontrolled: true,
      });
      if (windows.some((client) => client.visibilityState === "visible")) return;

      let payload = {};
      if (event.data) {
        try {
          payload = event.data.json();
        } catch (_) {
          payload = { body: event.data.text() };
        }
      }

      const appRoot = new URL("../", self.registration.scope);
      const conversationId = String(payload.conversation_id || "");
      const target = new URL(appRoot.href);
      if (conversationId) {
        target.hash = `/chat/${encodeURIComponent(conversationId)}`;
      }

      await self.registration.showNotification(payload.title || "ZZZ IM", {
        body: payload.body || "You have a new message.",
        icon: new URL("icons/Icon-192.png", appRoot).href,
        badge: new URL("icons/Icon-192.png", appRoot).href,
        tag: conversationId ? `conversation-${conversationId}` : undefined,
        renotify: Boolean(conversationId),
        data: { url: target.href },
      });
    })(),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    (async () => {
      const target = event.notification.data?.url;
      const windows = await self.clients.matchAll({
        type: "window",
        includeUncontrolled: true,
      });
      for (const client of windows) {
        if (target && "navigate" in client) await client.navigate(target);
        return client.focus();
      }
      return target ? self.clients.openWindow(target) : undefined;
    })(),
  );
});
