"use strict";

const state = {
  activeView: "dashboard",
  users: [],
  reports: [],
  selectedUserTitles: [],
  groups: [],
  conversations: [],
  messages: [],
  media: [],
  selectedGroup: null,
  selectedMessage: null,
  selectedMedia: null,
  toastTimer: null,
};

const loginView = document.querySelector("#login-view");
const appShell = document.querySelector("#app-shell");
const loginForm = document.querySelector("#login-form");
const loginError = document.querySelector("#login-error");
const pageTitle = document.querySelector("#page-title");
const toast = document.querySelector("#toast");

async function api(path, options = {}) {
  const request = { credentials: "same-origin", ...options };
  request.headers = { Accept: "application/json", ...(options.headers || {}) };
  if (request.body) request.headers["Content-Type"] = "application/json";
  if (["POST", "PATCH", "DELETE"].includes(request.method) && path !== "session") {
    request.headers["X-ZZZ-Admin"] = "1";
  }
  const response = await fetch(`api/${path}`, request);
  if (response.status === 401 && path !== "session") {
    showLogin();
    throw new Error("Admin session expired");
  }
  if (!response.ok) {
    let message = `Request failed (${response.status})`;
    try {
      const payload = await response.json();
      if (payload.error) message = payload.error;
    } catch (_) {
      // Keep the status-based fallback.
    }
    throw new Error(message);
  }
  if (response.status === 204) return null;
  return response.json();
}

function showLogin() {
  appShell.hidden = true;
  loginView.hidden = false;
  document.querySelector("#admin-token").focus();
}

function showApp() {
  loginView.hidden = true;
  appShell.hidden = false;
}

function showToast(message, isError = false) {
  window.clearTimeout(state.toastTimer);
  toast.textContent = message;
  toast.classList.toggle("error", isError);
  toast.classList.add("visible");
  state.toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 3200);
}

function element(tag, className, text) {
  const item = document.createElement(tag);
  if (className) item.className = className;
  if (text !== undefined) item.textContent = text;
  return item;
}

function formatDate(value) {
  if (!value || value.startsWith("0001-")) return "-";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function formatDuration(seconds) {
  const units = [
    [86400, "d"],
    [3600, "h"],
    [60, "m"],
  ];
  let remaining = Math.max(0, Number(seconds) || 0);
  const parts = [];
  for (const [size, suffix] of units) {
    const value = Math.floor(remaining / size);
    if (value > 0) parts.push(`${value}${suffix}`);
    remaining %= size;
    if (parts.length === 2) break;
  }
  return parts.length ? parts.join(" ") : `${Math.floor(remaining)}s`;
}

function formatMilliseconds(milliseconds) {
  const value = Math.max(0, Number(milliseconds) || 0);
  if (value < 1000) return `${Math.round(value)} ms`;
  return `${(value / 1000).toFixed(value >= 10000 ? 1 : 2)} s`;
}

function formatPercent(value) {
  return `${Math.max(0, Number(value) || 0).toFixed(1)}%`;
}

function formatBytes(bytes) {
  let value = Number(bytes) || 0;
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

function statusBadge(text, enabled) {
  const badge = element("span", `status-badge ${enabled ? "enabled" : "offline"}`, text);
  return badge;
}

function messageSummary(message) {
  if (message.recalled) return "Recalled message";
  const parts = (message.segments || []).map((segment) => {
    const data = segment.data || {};
    if (segment.type === "text") return String(data.text || "").trim();
    if (segment.type === "at") return `@${data.qq || data.user_id || "user"}`;
    const label = segment.type ? segment.type[0].toUpperCase() + segment.type.slice(1) : "Segment";
    return `[${label}] ${data.file || data.name || data.id || ""}`.trim();
  }).filter(Boolean);
  return parts.join(" ") || "Empty message";
}

function appendDetails(target, details) {
  target.replaceChildren(...details.map(([term, description, mono = false]) => {
    const wrapper = document.createElement("div");
    wrapper.append(element("dt", "", term), element("dd", mono ? "mono" : "", String(description)));
    return wrapper;
  }));
}

function safeMediaURL(file) {
  try {
    const resolved = new URL(file.url, window.location.href);
    return resolved.origin === window.location.origin ? resolved.href : "";
  } catch (_) {
    return "";
  }
}

async function loadOverview() {
  const payload = await api("overview");
  const stats = payload.stats;
  const items = [
    ["Users", stats.users, ""],
    ["Online", stats.online_users, "online"],
    ["Groups", stats.groups, ""],
    ["Conversations", stats.conversations, ""],
    ["Messages", stats.messages, "messages"],
    ["Sessions", stats.active_sessions, ""],
    ["Push devices", stats.push_subscriptions, ""],
    ["Media", formatBytes(stats.media_bytes), "storage"],
  ];
  const grid = document.querySelector("#stat-grid");
  grid.replaceChildren(...items.map(([label, value, style]) => {
    const card = element("div", `stat-item ${style}`);
    card.append(element("span", "eyebrow", label), element("strong", "", String(value)));
    return card;
  }));

  const service = payload.service;
  const details = [
    ["Storage", String(service.storage_driver).toUpperCase()],
    ["Uptime", formatDuration(service.uptime_seconds)],
    ["Started", formatDate(service.started_at)],
    ["Web Push", service.push_enabled ? "Enabled" : "Disabled"],
    ["Registration", service.registration_enabled ? "Enabled" : "Disabled"],
    ["Runtime", service.go_version],
  ];
  document.querySelector("#service-details").replaceChildren(...details.map(([term, description]) => {
    const wrapper = document.createElement("div");
    wrapper.append(element("dt", "", term), element("dd", "", description));
    return wrapper;
  }));
  const performance = payload.performance || {};
  const cold = performance.cold || {};
  const warm = performance.warm || {};
  const totalSamples = Number(performance.total_samples) || 0;
  const performanceDetails = document.querySelector("#performance-details");
  const performanceEmpty = document.querySelector("#performance-empty");
  const sampleCount = document.querySelector("#performance-sample-count");
  sampleCount.textContent = totalSamples === 1 ? "1 sample" : `${totalSamples} samples`;
  sampleCount.classList.toggle("enabled", totalSamples > 0);
  sampleCount.classList.toggle("offline", totalSamples === 0);
  performanceEmpty.hidden = totalSamples > 0;
  performanceDetails.hidden = totalSamples === 0;
  if (totalSamples > 0) {
    const unavailable = "No samples";
    appendDetails(performanceDetails, [
      ["Cold p50", cold.samples ? formatMilliseconds(cold.p50_interactive_ms) : unavailable],
      ["Cold p95", cold.samples ? formatMilliseconds(cold.p95_interactive_ms) : unavailable],
      ["Cold <= 8 s", cold.samples ? formatPercent(cold.within_target_percent) : unavailable],
      ["Warm p50", warm.samples ? formatMilliseconds(warm.p50_interactive_ms) : unavailable],
      ["Warm p95", warm.samples ? formatMilliseconds(warm.p95_interactive_ms) : unavailable],
      ["Warm <= 2 s", warm.samples ? formatPercent(warm.within_target_percent) : unavailable],
      ["Warm cache hits", warm.samples ? formatPercent(warm.resource_cache_hit_percent) : unavailable],
      ["Average transfer", warm.samples ? formatBytes(warm.average_transfer_bytes) : cold.samples ? formatBytes(cold.average_transfer_bytes) : unavailable],
      ["Latest sample", formatDate(performance.last_sample_at)],
    ]);
  } else {
    performanceDetails.replaceChildren();
  }
  document.querySelector("#overview-updated").textContent = `Updated ${formatDate(payload.generated_at)}`;
}

async function loadUsers() {
  const payload = await api("users");
  state.users = payload.users || [];
  renderUsers();
}

function renderUsers() {
  const query = document.querySelector("#user-search").value.trim().toLowerCase();
  const users = state.users.filter((user) => `${user.id} ${user.nickname}`.toLowerCase().includes(query));
  const rows = users.map((user) => {
    const row = document.createElement("tr");
    const identity = document.createElement("td");
    identity.append(element("span", "cell-title", user.nickname || user.id), element("span", "cell-subtitle mono", user.id));
    const status = document.createElement("td");
    status.append(statusBadge(user.online ? "Online" : "Offline", user.online));
    const created = element("td", "", formatDate(user.created_at));
    const actions = document.createElement("td");
    const edit = element("button", "table-button", "Manage");
    edit.type = "button";
    edit.addEventListener("click", () => openUserEditor(user));
    actions.append(edit);
    row.append(identity, status, created, actions);
    return row;
  });
  document.querySelector("#users-body").replaceChildren(...rows);
  document.querySelector("#users-empty").hidden = rows.length !== 0;
}

async function openUserEditor(user) {
  const dialog = document.querySelector("#edit-user-dialog");
  document.querySelector("#edit-user-id").textContent = user.id;
  document.querySelector("#edit-user-nickname").value = user.nickname || user.id;
  document.querySelector("#reset-password").value = "";
  document.querySelector("#reset-password-confirm").value = "";
  document.querySelector("#revoke-user-sessions").checked = true;
  document.querySelector("#reset-password-error").textContent = "";
  dialog.dataset.userId = user.id;
  dialog.showModal();
  await loadUserTitles(user.id);
}

async function loadUserTitles(userId) {
  const payload = await api(`titles?user_id=${encodeURIComponent(userId)}`);
  state.selectedUserTitles = payload.titles || [];
  renderUserTitles();
}

function renderUserTitles() {
  const target = document.querySelector("#user-title-list");
  if (!state.selectedUserTitles.length) {
    target.replaceChildren(element("p", "empty-state", "No active system titles."));
    return;
  }
  const items = state.selectedUserTitles.map((title) => {
    const item = element("div", "title-item");
    item.append(element("strong", "", title.text), element("span", "title-style", title.style));
    const remove = element("button", "table-button", "Revoke");
    remove.type = "button";
    remove.addEventListener("click", () => revokeTitle(title));
    item.append(remove);
    return item;
  });
  target.replaceChildren(...items);
}

async function revokeTitle(title) {
  try {
    await api("titles", { method: "DELETE", body: JSON.stringify({ title_id: title.title_id }) });
    showToast("Title revoked");
    await loadUserTitles(document.querySelector("#edit-user-dialog").dataset.userId);
  } catch (error) {
    showToast(error.message, true);
  }
}

async function loadReports() {
  const payload = await api("reports");
  state.reports = payload.reports || [];
  renderReports();
}

function renderReports() {
  const query = document.querySelector("#report-search").value.trim().toLowerCase();
  const reports = state.reports.filter((report) => `${report.target_id} ${report.reporter_id} ${report.reason} ${report.details || ""}`.toLowerCase().includes(query));
  const rows = reports.map((report) => {
    const row = document.createElement("tr");
    row.append(
      element("td", "mono", report.target_id),
      element("td", "mono", report.reporter_id),
      element("td", "", report.reason),
      element("td", "message-preview", report.details || "-"),
      element("td", "", formatDate(report.created_at)),
    );
    return row;
  });
  document.querySelector("#reports-body").replaceChildren(...rows);
  document.querySelector("#reports-empty").hidden = rows.length !== 0;
}

async function loadGroups() {
  const payload = await api("groups");
  state.groups = payload.groups || [];
  renderGroups();
}

function renderGroups() {
  const query = document.querySelector("#group-search").value.trim().toLowerCase();
  const groups = state.groups.filter((group) => `${group.id} ${group.name} ${group.owner_id}`.toLowerCase().includes(query));
  const rows = groups.map((group) => {
    const row = document.createElement("tr");
    const identity = document.createElement("td");
    identity.append(element("span", "cell-title", group.name), element("span", "cell-subtitle mono", group.id));
    const owner = element("td", "mono", group.owner_id);
    const members = element("td", "", String((group.members || []).length));
    const created = element("td", "", formatDate(group.created_at));
    const actions = document.createElement("td");
    const inspect = element("button", "table-button", "Open");
    inspect.type = "button";
    inspect.addEventListener("click", () => openGroup(group));
    actions.append(inspect);
    row.append(identity, owner, members, created, actions);
    return row;
  });
  document.querySelector("#groups-body").replaceChildren(...rows);
  document.querySelector("#groups-empty").hidden = rows.length !== 0;
}

function openGroup(group) {
  state.selectedGroup = group;
  document.querySelector("#group-dialog-title").textContent = group.name;
  document.querySelector("#group-member-count").textContent = String((group.members || []).length);
  const details = [
    ["Group ID", group.id],
    ["Owner", group.owner_id],
    ["Created", formatDate(group.created_at)],
    ["Mute all", group.mute_all ? "On" : "Off"],
  ];
  document.querySelector("#group-details").replaceChildren(...details.map(([term, description]) => {
    const wrapper = document.createElement("div");
    wrapper.append(element("dt", "", term), element("dd", term === "Group ID" || term === "Owner" ? "mono" : "", description));
    return wrapper;
  }));
  const memberRows = (group.members || []).map((member) => {
    const row = document.createElement("tr");
    row.append(element("td", "mono", member.user_id), element("td", "", member.role), element("td", "", formatDate(member.joined_at)));
    return row;
  });
  document.querySelector("#group-members-body").replaceChildren(...memberRows);
  document.querySelector("#group-dialog").showModal();
}

async function loadConversations() {
  const payload = await api("conversations");
  state.conversations = payload.conversations || [];
  renderConversations();
}

function renderConversations() {
  const query = document.querySelector("#conversation-search").value.trim().toLowerCase();
  const conversations = state.conversations.filter((conversation) => {
    return `${conversation.id} ${conversation.title} ${(conversation.participants || []).join(" ")}`.toLowerCase().includes(query);
  });
  const rows = conversations.map((conversation) => {
    const row = document.createElement("tr");
    const identity = document.createElement("td");
    identity.append(element("span", "cell-title", conversation.title || conversation.id), element("span", "cell-subtitle mono", conversation.id));
    const type = document.createElement("td");
    type.append(statusBadge(conversation.type, conversation.type === "group"));
    const participants = element("td", "", String((conversation.participants || []).length));
    const created = element("td", "", formatDate(conversation.created_at));
    const actions = document.createElement("td");
    if (conversation.type === "group") {
      actions.append(element("span", "cell-subtitle", "Groups"));
    } else {
      const remove = element("button", "table-button", "Delete");
      remove.type = "button";
      remove.addEventListener("click", () => deleteConversation(conversation));
      actions.append(remove);
    }
    row.append(identity, type, participants, created, actions);
    return row;
  });
  document.querySelector("#conversations-body").replaceChildren(...rows);
  document.querySelector("#conversations-empty").hidden = rows.length !== 0;
}

async function loadMessages() {
  const payload = await api("messages");
  state.messages = payload.messages || [];
  renderMessages();
}

function renderMessages() {
  const query = document.querySelector("#message-search").value.trim().toLowerCase();
  const messages = state.messages.filter((message) => {
    return `${message.id} ${message.conversation_id} ${message.sender_id} ${message.sender_nickname} ${messageSummary(message)}`.toLowerCase().includes(query);
  });
  const rows = messages.map((message) => {
    const row = document.createElement("tr");
    const content = document.createElement("td");
    content.append(element("span", "cell-title message-preview", messageSummary(message)), element("span", "cell-subtitle mono", message.id));
    const sender = document.createElement("td");
    sender.append(element("span", "cell-title", message.sender_nickname || message.sender_id), element("span", "cell-subtitle mono", message.sender_id));
    const conversation = element("td", "mono", message.conversation_id);
    const sent = element("td", "", formatDate(message.timestamp));
    const actions = document.createElement("td");
    const inspect = element("button", "table-button", "Open");
    inspect.type = "button";
    inspect.addEventListener("click", () => openMessage(message));
    actions.append(inspect);
    row.append(content, sender, conversation, sent, actions);
    return row;
  });
  document.querySelector("#messages-body").replaceChildren(...rows);
  document.querySelector("#messages-empty").hidden = rows.length !== 0;
}

function openMessage(message) {
  state.selectedMessage = message;
  document.querySelector("#message-dialog-title").textContent = message.sender_nickname || message.sender_id;
  appendDetails(document.querySelector("#message-details"), [
    ["Message ID", message.id, true],
    ["Conversation", message.conversation_id, true],
    ["Sender", message.sender_id, true],
    ["Sent", formatDate(message.timestamp)],
    ["Status", message.recalled ? "Recalled" : "Stored"],
    ["Segments", (message.segments || []).length],
  ]);
  const segments = (message.segments || []).map((segment) => {
    const item = element("div", "segment-item");
    item.append(element("strong", "", segment.type || "unknown"), element("pre", "", JSON.stringify(segment.data || {}, null, 2)));
    return item;
  });
  document.querySelector("#message-segments").replaceChildren(...segments);
  document.querySelector("#message-dialog").showModal();
}

async function loadMedia() {
  const payload = await api("media");
  state.media = payload.media || [];
  renderMedia();
}

function renderMedia() {
  const query = document.querySelector("#media-search").value.trim().toLowerCase();
  const files = state.media.filter((file) => `${file.id} ${file.file_name} ${file.file_type} ${file.mime_type} ${file.uploader_id}`.toLowerCase().includes(query));
  const rows = files.map((file) => {
    const row = document.createElement("tr");
    const fileCell = document.createElement("td");
    const identity = element("div", "media-identity");
    const preview = element("span", "media-thumbnail", String(file.file_type || "file").slice(0, 1).toUpperCase());
    const url = safeMediaURL(file);
    if (url && String(file.mime_type).startsWith("image/") && file.mime_type !== "image/svg+xml") {
      const image = document.createElement("img");
      image.src = url;
      image.alt = "";
      preview.replaceChildren(image);
    }
    const labels = element("span", "");
    labels.append(element("span", "cell-title", file.file_name), element("span", "cell-subtitle mono", file.id));
    identity.append(preview, labels);
    fileCell.append(identity);
    const uploader = element("td", "mono", file.uploader_id);
    const type = document.createElement("td");
    type.append(element("span", "cell-title", file.file_type || "file"), element("span", "cell-subtitle", `${file.mime_type || "unknown"} / ${formatBytes(file.size)}`));
    const uploaded = element("td", "", formatDate(file.created_at));
    const actions = document.createElement("td");
    const inspect = element("button", "table-button", "Open");
    inspect.type = "button";
    inspect.addEventListener("click", () => openMedia(file));
    actions.append(inspect);
    row.append(fileCell, uploader, type, uploaded, actions);
    return row;
  });
  document.querySelector("#media-body").replaceChildren(...rows);
  document.querySelector("#media-empty").hidden = rows.length !== 0;
}

function openMedia(file) {
  state.selectedMedia = file;
  document.querySelector("#media-dialog-title").textContent = file.file_name;
  appendDetails(document.querySelector("#media-details"), [
    ["File ID", file.id, true],
    ["Uploader", file.uploader_id, true],
    ["Type", file.file_type || "file"],
    ["MIME", file.mime_type || "unknown", true],
    ["Size", formatBytes(file.size)],
    ["Uploaded", formatDate(file.created_at)],
  ]);
  const viewer = document.querySelector("#media-viewer");
  const url = safeMediaURL(file);
  let content = element("div", "file-placeholder", String(file.file_type || "file").toUpperCase());
  if (url && String(file.mime_type).startsWith("image/") && file.mime_type !== "image/svg+xml") {
    content = document.createElement("img");
    content.src = url;
    content.alt = file.file_name;
  } else if (url && String(file.mime_type).startsWith("video/")) {
    content = document.createElement("video");
    content.src = url;
    content.controls = true;
  } else if (url && String(file.mime_type).startsWith("audio/")) {
    content = document.createElement("audio");
    content.src = url;
    content.controls = true;
  }
  viewer.replaceChildren(content);
  const link = document.querySelector("#open-media-link");
  link.href = url || "#";
  link.hidden = !url;
  document.querySelector("#media-dialog").showModal();
}

async function loadRegistration() {
  const payload = await api("settings/registration");
  const enabled = Boolean(payload.enabled);
  document.querySelector("#registration-enabled").checked = enabled;
  const badge = document.querySelector("#registration-state");
  badge.textContent = enabled ? "Enabled" : "Disabled";
  badge.className = `status-badge ${enabled ? "enabled" : "offline"}`;
}

async function setActiveView(view) {
  state.activeView = view;
  document.querySelectorAll(".nav-button").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  document.querySelectorAll(".view").forEach((section) => {
    const active = section.dataset.section === view;
    section.hidden = !active;
    section.classList.toggle("active", active);
  });
  pageTitle.textContent = document.querySelector(`.nav-button[data-view="${view}"]`).textContent;
  await refreshActiveView();
}

async function refreshActiveView() {
  const loaders = {
    dashboard: loadOverview,
    users: loadUsers,
    reports: loadReports,
    groups: loadGroups,
    conversations: loadConversations,
    messages: loadMessages,
    media: loadMedia,
    settings: loadRegistration,
  };
  try {
    await loaders[state.activeView]();
  } catch (error) {
    showToast(error.message, true);
  }
}

async function deleteConversation(conversation) {
  if (!window.confirm(`Delete conversation ${conversation.id} and all of its messages?`)) return;
  try {
    await api("conversations", { method: "DELETE", body: JSON.stringify({ conversation_id: conversation.id }) });
    showToast("Conversation deleted");
    await loadConversations();
  } catch (error) {
    showToast(error.message, true);
  }
}

loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  loginError.textContent = "";
  const tokenInput = document.querySelector("#admin-token");
  try {
    await api("session", { method: "POST", body: JSON.stringify({ token: tokenInput.value }) });
    tokenInput.value = "";
    showApp();
    await setActiveView("dashboard");
  } catch (error) {
    loginError.textContent = error.message;
  }
});

document.querySelector("#logout-button").addEventListener("click", async () => {
  try {
    await api("session", { method: "DELETE" });
  } finally {
    showLogin();
  }
});

document.querySelector("#refresh-button").addEventListener("click", refreshActiveView);
document.querySelectorAll(".nav-button").forEach((button) => button.addEventListener("click", () => setActiveView(button.dataset.view)));
document.querySelector("#user-search").addEventListener("input", renderUsers);
document.querySelector("#report-search").addEventListener("input", renderReports);
document.querySelector("#group-search").addEventListener("input", renderGroups);
document.querySelector("#conversation-search").addEventListener("input", renderConversations);
document.querySelector("#message-search").addEventListener("input", renderMessages);
document.querySelector("#media-search").addEventListener("input", renderMedia);

document.querySelectorAll("[data-close-dialog]").forEach((button) => {
  button.addEventListener("click", () => document.querySelector(`#${button.dataset.closeDialog}`).close());
});

document.querySelector("#edit-user-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const dialog = document.querySelector("#edit-user-dialog");
  try {
    await api("users", {
      method: "PATCH",
      body: JSON.stringify({ user_id: dialog.dataset.userId, nickname: document.querySelector("#edit-user-nickname").value }),
    });
    showToast("User updated");
    await loadUsers();
  } catch (error) {
    showToast(error.message, true);
  }
});

document.querySelector("#grant-title-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const dialog = document.querySelector("#edit-user-dialog");
  const expiry = document.querySelector("#grant-title-expiry").value;
  try {
    await api("titles", {
      method: "POST",
      body: JSON.stringify({
        user_id: dialog.dataset.userId,
        text: document.querySelector("#grant-title-text").value,
        style: document.querySelector("#grant-title-style").value,
        expires_at: expiry ? new Date(expiry).toISOString() : "",
      }),
    });
    document.querySelector("#grant-title-text").value = "";
    document.querySelector("#grant-title-expiry").value = "";
    showToast("Title granted");
    await loadUserTitles(dialog.dataset.userId);
  } catch (error) {
    showToast(error.message, true);
  }
});

document.querySelector("#reset-password-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const dialog = document.querySelector("#edit-user-dialog");
  const password = document.querySelector("#reset-password");
  const confirmation = document.querySelector("#reset-password-confirm");
  const error = document.querySelector("#reset-password-error");
  error.textContent = "";
  if (password.value !== confirmation.value) {
    error.textContent = "Passwords do not match";
    return;
  }
  try {
    await api("users/password", {
      method: "PATCH",
      body: JSON.stringify({
        user_id: dialog.dataset.userId,
        password: password.value,
        revoke_sessions: document.querySelector("#revoke-user-sessions").checked,
      }),
    });
    password.value = "";
    confirmation.value = "";
    dialog.close();
    showToast("Password reset");
  } catch (requestError) {
    error.textContent = requestError.message;
  }
});

document.querySelector("#delete-message-button").addEventListener("click", async () => {
  const message = state.selectedMessage;
  if (!message || !window.confirm(`Delete message ${message.id}?`)) return;
  try {
    await api("messages", { method: "DELETE", body: JSON.stringify({ message_id: message.id }) });
    document.querySelector("#message-dialog").close();
    showToast("Message deleted");
    await loadMessages();
  } catch (error) {
    showToast(error.message, true);
  }
});

document.querySelector("#delete-media-button").addEventListener("click", async () => {
  const file = state.selectedMedia;
  if (!file || !window.confirm(`Permanently delete ${file.file_name}? Messages that reference it will no longer load the file.`)) return;
  try {
    await api("media", { method: "DELETE", body: JSON.stringify({ media_id: file.id }) });
    document.querySelector("#media-dialog").close();
    showToast("File deleted");
    await loadMedia();
  } catch (error) {
    showToast(error.message, true);
  }
});

document.querySelector("#delete-group-button").addEventListener("click", async () => {
  const group = state.selectedGroup;
  if (!group || !window.confirm(`Delete group ${group.name}, its conversation, and all messages?`)) return;
  try {
    await api("groups", { method: "DELETE", body: JSON.stringify({ group_id: group.id }) });
    document.querySelector("#group-dialog").close();
    showToast("Group deleted");
    await loadGroups();
  } catch (error) {
    showToast(error.message, true);
  }
});

document.querySelector("#registration-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const enabled = document.querySelector("#registration-enabled").checked;
  const inviteInput = document.querySelector("#invite-code");
  try {
    await api("settings/registration", {
      method: "PATCH",
      body: JSON.stringify({ enabled, invite_code: inviteInput.value }),
    });
    inviteInput.value = "";
    showToast("Registration settings applied");
    await loadRegistration();
  } catch (error) {
    showToast(error.message, true);
  }
});

(async function initialize() {
  try {
    await api("session");
    showApp();
    await setActiveView("dashboard");
  } catch (_) {
    showLogin();
  }
})();
