"use strict";

const state = {
  activeView: "dashboard",
  users: [],
  groups: [],
  conversations: [],
  selectedGroup: null,
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
    const edit = element("button", "table-button", "Edit");
    edit.type = "button";
    edit.addEventListener("click", () => openUserEditor(user));
    actions.append(edit);
    row.append(identity, status, created, actions);
    return row;
  });
  document.querySelector("#users-body").replaceChildren(...rows);
  document.querySelector("#users-empty").hidden = rows.length !== 0;
}

function openUserEditor(user) {
  const dialog = document.querySelector("#edit-user-dialog");
  document.querySelector("#edit-user-id").textContent = user.id;
  document.querySelector("#edit-user-nickname").value = user.nickname || user.id;
  dialog.dataset.userId = user.id;
  dialog.showModal();
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
    groups: loadGroups,
    conversations: loadConversations,
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
document.querySelector("#group-search").addEventListener("input", renderGroups);
document.querySelector("#conversation-search").addEventListener("input", renderConversations);

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
    dialog.close();
    showToast("User updated");
    await loadUsers();
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
