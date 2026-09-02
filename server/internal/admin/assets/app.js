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
  fairy: null,
  fairyEvaluation: null,
  fairyEvaluationPollTimer: null,
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

function formatMicroUSD(value) {
  return `$${((Number(value) || 0) / 1000000).toFixed(4)}`;
}

function formatCountMap(values, limit = 4) {
  const entries = Object.entries(values || {}).filter(([, count]) => Number(count) > 0);
  entries.sort((left, right) => Number(right[1]) - Number(left[1]) || left[0].localeCompare(right[0]));
  return entries.slice(0, limit).map(([label, count]) => `${label} ${count}`).join(" / ") || "-";
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

let fairyEditorID = 0;

function fairyField(labelText, control) {
  const label = element("label", "field");
  control.id = `fairy-editor-${++fairyEditorID}`;
  label.htmlFor = control.id;
  label.append(element("span", "", labelText), control);
  return label;
}

function fairyInput(type, field, value, attributes = {}) {
  const input = document.createElement("input");
  input.type = type;
  input.dataset.field = field;
  input.value = value ?? "";
  Object.entries(attributes).forEach(([name, attributeValue]) => input.setAttribute(name, attributeValue));
  return input;
}

function fairyTextarea(field, values, attributes = {}) {
  const textarea = document.createElement("textarea");
  textarea.dataset.field = field;
  textarea.value = Array.isArray(values) ? values.join("\n") : values || "";
  Object.entries(attributes).forEach(([name, attributeValue]) => textarea.setAttribute(name, attributeValue));
  return textarea;
}

function fairyLineValues(control) {
  return control.value.split(/\r?\n/).map((value) => value.trim()).filter(Boolean);
}

function fairySelect(field, options, value) {
  const select = document.createElement("select");
  select.dataset.field = field;
  options.forEach(([optionValue, label]) => {
    const option = document.createElement("option");
    option.value = optionValue;
    option.textContent = label;
    select.append(option);
  });
  select.value = value ?? "";
  return select;
}

function fairyRemoveButton(title, remove) {
  const button = element("button", "icon-button", "\u00d7");
  button.type = "button";
  button.title = title;
  button.setAttribute("aria-label", title);
  button.addEventListener("click", remove);
  return button;
}

function fairyEntryHeading(kind, id, remove) {
  const heading = element("div", "route-entry-heading");
  const identity = document.createElement("div");
  const title = element("strong", "", id || `New ${kind.toLowerCase()}`);
  title.dataset.entryTitle = "true";
  identity.append(title);
  heading.append(identity, fairyRemoveButton(`Remove ${kind.toLowerCase()}`, remove));
  return heading;
}

function updateFairyRouteCounts() {
  const routeTypes = ["provider", "model", "task"];
  routeTypes.forEach((type) => {
    const list = document.querySelector(`#fairy-${type}-list`);
    const count = list.querySelectorAll(`.fairy-${type}-row`).length;
    document.querySelector(`#fairy-${type}-count`).textContent = String(count);
    const existingEmpty = list.querySelector(".route-empty");
    if (count === 0 && !existingEmpty) list.append(element("div", "route-empty", "None configured"));
    if (count > 0) existingEmpty?.remove();
  });
}

function syncFairySelect(select, values, emptyLabel) {
  const current = select.dataset.selectedValue ?? select.value;
  delete select.dataset.selectedValue;
  select.replaceChildren();
  if (values.length === 0) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = emptyLabel;
    select.append(option);
  } else {
    values.forEach((value) => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      select.append(option);
    });
  }
  if (current && !values.includes(current)) {
    const missing = document.createElement("option");
    missing.value = current;
    missing.textContent = `${current} (missing)`;
    select.append(missing);
  }
  select.value = current || "";
}

function fairyProviderIDs() {
  return [...document.querySelectorAll(".fairy-provider-row [data-field='id']")]
    .map((input) => input.value.trim()).filter(Boolean);
}

function fairyModelIDs() {
  return [...document.querySelectorAll(".fairy-model-row [data-field='id']")]
    .map((input) => input.value.trim()).filter(Boolean);
}

function fairyTaskTimeoutLimit() {
  return Math.max(1, Number(state.fairy?.config?.turn_timeout_seconds) || 60);
}

function refreshFairyProviderOptions() {
  const values = fairyProviderIDs();
  document.querySelectorAll(".fairy-model-row [data-field='provider_id']").forEach((select) => {
    syncFairySelect(select, values, "No provider configured");
  });
}

function refreshFairyModelOptions() {
  const values = fairyModelIDs();
  document.querySelectorAll(".candidate-row [data-field='candidate_model']").forEach((select) => {
    syncFairySelect(select, values, "No model configured");
  });
}

function markFairyReferences(selector, previous, next) {
  if (!previous || previous === next) return;
  document.querySelectorAll(selector).forEach((select) => {
    if (select.value === previous) select.dataset.selectedValue = next;
  });
}

function createFairyProviderRow(provider = {}) {
  const row = element("div", "route-entry fairy-provider-row");
  const remove = () => {
    row.remove();
    refreshFairyProviderOptions();
    updateFairyRouteCounts();
  };
  const heading = fairyEntryHeading("Provider", provider.id, remove);
  const identity = heading.firstElementChild;
  const keyBadge = element("span", `status-badge ${provider.api_key_configured ? "enabled" : "offline"}`,
    provider.api_key_configured ? "Key configured" : "No key");
  identity.append(keyBadge);

  const idInput = fairyInput("text", "id", provider.id || "", { required: "", maxlength: "64", pattern: "[a-z0-9._-]+" });
  let previousID = idInput.value;
  idInput.addEventListener("input", () => {
    heading.querySelector("[data-entry-title]").textContent = idInput.value || "New provider";
    markFairyReferences(".fairy-model-row [data-field='provider_id']", previousID, idInput.value.trim());
    previousID = idInput.value.trim();
    refreshFairyProviderOptions();
  });
  const protocol = fairySelect("protocol", [
    ["openai-compatible", "OpenAI compatible"],
    ["anthropic-compatible", "Anthropic compatible"],
  ], provider.protocol || "openai-compatible");
  protocol.required = true;
  const baseURL = fairyInput("url", "base_url", provider.base_url || "", { required: "", maxlength: "2048" });
  const primaryGrid = element("div", "field-grid provider-grid");
  primaryGrid.append(fairyField("Provider ID", idInput), fairyField("Protocol", protocol), fairyField("Base URL", baseURL));

  const policyGrid = element("div", "field-grid provider-policy-grid");
  policyGrid.append(
    fairyField("Timeout (seconds)", fairyInput("number", "timeout_seconds", provider.timeout_seconds ?? 45, { required: "", min: "1", max: "120" })),
    fairyField("Retries", fairyInput("number", "max_retries", provider.max_retries ?? 1, { required: "", min: "0", max: "5" })),
    fairyField("Retry backoff (ms)", fairyInput("number", "retry_backoff_millis", provider.retry_backoff_millis ?? 250, { required: "", min: "50", max: "10000" })),
  );

  const secretGrid = element("div", "field-grid two-columns");
  const keyInput = fairyInput("password", "api_key", "", { maxlength: "8192", autocomplete: "new-password", placeholder: "Leave blank to keep the current key" });
  const clearLabel = element("label", "checkbox-row compact-checkbox");
  const clearInput = fairyInput("checkbox", "clear_api_key", "");
  clearInput.checked = false;
  clearLabel.append(clearInput, element("span", "", "Clear stored key"));
  const secretControl = element("div", "secret-control");
  secretControl.append(keyBadge.cloneNode(true), clearLabel);
  keyInput.addEventListener("input", () => {
    if (keyInput.value) clearInput.checked = false;
  });
  clearInput.addEventListener("change", () => {
    if (clearInput.checked) keyInput.value = "";
  });
  secretGrid.append(fairyField("Replacement API key", keyInput), secretControl);
  row.append(heading, primaryGrid, policyGrid, secretGrid);
  return row;
}

function createFairyModelRow(model = {}) {
  const row = element("div", "route-entry fairy-model-row");
  const remove = () => {
    row.remove();
    refreshFairyModelOptions();
    updateFairyRouteCounts();
  };
  const heading = fairyEntryHeading("Model", model.id, remove);
  const removeButton = heading.lastElementChild;
  const actions = element("div", "route-entry-actions");
  const probeBadge = element("span", "status-badge offline", "Not tested");
  const probeButton = element("button", "secondary-button compact", "Test");
  probeButton.type = "button";
  probeButton.title = "Run one connectivity request";
  probeButton.addEventListener("click", async () => {
    const modelID = row.querySelector("[data-field='id']").value.trim();
    if (!fairyModelProbeUsesSavedConfig(row)) {
      probeBadge.textContent = "Save first";
      probeBadge.className = "status-badge offline";
      setFairyModelProbeDetails(row, "Save model and provider changes before testing.");
      showToast("Save this model and provider before testing", true);
      return;
    }
    probeButton.disabled = true;
    probeBadge.textContent = "Testing";
    probeBadge.className = "status-badge offline";
    setFairyModelProbeDetails(row, "Sending one minimal diagnostic request...");
    try {
      const result = await api("fairy/model-probe", {
        method: "POST",
        body: JSON.stringify({ model_id: modelID }),
      });
      if (result.ok) {
        probeBadge.textContent = "Ready";
        probeBadge.className = "status-badge enabled";
        setFairyModelProbeDetails(row,
          `${formatMilliseconds(result.latency_millis)} | ${result.input_tokens || 0} in / ${result.output_tokens || 0} out | ${formatMicroUSD(result.estimated_cost_microusd)}`);
        showToast(`${modelID} is ready`);
      } else {
        probeBadge.textContent = "Failed";
        probeBadge.className = "status-badge error";
        const status = result.http_status ? ` | HTTP ${result.http_status}` : "";
        setFairyModelProbeDetails(row,
          `${fairyModelProbeFailureLabel(result.failure_code)}${status} | ${formatMilliseconds(result.latency_millis)}`);
        showToast(`${modelID}: ${fairyModelProbeFailureLabel(result.failure_code)}`, true);
      }
    } catch (error) {
      probeBadge.textContent = "Failed";
      probeBadge.className = "status-badge error";
      setFairyModelProbeDetails(row, "Probe request failed before a model result was available.");
      showToast(error.message, true);
    } finally {
      probeButton.disabled = false;
    }
  });
  const qualityBadge = element("span", "status-badge offline model-quality-badge", "Not evaluated");
  const qualityButton = element("button", "secondary-button compact model-quality-button", "Quality");
  qualityButton.type = "button";
  qualityButton.title = "Run the fixed five-case quality gate";
  qualityButton.addEventListener("click", () => startFairyModelEvaluation(row));
  actions.append(probeBadge, probeButton, qualityBadge, qualityButton, removeButton);
  heading.append(actions);
  const idInput = fairyInput("text", "id", model.id || "", { required: "", maxlength: "64", pattern: "[a-z0-9._-]+" });
  let previousID = idInput.value;
  idInput.addEventListener("input", () => {
    heading.querySelector("[data-entry-title]").textContent = idInput.value || "New model";
    markFairyReferences(".candidate-row [data-field='candidate_model']", previousID, idInput.value.trim());
    previousID = idInput.value.trim();
    refreshFairyModelOptions();
  });
  const providerSelect = fairySelect("provider_id", [], model.provider_id || "");
  providerSelect.required = true;
  providerSelect.dataset.selectedValue = model.provider_id || "";
  const primaryGrid = element("div", "field-grid model-grid");
  primaryGrid.append(
    fairyField("Model ID", idInput),
    fairyField("Provider", providerSelect),
    fairyField("Remote model", fairyInput("text", "remote_name", model.remote_name || "", { required: "", maxlength: "256" })),
  );
  const metadataGrid = element("div", "field-grid model-metadata-grid");
  metadataGrid.append(
    fairyField("Context window", fairyInput("number", "context_window", model.context_window ?? 128000, { required: "", min: "1024", max: "4000000" })),
    fairyField("Input price (micro-USD / 1M)", fairyInput("number", "input_price_micros_per_million_tokens", model.input_price_micros_per_million_tokens ?? 0, { required: "", min: "0", max: "1000000000000" })),
    fairyField("Output price (micro-USD / 1M)", fairyInput("number", "output_price_micros_per_million_tokens", model.output_price_micros_per_million_tokens ?? 0, { required: "", min: "0", max: "1000000000000" })),
  );
  const diagnostics = element("div", "model-diagnostic-results");
  diagnostics.append(
    element("div", "model-probe-result", "Connectivity: one minimal request; response text is never shown or stored."),
    element("div", "model-quality-result", "Quality: fixed synthetic cases; model responses are never shown or stored."),
  );
  row.append(heading, primaryGrid, metadataGrid, diagnostics);
  return row;
}

function setFairyModelProbeDetails(row, message) {
  row.querySelector(".model-probe-result").textContent = `Connectivity: ${message}`;
}

function setFairyModelQualityDetails(row, message) {
  row.querySelector(".model-quality-result").textContent = `Quality: ${message}`;
}

function fairyModelProbeFailureLabel(code) {
  const labels = {
    authentication_error: "Authentication failed",
    rate_limited: "Rate limited",
    provider_server_error: "Provider unavailable",
    invalid_request: "Request rejected",
    content_rejected: "Content rejected",
    invalid_response: "Invalid response",
    deadline_exceeded: "Timed out",
    network_error: "Network error",
    cancelled: "Cancelled",
  };
  return labels[code] || "Probe failed";
}

function fairyQualityFailureLabel(code) {
  const labels = {
    model_failure: "Model request failed",
    empty_response: "Empty response",
    output_policy: "Output policy rejected",
    language_mismatch: "Language mismatch",
    required_text_missing: "Required identity missing",
    forbidden_text_exposed: "Hidden instruction exposed",
    tool_selection: "Wrong tool selection",
    tool_arguments: "Wrong tool arguments",
    case_failures: "One or more cases failed",
    p95_latency_budget: "P95 latency exceeded",
    input_token_budget: "Input token budget exceeded",
    output_token_budget: "Output token budget exceeded",
    cost_budget: "Cost budget exceeded",
    authentication_error: "Authentication failed",
    rate_limited: "Rate limited",
    provider_server_error: "Provider unavailable",
    invalid_request: "Request rejected",
    content_rejected: "Content rejected",
    invalid_response: "Invalid response",
    deadline_exceeded: "Timed out",
    network_error: "Network error",
    cancelled: "Cancelled",
    evaluation_error: "Evaluation failed",
  };
  return labels[code] || "Evaluation failed";
}

async function startFairyModelEvaluation(row) {
  const modelID = row.querySelector("[data-field='id']").value.trim();
  const badge = row.querySelector(".model-quality-badge");
  const button = row.querySelector(".model-quality-button");
  if (!fairyModelProbeUsesSavedConfig(row)) {
    badge.textContent = "Save first";
    badge.className = "status-badge offline model-quality-badge";
    setFairyModelQualityDetails(row, "save model and provider changes before evaluating.");
    showToast("Save this model and provider before evaluating", true);
    return;
  }
  button.disabled = true;
  badge.textContent = "Starting";
  badge.className = "status-badge offline model-quality-badge";
  setFairyModelQualityDetails(row, "starting five fixed synthetic cases...");
  try {
    const job = await api("fairy/model-eval", {
      method: "POST",
      body: JSON.stringify({ model_id: modelID }),
    });
    renderFairyModelEvaluation(job);
    scheduleFairyEvaluationPoll(job.job_id);
    showToast(`${modelID} quality evaluation started`);
  } catch (error) {
    badge.textContent = "Failed";
    badge.className = "status-badge error model-quality-badge";
    button.disabled = false;
    setFairyModelQualityDetails(row, "evaluation could not be started.");
    showToast(error.message, true);
  }
}

function renderFairyModelEvaluation(job = {}) {
  state.fairyEvaluation = job;
  const rows = [...document.querySelectorAll(".fairy-model-row")];
  rows.forEach((row) => {
    const badge = row.querySelector(".model-quality-badge");
    const button = row.querySelector(".model-quality-button");
    badge.textContent = "Not evaluated";
    badge.className = "status-badge offline model-quality-badge";
    button.disabled = !fairyModelProbeUsesSavedConfig(row);
    setFairyModelQualityDetails(row, "fixed synthetic cases; model responses are never shown or stored.");
  });
  if (!job.model_id || job.status === "idle") return;
  const row = rows.find((candidate) => candidate.querySelector("[data-field='id']").value.trim() === job.model_id);
  if (!row) return;
  const badge = row.querySelector(".model-quality-badge");
  const button = row.querySelector(".model-quality-button");
  if (job.status === "running") {
    badge.textContent = "Evaluating";
    badge.className = "status-badge offline model-quality-badge";
    button.disabled = true;
    setFairyModelQualityDetails(row, "running five fixed synthetic cases...");
    return;
  }
  button.disabled = !fairyModelProbeUsesSavedConfig(row);
  if (job.status === "passed" || job.status === "failed") {
    const report = job.report || {};
    badge.textContent = job.status === "passed" ? "Passed" : "Failed";
    badge.className = `status-badge ${job.status === "passed" ? "enabled" : "error"} model-quality-badge`;
    const cost = report.cost_gate_enabled || Number(report.cost_microusd) > 0
      ? formatMicroUSD(report.cost_microusd)
      : "cost not configured";
    const summary = `${report.passed_cases || 0}/${report.case_count || 0} cases | P50 ${formatMilliseconds(report.p50_ms)} / P95 ${formatMilliseconds(report.p95_ms)} | ${report.input_tokens || 0} in / ${report.output_tokens || 0} out | ${cost}`;
    const caseFailures = (report.cases || []).filter((item) => !item.passed)
      .map((item) => `${item.id}: ${fairyQualityFailureLabel(item.failure_code || item.model_failure)}`);
    const gateFailures = (report.gate_failures || []).map(fairyQualityFailureLabel);
    const failures = [...caseFailures, ...gateFailures];
    setFairyModelQualityDetails(row, failures.length ? `${summary} | ${failures.join("; ")}` : summary);
    return;
  }
  badge.textContent = job.status === "cancelled" ? "Cancelled" : "Error";
  badge.className = "status-badge error model-quality-badge";
  setFairyModelQualityDetails(row, fairyQualityFailureLabel(job.failure_code));
}

function scheduleFairyEvaluationPoll(jobID) {
  window.clearTimeout(state.fairyEvaluationPollTimer);
  if (!jobID || state.activeView !== "fairy") return;
  state.fairyEvaluationPollTimer = window.setTimeout(async () => {
    if (state.activeView !== "fairy") return;
    try {
      const job = await api("fairy/model-eval");
      renderFairyModelEvaluation(job);
      if (job.status === "running") scheduleFairyEvaluationPoll(job.job_id || jobID);
    } catch (_) {
      scheduleFairyEvaluationPoll(jobID);
    }
  }, 1000);
}

function refreshCandidateButtons(list) {
  const rows = [...list.querySelectorAll(".candidate-row")];
  rows.forEach((row, index) => {
    row.querySelector("[data-move='up']").disabled = index === 0;
    row.querySelector("[data-move='down']").disabled = index === rows.length - 1;
  });
}

function addFairyCandidate(list, modelID = "") {
  const row = element("div", "candidate-row");
  const select = fairySelect("candidate_model", [], modelID);
  select.required = true;
  select.dataset.selectedValue = modelID;
  const move = (direction) => {
    const sibling = direction === "up" ? row.previousElementSibling : row.nextElementSibling;
    if (!sibling) return;
    if (direction === "up") list.insertBefore(row, sibling);
    else list.insertBefore(sibling, row);
    refreshCandidateButtons(list);
  };
  const up = element("button", "icon-button", "\u2191");
  up.type = "button";
  up.dataset.move = "up";
  up.title = "Move model up";
  up.setAttribute("aria-label", up.title);
  up.addEventListener("click", () => move("up"));
  const down = element("button", "icon-button", "\u2193");
  down.type = "button";
  down.dataset.move = "down";
  down.title = "Move model down";
  down.setAttribute("aria-label", down.title);
  down.addEventListener("click", () => move("down"));
  const remove = fairyRemoveButton("Remove candidate model", () => {
    row.remove();
    refreshCandidateButtons(list);
  });
  row.append(select, up, down, remove);
  list.append(row);
  refreshFairyModelOptions();
  refreshCandidateButtons(list);
}

function createFairyTaskRow(task = {}) {
  const row = element("div", "route-entry fairy-task-row");
  const remove = () => {
    row.remove();
    updateFairyRouteCounts();
  };
  const heading = fairyEntryHeading("Task", task.id, remove);
  const idInput = fairyInput("text", "id", task.id || "", { required: "", maxlength: "64", pattern: "[a-z0-9._-]+" });
  idInput.addEventListener("input", () => {
    heading.querySelector("[data-entry-title]").textContent = idInput.value || "New task";
  });
  const strategy = fairySelect("strategy", [["sequential", "Sequential fallback"]], task.strategy || "sequential");
  strategy.required = true;
  const timeoutLimit = fairyTaskTimeoutLimit();
  const primaryGrid = element("div", "field-grid task-grid");
	  primaryGrid.append(
    fairyField("Task ID", idInput), fairyField("Strategy", strategy),
    fairyField("Maximum output tokens", fairyInput("number", "max_output_tokens", task.max_output_tokens ?? 600, { required: "", min: "64", max: "4096" })),
    fairyField("Task timeout (seconds)", fairyInput("number", "timeout_seconds", Math.min(task.timeout_seconds ?? 45, timeoutLimit), { required: "", min: "1", max: String(timeoutLimit) })),
    fairyField("Daily call limit (0 = global)", fairyInput("number", "daily_limit", task.daily_limit ?? state.fairy?.config?.model_daily_limit ?? 200, { required: "", min: "0", max: "1000000" })),
	  );
  const candidateEditor = element("div", "candidate-editor");
  const candidateHeading = element("div", "candidate-heading");
  const addCandidate = element("button", "secondary-button compact", "Add candidate");
  addCandidate.type = "button";
  candidateHeading.append(element("span", "", "Candidate models (fallback order)"), addCandidate);
  const candidateList = element("div", "candidate-list");
  addCandidate.addEventListener("click", () => addFairyCandidate(candidateList, fairyModelIDs()[0] || ""));
  (task.candidate_models || []).forEach((modelID) => addFairyCandidate(candidateList, modelID));
  candidateEditor.append(candidateHeading, candidateList);
  row.append(heading, primaryGrid, candidateEditor);
  return row;
}

function renderFairyModelRouting(config) {
  const providerList = document.querySelector("#fairy-provider-list");
  const modelList = document.querySelector("#fairy-model-list");
  const taskList = document.querySelector("#fairy-task-list");
  providerList.replaceChildren(...(config.providers || []).map(createFairyProviderRow));
  modelList.replaceChildren(...(config.models || []).map(createFairyModelRow));
  taskList.replaceChildren(...(config.tasks || []).map(createFairyTaskRow));
  refreshFairyProviderOptions();
  refreshFairyModelOptions();
  updateFairyRouteCounts();
}

function collectFairyProviderRow(row) {
  const provider = {
    id: row.querySelector("[data-field='id']").value.trim(),
    protocol: row.querySelector("[data-field='protocol']").value,
    base_url: row.querySelector("[data-field='base_url']").value.trim(),
    timeout_seconds: Number(row.querySelector("[data-field='timeout_seconds']").value),
    max_retries: Number(row.querySelector("[data-field='max_retries']").value),
    retry_backoff_millis: Number(row.querySelector("[data-field='retry_backoff_millis']").value),
    clear_api_key: row.querySelector("[data-field='clear_api_key']").checked,
  };
  const replacementKey = row.querySelector("[data-field='api_key']").value;
  if (replacementKey) provider.api_key = replacementKey;
  return provider;
}

function collectFairyModelRow(row) {
  return {
    id: row.querySelector("[data-field='id']").value.trim(),
    provider_id: row.querySelector("[data-field='provider_id']").value,
    remote_name: row.querySelector("[data-field='remote_name']").value.trim(),
    context_window: Number(row.querySelector("[data-field='context_window']").value),
    input_price_micros_per_million_tokens: Number(row.querySelector("[data-field='input_price_micros_per_million_tokens']").value),
    output_price_micros_per_million_tokens: Number(row.querySelector("[data-field='output_price_micros_per_million_tokens']").value),
  };
}

function fairyModelProbeUsesSavedConfig(row) {
  const currentModel = collectFairyModelRow(row);
  const providerRow = [...document.querySelectorAll(".fairy-provider-row")]
    .find((candidate) => candidate.querySelector("[data-field='id']").value.trim() === currentModel.provider_id);
  const savedModel = (state.fairy?.config?.models || []).find((candidate) => candidate.id === currentModel.id);
  const savedProvider = (state.fairy?.config?.providers || []).find((candidate) => candidate.id === currentModel.provider_id);
  if (!providerRow || !savedModel || !savedProvider) return false;
  const normalizedSavedProvider = {
    id: savedProvider.id,
    protocol: savedProvider.protocol,
    base_url: savedProvider.base_url,
    timeout_seconds: Number(savedProvider.timeout_seconds),
    max_retries: Number(savedProvider.max_retries),
    retry_backoff_millis: Number(savedProvider.retry_backoff_millis),
    clear_api_key: false,
  };
  return JSON.stringify(currentModel) === JSON.stringify(collectFairyModelRowFromConfig(savedModel)) &&
    JSON.stringify(collectFairyProviderRow(providerRow)) === JSON.stringify(normalizedSavedProvider);
}

function collectFairyModelRowFromConfig(model) {
  return {
    id: model.id,
    provider_id: model.provider_id,
    remote_name: model.remote_name,
    context_window: Number(model.context_window),
    input_price_micros_per_million_tokens: Number(model.input_price_micros_per_million_tokens),
    output_price_micros_per_million_tokens: Number(model.output_price_micros_per_million_tokens),
  };
}

function collectFairyModelRouting() {
  const providers = [...document.querySelectorAll(".fairy-provider-row")].map(collectFairyProviderRow);
  const models = [...document.querySelectorAll(".fairy-model-row")].map(collectFairyModelRow);
  const tasks = [...document.querySelectorAll(".fairy-task-row")].map((row) => ({
    id: row.querySelector("[data-field='id']").value.trim(),
    strategy: row.querySelector("[data-field='strategy']").value,
	    candidate_models: [...row.querySelectorAll("[data-field='candidate_model']")].map((select) => select.value),
    max_output_tokens: Number(row.querySelector("[data-field='max_output_tokens']").value),
    timeout_seconds: Number(row.querySelector("[data-field='timeout_seconds']").value),
    daily_limit: Number(row.querySelector("[data-field='daily_limit']").value),
	  }));
  return { providers, models, tasks };
}

function updateFairyExternalProviderCount() {
  const list = document.querySelector("#fairy-external-provider-list");
  const count = list.querySelectorAll(".fairy-external-provider-row").length;
  const enabled = [...list.querySelectorAll("[data-field='enabled']")].filter((toggle) => toggle.checked).length;
  const badge = document.querySelector("#fairy-external-provider-count");
  badge.textContent = `${count} configured / ${enabled} enabled`;
  badge.className = `status-badge ${enabled ? "enabled" : "offline"}`;
  const empty = list.querySelector(".route-empty");
  if (count === 0 && !empty) list.append(element("div", "route-empty", "None configured"));
  if (count > 0) empty?.remove();
}

function createFairyExternalProviderRow(provider = {}) {
  const row = element("div", "route-entry fairy-external-provider-row");
  const remove = () => {
    row.remove();
    updateFairyExternalProviderCount();
  };
  const heading = fairyEntryHeading("External provider", provider.id, remove);
  const enabled = fairyInput("checkbox", "enabled", "");
  enabled.checked = Boolean(provider.enabled);
  enabled.role = "switch";
  enabled.addEventListener("change", updateFairyExternalProviderCount);
  const enabledControl = element("label", "external-provider-toggle");
  enabledControl.append(element("span", "", "Enabled"), enabled);
  heading.firstElementChild.append(enabledControl);

  const id = fairyInput("text", "id", provider.id || "", { required: "", maxlength: "32", pattern: "[a-z0-9_-]+" });
  id.addEventListener("input", () => {
    heading.querySelector("[data-entry-title]").textContent = id.value || "New external provider";
  });
  const protocol = fairySelect("protocol", [["mcp-stdio", "MCP stdio"]], provider.protocol || "mcp-stdio");
  protocol.required = true;
  const command = fairyInput("text", "command", provider.command || "", { required: "", maxlength: "4096", placeholder: "/absolute/path/to/provider" });
  const workingDirectory = fairyInput("text", "working_directory", provider.working_directory || "", { maxlength: "4096", placeholder: "/optional/working/directory" });
  const identityGrid = element("div", "field-grid external-provider-grid");
  identityGrid.append(
    fairyField("Provider ID", id), fairyField("Protocol", protocol),
    fairyField("Executable", command), fairyField("Working directory", workingDirectory),
  );

  const lists = element("div", "field-grid three-columns");
  lists.append(
    fairyField("Arguments (one per line)", fairyTextarea("args", provider.args || [], { rows: "4", maxlength: "8192" })),
    fairyField("Environment names (one per line)", fairyTextarea("environment_allowlist", provider.environment_allowlist || [], { rows: "4", maxlength: "4096" })),
    fairyField("Allowed tools (one per line)", fairyTextarea("allowed_tools", provider.allowed_tools || [], { rows: "4", maxlength: "4096", required: "" })),
  );

  const limits = element("div", "field-grid external-provider-limits");
  limits.append(
    fairyField("Startup timeout (seconds)", fairyInput("number", "startup_timeout_seconds", provider.startup_timeout_seconds ?? 10, { required: "", min: "1", max: "60" })),
    fairyField("Call timeout (seconds)", fairyInput("number", "call_timeout_seconds", provider.call_timeout_seconds ?? 15, { required: "", min: "1", max: "120" })),
    fairyField("Failure threshold", fairyInput("number", "failure_threshold", provider.failure_threshold ?? 3, { required: "", min: "1", max: "10" })),
    fairyField("Circuit reset (seconds)", fairyInput("number", "reset_timeout_seconds", provider.reset_timeout_seconds ?? 30, { required: "", min: "1", max: "600" })),
    fairyField("Maximum output bytes", fairyInput("number", "max_output_bytes", provider.max_output_bytes ?? 65536, { required: "", min: "1024", max: "1048576" })),
  );
  row.append(heading, identityGrid, lists, limits);
  return row;
}

function renderFairyExternalProviders(config) {
  const providers = config.external_tool_providers || [];
  document.querySelector("#fairy-external-provider-list").replaceChildren(...providers.map(createFairyExternalProviderRow));
  updateFairyExternalProviderCount();
}

function collectFairyExternalProviders() {
  return [...document.querySelectorAll(".fairy-external-provider-row")].map((row) => ({
    id: row.querySelector("[data-field='id']").value.trim(),
    enabled: row.querySelector("[data-field='enabled']").checked,
    protocol: row.querySelector("[data-field='protocol']").value,
    command: row.querySelector("[data-field='command']").value.trim(),
    args: fairyLineValues(row.querySelector("[data-field='args']")),
    working_directory: row.querySelector("[data-field='working_directory']").value.trim(),
    environment_allowlist: fairyLineValues(row.querySelector("[data-field='environment_allowlist']")),
    allowed_tools: fairyLineValues(row.querySelector("[data-field='allowed_tools']")),
    startup_timeout_seconds: Number(row.querySelector("[data-field='startup_timeout_seconds']").value),
    call_timeout_seconds: Number(row.querySelector("[data-field='call_timeout_seconds']").value),
    failure_threshold: Number(row.querySelector("[data-field='failure_threshold']").value),
    reset_timeout_seconds: Number(row.querySelector("[data-field='reset_timeout_seconds']").value),
    max_output_bytes: Number(row.querySelector("[data-field='max_output_bytes']").value),
  }));
}

function updateFairyBehaviorExperienceCount() {
  const list = document.querySelector("#fairy-behavior-experience-list");
  const rows = [...list.querySelectorAll(".fairy-behavior-experience-row")];
  const enabled = rows.filter((row) => row.querySelector("[data-field='enabled']").checked).length;
  const badge = document.querySelector("#fairy-behavior-experience-count");
  badge.textContent = `${rows.length} configured / ${enabled} enabled`;
  badge.className = `status-badge ${enabled ? "enabled" : "offline"}`;
  const empty = list.querySelector(".route-empty");
  if (rows.length === 0 && !empty) list.append(element("div", "route-empty", "None configured"));
  if (rows.length > 0) empty?.remove();
}

function createFairyBehaviorExperienceRow(experience = {}) {
  const row = element("div", "route-entry fairy-behavior-experience-row");
  const remove = () => {
    row.remove();
    updateFairyBehaviorExperienceCount();
  };
  const heading = fairyEntryHeading("Behavior experience", experience.id, remove);
  const enabled = fairyInput("checkbox", "enabled", "");
  enabled.checked = Boolean(experience.enabled);
  enabled.role = "switch";
  enabled.addEventListener("change", updateFairyBehaviorExperienceCount);
  const enabledControl = element("label", "external-provider-toggle");
  enabledControl.append(element("span", "", "Enabled"), enabled);
  heading.firstElementChild.append(enabledControl);

  const id = fairyInput("text", "id", experience.id || "", { required: "", maxlength: "64", pattern: "[a-z0-9._-]+" });
  id.addEventListener("input", () => {
    heading.querySelector("[data-entry-title]").textContent = id.value || "New behavior experience";
  });
  const scope = fairySelect("scope", [
    ["all", "All conversations"], ["private", "Private only"], ["group", "Groups only"],
  ], experience.scope || "all");
  scope.required = true;
  const identity = element("div", "field-grid behavior-experience-grid");
  identity.append(
    fairyField("Experience ID", id),
    fairyField("Scope", scope),
    fairyField("Keywords (one per line)", fairyTextarea("keywords", experience.keywords || [], { rows: "3", maxlength: "600", required: "" })),
  );
  const content = element("div", "field-grid behavior-experience-content-grid");
  content.append(
    fairyField("Scene", fairyTextarea("scene", experience.scene || "", { rows: "4", maxlength: "240", required: "" })),
    fairyField("Recommended action", fairyTextarea("action", experience.action || "", { rows: "4", maxlength: "600", required: "" })),
    fairyField("Observed outcome", fairyTextarea("outcome", experience.outcome || "", { rows: "4", maxlength: "400", required: "" })),
  );
  row.append(heading, identity, content);
  return row;
}

function renderFairyBehaviorExperiences(config) {
  const experiences = config.behavior_experiences || [];
  document.querySelector("#fairy-behavior-experience-list")
    .replaceChildren(...experiences.map(createFairyBehaviorExperienceRow));
  const autoLearning = document.querySelector("#fairy-behavior-auto-learning");
  autoLearning.textContent = config.behavior_auto_learning ? "Auto learning on" : "Auto learning off";
  autoLearning.className = `status-badge ${config.behavior_auto_learning ? "enabled" : "offline"}`;
  updateFairyBehaviorExperienceCount();
}

function collectFairyBehaviorExperiences() {
  return [...document.querySelectorAll(".fairy-behavior-experience-row")].map((row) => ({
    id: row.querySelector("[data-field='id']").value.trim(),
    enabled: row.querySelector("[data-field='enabled']").checked,
    scope: row.querySelector("[data-field='scope']").value,
    keywords: fairyLineValues(row.querySelector("[data-field='keywords']")),
    scene: row.querySelector("[data-field='scene']").value.trim(),
    action: row.querySelector("[data-field='action']").value.trim(),
    outcome: row.querySelector("[data-field='outcome']").value.trim(),
  }));
}

function renderFairy(payload) {
  state.fairy = payload;
  const config = payload.config || {};
  const plugins = payload.plugins || [];
  const connectionBadge = document.querySelector("#fairy-connection-state");
  connectionBadge.textContent = payload.connected ? "Connected" : "Connecting";
  connectionBadge.className = `status-badge ${payload.connected ? "enabled" : "offline"}`;
  const modelBadge = document.querySelector("#fairy-model-state");
  modelBadge.textContent = config.model_enabled ? "AI enabled" : "AI disabled";
  modelBadge.className = `status-badge ${config.model_enabled ? "enabled" : "offline"}`;
  const agentBadge = document.querySelector("#fairy-agent-state");
  agentBadge.textContent = config.agent_enabled ? "Planner enabled" : "Planner disabled";
  agentBadge.className = `status-badge ${config.agent_enabled ? "enabled" : "offline"}`;
  const visionBadge = document.querySelector("#fairy-vision-state");
  visionBadge.textContent = config.vision_enabled ? "Vision enabled" : "Vision disabled";
  visionBadge.className = `status-badge ${config.vision_enabled ? "enabled" : "offline"}`;
  const transcriberBadge = document.querySelector("#fairy-transcriber-state");
  transcriberBadge.textContent = config.transcriber_enabled ? "Voice enabled" : "Voice disabled";
  transcriberBadge.className = `status-badge ${config.transcriber_enabled ? "enabled" : "offline"}`;
  renderFairyModelRouting(config);
  renderFairyExternalProviders(config);
  renderFairyBehaviorExperiences(config);
  document.querySelector("#fairy-system-prompt").value = config.system_prompt || "";
  document.querySelector("#fairy-group-default").checked = Boolean(config.group_default_enabled);
  document.querySelector("#fairy-group-soft-trigger").value = config.group_soft_trigger || "shadow";
  document.querySelector("#fairy-focus-ttl").value = config.focus_ttl_seconds ?? 120;
  document.querySelector("#fairy-soft-cooldown").value = config.soft_cooldown_seconds ?? 30;
  document.querySelector("#fairy-expression-style").value = config.expression_style || "normal";
  document.querySelector("#fairy-daily-limit").value = config.model_daily_limit ?? 0;
  document.querySelector("#fairy-max-concurrent").value = config.max_concurrent ?? 4;
  document.querySelector("#fairy-rate-limit").value = config.rate_limit_seconds ?? 8;
  document.querySelector("#fairy-context-ttl").value = config.context_ttl_seconds ?? 1800;
  document.querySelector("#fairy-context-messages").value = config.context_messages ?? 12;
  document.querySelector("#fairy-zzz-api-url").value = config.zzz_api_url || "";
  document.querySelector("#fairy-zzz-timeout").value = config.zzz_request_timeout_seconds ?? 15;

  const pluginRows = plugins.map((plugin) => {
    const row = document.createElement("label");
    row.className = "plugin-row";
    const identity = document.createElement("span");
    identity.append(
      element("strong", "", plugin.name || plugin.id),
      element("small", "", `${plugin.description || ""} ${plugin.command || ""}`.trim()),
    );
    const toggle = document.createElement("input");
    toggle.type = "checkbox";
    toggle.role = "switch";
    toggle.checked = Boolean(plugin.enabled);
    toggle.dataset.pluginId = plugin.id;
    row.append(identity, toggle);
    return row;
  });
  document.querySelector("#fairy-plugin-list").replaceChildren(...pluginRows);
  const enabledPlugins = plugins.filter((plugin) => plugin.enabled).length;
  const pluginBadge = document.querySelector("#fairy-plugin-count");
  pluginBadge.textContent = `${enabledPlugins} enabled`;
  pluginBadge.className = `status-badge ${enabledPlugins ? "enabled" : "offline"}`;
  renderFairyRuntime(payload.runtime || {}, payload.config_status || {});
}

function fairyConfigRevisionLabel(value) {
  const revision = String(value ?? "0");
  return revision === "0" ? "Environment baseline" : `r${revision}`;
}

function renderFairyRuntime(runtime, configStatus) {
  const scheduler = runtime.scheduler || {};
  const quota = runtime.model_quota || {};
  const trace = runtime.trace_24h || {};
  const behavior = runtime.behavior || {};
  const factMemory = runtime.fact_memory || {};
  const behaviorExperiences = runtime.behavior_experiences || {};
  const outbound = runtime.outbound_delivery || {};
  const feedback = runtime.feedback_24h || {};
  const taskQuotas = runtime.task_model_quotas || [];
  const modelHealth = trace.model_health || [];
  const recentFailures = trace.recent_failures || [];
  const gateActions = trace.gate_actions || {};
  const hasConfigStatus = Boolean(configStatus.schema_version);
  const revision = hasConfigStatus ? fairyConfigRevisionLabel(configStatus.revision) : "-";
  const activeRevision = hasConfigStatus ? fairyConfigRevisionLabel(configStatus.active_revision) : "-";
  const revisionSummary = hasConfigStatus && String(configStatus.revision ?? "0") !== String(configStatus.active_revision ?? "0")
    ? `${revision} desired / ${activeRevision} active`
    : revision;
  appendDetails(document.querySelector("#fairy-runtime-details"), [
    ["Config schema", configStatus.schema_version ? `v${configStatus.schema_version}` : "-"],
    ["Config revision", revisionSummary],
    ["Config updated", formatDate(configStatus.updated_at)],
    ["Admission", scheduler.accepting ? "Accepting" : "Closed"],
    ["Scheduler", `${scheduler.active || 0} active / ${scheduler.pending || 0} pending`],
    ["Queue limits", `${scheduler.conversations || 0} conversations · ${scheduler.max_pending || 0} pending max`],
    ["Model quota", `${quota.used || 0} used / ${quota.remaining || 0} remaining`],
    ["Fact memory", factMemory.available ? `${factMemory.facts || 0} facts / ${factMemory.stored_scopes || 0} stored scopes / ${factMemory.enabled_scopes || 0} enabled` : "Unavailable"],
    ["Behavior experiences", `${behaviorExperiences.configured || 0} configured / ${behaviorExperiences.enabled || 0} enabled`],
    ["Behavior auto learning", behaviorExperiences.auto_learning ? "Enabled" : "Disabled"],
    ["Outbound replies", `${outbound.delivered || 0} delivered / ${outbound.failed || 0} failed`],
    ["Outbound retries", `${outbound.retry_attempts || 0} retries / ${outbound.outcome_unknown || 0} unknown outcomes`],
    ["Explicit feedback · 24h", feedback.available ? `${feedback.rated_outputs || 0} rated replies · ${feedback.positive || 0} positive / ${feedback.negative || 0} negative` : "Unavailable"],
    ["Positive rate · 24h", feedback.available && (feedback.positive || feedback.negative) ? `${(Number(feedback.positive_rate || 0) * 100).toFixed(1)}%` : "-"],
    ["Model attempts · 24h", `${trace.model_completed || 0} completed / ${trace.model_failed || 0} failed`],
    ["Tokens · 24h", `${trace.input_tokens || 0} in / ${trace.output_tokens || 0} out`],
    ["Model cost · 24h", formatMicroUSD(trace.cost_microusd)],
    ["Tool calls · 24h", `${trace.tool_completed || 0} completed / ${trace.tool_failed || 0} failed`],
    ["Gate · 24h", `${gateActions.trigger || 0} trigger / ${gateActions.wait || 0} wait / ${gateActions.ignore || 0} ignore / ${gateActions.reject || 0} reject`],
    ["Gate reasons · 24h", formatCountMap(trace.gate_reasons)],
    ["Soft trigger", behavior.group_soft_trigger || "-"],
    ["Focus / cooldown", `${behavior.focus_ttl_seconds || 0}s / ${behavior.soft_cooldown_seconds || 0}s`],
    ["Expression", behavior.expression_style || "-"],
  ]);

  const configState = document.querySelector("#fairy-config-state");
  if (!hasConfigStatus) {
    configState.textContent = "Config unavailable";
    configState.className = "status-badge offline";
  } else if (configStatus.state === "restart_pending") {
    configState.textContent = "Restart pending";
    configState.className = "status-badge error";
  } else if (configStatus.state === "applying") {
    configState.textContent = "Applying config";
    configState.className = "status-badge offline";
  } else {
    configState.textContent = "Config active";
    configState.className = "status-badge enabled";
  }

  const configSectionLabels = {
    model: "Model routing",
    prompt: "System prompt",
    behavior: "Behavior",
    runtime_limits: "Runtime limits",
    plugins: "Plugins",
    external_tools: "External tools",
    behavior_experiences: "Behavior experiences",
    none: "No value changes",
  };
  const configChanges = Array.isArray(configStatus.recent_changes) ? configStatus.recent_changes : [];
  const configRows = configChanges.map((change) => {
    const row = document.createElement("tr");
    const sections = Array.isArray(change.sections)
      ? change.sections.map((section) => configSectionLabels[section]).filter(Boolean).join(" · ")
      : "";
    row.append(
      element("td", "mono", fairyConfigRevisionLabel(change.revision)),
      element("td", "", formatDate(change.updated_at)),
      element("td", "", sections || "Unknown"),
    );
    return row;
  });
  document.querySelector("#fairy-config-history").replaceChildren(...configRows);
  document.querySelector("#fairy-config-history-empty").hidden = configRows.length > 0;
  document.querySelector(".runtime-config-history-table").hidden = configRows.length === 0;

  const taskQuotaRows = taskQuotas.map((task) => {
    const row = document.createElement("tr");
    row.append(
      element("td", "", task.task_id || "-"),
      element("td", "", Number(task.used || 0).toLocaleString()),
      element("td", "", Number(task.remaining || 0).toLocaleString()),
      element("td", "", Number(task.daily_limit || 0).toLocaleString()),
    );
    return row;
  });
  document.querySelector("#fairy-runtime-task-quotas").replaceChildren(...taskQuotaRows);
  document.querySelector("#fairy-runtime-task-quotas-empty").hidden = taskQuotas.length > 0;
  document.querySelector(".runtime-task-quota-table").hidden = taskQuotas.length === 0;

  const modelHealthRows = modelHealth.map((model) => {
    const attempts = Number(model.attempts || 0);
    const completed = Number(model.completed || 0);
    const failed = Number(model.failed || 0);
    const successRate = attempts > 0 ? `${((completed / attempts) * 100).toFixed(1)}% success` : "No calls";
    let healthLabel = "Healthy";
    let healthClass = "enabled";
    if (failed > 0 && completed > 0) {
      healthLabel = "Degraded";
      healthClass = "warning";
    } else if (failed > 0) {
      healthLabel = "Failing";
      healthClass = "error";
    }
    const row = document.createElement("tr");
    const identity = document.createElement("td");
    identity.append(
      element("span", "cell-title", model.model_id || "-"),
      element("span", "cell-subtitle", model.provider_id || "-"),
    );
    const health = document.createElement("td");
    health.append(element("span", `status-badge ${healthClass}`, healthLabel));
    const calls = document.createElement("td");
    calls.append(
      element("span", "cell-title", `${completed} / ${attempts}`),
      element("span", "cell-subtitle", successRate),
    );
    row.append(
      identity,
      element("td", "", model.task_id || "-"),
      health,
      calls,
      element("td", "", Number(model.fallback_attempts || 0).toLocaleString()),
      element("td", "", `P50 ${formatMilliseconds(model.p50_ms)} / P95 ${formatMilliseconds(model.p95_ms)}`),
      element("td", "", `${Number(model.input_tokens || 0).toLocaleString()} in / ${Number(model.output_tokens || 0).toLocaleString()} out`),
      element("td", "", formatMicroUSD(model.cost_microusd)),
      element("td", "", formatCountMap(model.failure_codes, 6)),
    );
    return row;
  });
  document.querySelector("#fairy-runtime-model-health").replaceChildren(...modelHealthRows);
  document.querySelector("#fairy-runtime-model-health-empty").hidden = modelHealth.length > 0;
  document.querySelector(".runtime-model-health-table").hidden = modelHealth.length === 0;

  const failureKindLabels = { model: "Model", tool: "Tool", admission: "Admission", turn: "Turn" };
  const recentFailureRows = recentFailures.map((failure) => {
    const row = document.createElement("tr");
    const type = document.createElement("td");
    type.append(element("span", "status-badge error", failureKindLabels[failure.kind] || "Failure"));
    let target = "Scheduler";
    let targetDetail = "";
    let details = "-";
    if (failure.kind === "model") {
      target = failure.model_id || "-";
      targetDetail = failure.provider_id || "-";
      const parts = [failure.task_id || "-"];
      if (Number(failure.attempt || 0) > 0) parts.push(`attempt ${failure.attempt}`);
      if (failure.fallback) parts.push("fallback");
      if (Number(failure.step || 0) > 0) parts.push(`step ${failure.step}`);
      details = parts.join(" · ");
    } else if (failure.kind === "tool") {
      target = failure.tool_name || "-";
      details = failure.tool_status || "-";
      if (Number(failure.step || 0) > 0) details += ` · step ${failure.step}`;
    } else if (failure.kind === "admission") {
      details = `${Number(failure.queue_depth || 0)} queued · ${Number(failure.pending_turns || 0)} pending`;
    }
    const targetCell = document.createElement("td");
    targetCell.append(element("span", "cell-title", target));
    if (targetDetail) targetCell.append(element("span", "cell-subtitle", targetDetail));
    row.append(
      element("td", "", formatDate(failure.occurred_at)),
      type,
      targetCell,
      element("td", "mono", failure.code || "-"),
      element("td", "", Number(failure.duration_ms || 0) > 0 ? formatMilliseconds(failure.duration_ms) : "-"),
      element("td", "", details),
    );
    return row;
  });
  document.querySelector("#fairy-runtime-recent-failures").replaceChildren(...recentFailureRows);
  document.querySelector("#fairy-runtime-recent-failures-empty").hidden = recentFailures.length > 0;
  document.querySelector(".runtime-recent-failures-table").hidden = recentFailures.length === 0;

  const traceBadge = document.querySelector("#fairy-trace-state");
  traceBadge.textContent = runtime.trace_available ? "Trace online" : "Trace unavailable";
  traceBadge.className = `status-badge ${runtime.trace_available ? "enabled" : "offline"}`;

  const providers = runtime.external_tool_providers || [];
  const providerLabels = {
    ready: "Ready", disabled: "Disabled", startup_failed: "Startup failed",
    circuit_open: "Circuit open", unavailable: "Unavailable", closed: "Closed",
  };
  const providerRows = providers.map((provider) => {
    const row = document.createElement("tr");
    const id = document.createElement("td");
    id.append(element("span", "cell-title", provider.id || "-"));
    const providerStatus = provider.status || "unavailable";
    const status = document.createElement("td");
    status.append(statusBadge(providerLabels[providerStatus] || providerStatus, providerStatus === "ready"));
    row.append(
      id, status, element("td", "", String(provider.tools || 0)),
      element("td", "", String(provider.consecutive_failures || 0)),
      element("td", "", provider.circuit_open_until ? formatDate(provider.circuit_open_until) : "-"),
    );
    return row;
  });
  document.querySelector("#fairy-runtime-providers").replaceChildren(...providerRows);
  document.querySelector("#fairy-runtime-providers-empty").hidden = providers.length > 0;
  document.querySelector(".runtime-provider-table").hidden = providers.length === 0;

  const tools = runtime.tools || [];
  const rows = tools.map((tool) => {
    const row = document.createElement("tr");
    const name = document.createElement("td");
    name.append(element("span", "cell-title", tool.name));
    const enabled = document.createElement("td");
    enabled.append(statusBadge(tool.enabled ? "Enabled" : "Disabled", tool.enabled));
    const policy = document.createElement("td");
    policy.append(statusBadge(tool.policy_allowed ? "Allowed" : "Denied", tool.policy_allowed));
    const risk = element("td", "", tool.risk || "-");
    const execution = element("td", "", `${tool.idempotency || "-"} · ${tool.concurrency || "-"} · ${formatMilliseconds(tool.timeout_millis)}`);
    row.append(name, enabled, policy, risk, execution);
    return row;
  });
  document.querySelector("#fairy-runtime-tools").replaceChildren(...rows);
  document.querySelector("#fairy-runtime-tools-empty").hidden = tools.length > 0;
  document.querySelector(".runtime-tool-table").hidden = tools.length === 0;
}

async function loadFairy() {
  try {
    const [payload, evaluation] = await Promise.all([api("fairy/config"), api("fairy/model-eval")]);
    renderFairy(payload);
    renderFairyModelEvaluation(evaluation);
    const configState = payload.config_status?.state;
    const saveNote = document.querySelector("#fairy-save-note");
    if (configState === "restart_pending") {
      saveNote.textContent = "Restart pending";
    } else if (configState === "applying") {
      saveNote.textContent = "Applying";
    } else {
      saveNote.textContent = "Ready";
    }
    if (evaluation.status === "running") scheduleFairyEvaluationPoll(evaluation.job_id);
  } catch (error) {
    const badge = document.querySelector("#fairy-connection-state");
    badge.textContent = "Unavailable";
    badge.className = "status-badge offline";
    throw error;
  }
}

async function setActiveView(view) {
  if (view !== "fairy") {
    window.clearTimeout(state.fairyEvaluationPollTimer);
    state.fairyEvaluationPollTimer = null;
  }
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
    fairy: loadFairy,
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

document.querySelector("#fairy-add-provider").addEventListener("click", () => {
  const existing = new Set(fairyProviderIDs());
  let index = existing.size + 1;
  while (existing.has(`provider-${index}`)) index += 1;
  document.querySelector("#fairy-provider-list").append(createFairyProviderRow({ id: `provider-${index}` }));
  refreshFairyProviderOptions();
  updateFairyRouteCounts();
});

document.querySelector("#fairy-add-model").addEventListener("click", () => {
  const existing = new Set(fairyModelIDs());
  let index = existing.size + 1;
  while (existing.has(`model-${index}`)) index += 1;
  document.querySelector("#fairy-model-list").append(createFairyModelRow({
    id: `model-${index}`,
    provider_id: fairyProviderIDs()[0] || "",
  }));
  refreshFairyProviderOptions();
  refreshFairyModelOptions();
  updateFairyRouteCounts();
});

document.querySelector("#fairy-add-task").addEventListener("click", () => {
  const existing = new Set([...document.querySelectorAll(".fairy-task-row [data-field='id']")].map((input) => input.value.trim()));
  let id = ["replyer", "planner", "vision", "transcriber", "utility"]
    .find((candidate) => !existing.has(candidate)) || "task-1";
  let index = 1;
  while (existing.has(id)) id = `task-${++index}`;
  const task = createFairyTaskRow({ id, candidate_models: fairyModelIDs().slice(0, 1) });
  document.querySelector("#fairy-task-list").append(task);
  refreshFairyModelOptions();
  updateFairyRouteCounts();
});

document.querySelector("#fairy-add-external-provider").addEventListener("click", () => {
  const existing = new Set([...document.querySelectorAll(".fairy-external-provider-row [data-field='id']")]
    .map((input) => input.value.trim()));
  let index = existing.size + 1;
  while (existing.has(`tools-${index}`)) index += 1;
  document.querySelector("#fairy-external-provider-list").append(createFairyExternalProviderRow({
    id: `tools-${index}`, enabled: false, protocol: "mcp-stdio",
  }));
  updateFairyExternalProviderCount();
});

document.querySelector("#fairy-add-behavior-experience").addEventListener("click", () => {
  const existing = new Set([...document.querySelectorAll(".fairy-behavior-experience-row [data-field='id']")]
    .map((input) => input.value.trim()));
  let index = existing.size + 1;
  while (existing.has(`experience-${index}`)) index += 1;
  document.querySelector("#fairy-behavior-experience-list").append(createFairyBehaviorExperienceRow({
    id: `experience-${index}`, enabled: true, scope: "all",
  }));
  updateFairyBehaviorExperienceCount();
});

document.querySelector("#fairy-config-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const saveButton = document.querySelector("#fairy-save-button");
  const pluginEnabled = {};
  document.querySelectorAll("#fairy-plugin-list input[data-plugin-id]").forEach((toggle) => {
    pluginEnabled[toggle.dataset.pluginId] = toggle.checked;
  });
  const routing = collectFairyModelRouting();
  if (routing.tasks.some((task) => task.candidate_models.length === 0)) {
    showToast("Every model task requires at least one candidate", true);
    return;
  }
  const replyerTask = routing.tasks.find((task) => task.id === "replyer");
  const payload = {
    providers: routing.providers,
    models: routing.models,
    tasks: routing.tasks,
    external_tool_providers: collectFairyExternalProviders(),
    behavior_experiences: collectFairyBehaviorExperiences(),
    model_daily_limit: Number(document.querySelector("#fairy-daily-limit").value),
    model_max_tokens: replyerTask?.max_output_tokens ?? state.fairy?.config?.model_max_tokens ?? 600,
    system_prompt: document.querySelector("#fairy-system-prompt").value,
    group_default_enabled: document.querySelector("#fairy-group-default").checked,
    group_soft_trigger: document.querySelector("#fairy-group-soft-trigger").value,
    focus_ttl_seconds: Number(document.querySelector("#fairy-focus-ttl").value),
    soft_cooldown_seconds: Number(document.querySelector("#fairy-soft-cooldown").value),
    expression_style: document.querySelector("#fairy-expression-style").value,
    rate_limit_seconds: Number(document.querySelector("#fairy-rate-limit").value),
    context_ttl_seconds: Number(document.querySelector("#fairy-context-ttl").value),
    context_messages: Number(document.querySelector("#fairy-context-messages").value),
    max_concurrent: Number(document.querySelector("#fairy-max-concurrent").value),
    zzz_api_url: document.querySelector("#fairy-zzz-api-url").value,
    zzz_request_timeout_seconds: Number(document.querySelector("#fairy-zzz-timeout").value),
    plugin_enabled: pluginEnabled,
  };
  saveButton.disabled = true;
  try {
    const response = await api("fairy/config", { method: "PATCH", body: JSON.stringify(payload) });
    renderFairy(response);
    const saveNote = document.querySelector("#fairy-save-note");
    if (response.restart_scheduled) {
      saveNote.textContent = "Restart scheduled";
      showToast("Fairy settings saved; service is restarting");
      window.setTimeout(() => {
        if (state.activeView === "fairy") loadFairy().catch(() => {});
      }, 2500);
    } else if (response.applied_live) {
      saveNote.textContent = "Applied live";
      showToast("Fairy behavior applied live");
    } else {
      saveNote.textContent = "Saved";
      showToast("Fairy settings saved");
    }
  } catch (error) {
    showToast(error.message, true);
  } finally {
    saveButton.disabled = false;
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
