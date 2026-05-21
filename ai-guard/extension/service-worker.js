const NATIVE_HOST = "com.wininfosoft.ai_guard";
const CLAUDE_HOSTS = ["claude.ai"];
const STATUS_CACHE_TTL_MS = 2000;
const CLAUDE_PRESENCE_CACHE_TTL_MS = 1000;

const daemonState = {
  baseUrl: "http://127.0.0.1:48555",
  token: null,
  blockedHosts: [
    "chatgpt.com",
    "chat.openai.com",
    "gemini.google.com",
    "perplexity.ai",
  ],
  mode: "idle",
  activeSources: [],
  lastStatusAt: 0,
  lastClaudePresenceAt: 0,
};

let claudePresencePromise = null;

bootstrap()
  .then(() => auditExistingTabs({ forcePresenceSync: true }))
  .catch(console.error);

chrome.runtime.onInstalled.addListener(() => {
  bootstrap()
    .then(() => auditExistingTabs({ forcePresenceSync: true }))
    .catch(console.error);
});

chrome.runtime.onStartup.addListener(() => {
  bootstrap()
    .then(() => auditExistingTabs({ forcePresenceSync: true }))
    .catch(console.error);
});

chrome.tabs.onCreated.addListener((tab) => {
  const nextUrl = tab.pendingUrl || tab.url;
  if (!tab.id || !nextUrl) {
    return;
  }

  evaluateTab(tab.id, nextUrl).catch(console.error);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const nextUrl = changeInfo.url || tab.url;
  if (!nextUrl) {
    return;
  }

  evaluateTab(tabId, nextUrl).catch(console.error);
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    if (tab.url) {
      await evaluateTab(tabId, tab.url);
    }
  } catch (error) {
    console.error("AI Guard activation check failed", error);
  }
});

chrome.tabs.onRemoved.addListener(() => {
  syncClaudePresence({ force: true }).catch(console.error);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || !message.type) {
    return false;
  }

  if (message.type === "scan") {
    daemonFetch("/scan", {
      method: "POST",
      body: { text: message.text || "" },
    })
      .then((response) => sendResponse(response))
      .catch((error) =>
        sendResponse({
          action: "block",
          redacted_text: "",
          reason: `AI Guard Agent is unavailable: ${error.message}`,
        }),
      );
    return true;
  }

  if (message.type === "activity") {
    syncClaudePresence({ force: true })
      .then(() => {
        if (daemonState.mode === "active") {
          auditExistingTabs().catch(console.error);
        }
        sendResponse({ ok: true, mode: daemonState.mode });
      })
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  if (message.type === "status") {
    refreshStatus(true)
      .then((status) => sendResponse(status))
      .catch((error) => sendResponse({ mode: "idle", error: error.message }));
    return true;
  }

  return false;
});

async function bootstrap() {
  if (daemonState.token) {
    return daemonState;
  }

  const response = await chrome.runtime.sendNativeMessage(NATIVE_HOST, {
    type: "hello",
    extension_id: chrome.runtime.id,
  });

  if (!response || response.type !== "hello") {
    throw new Error(response?.message || "native bootstrap failed");
  }

  daemonState.token = response.token;
  daemonState.baseUrl = response.base_url;
  daemonState.blockedHosts = Array.isArray(response.blocked_hosts)
    ? response.blocked_hosts
    : daemonState.blockedHosts;
  daemonState.mode = response.mode || daemonState.mode;
  daemonState.lastStatusAt = Date.now();
  return daemonState;
}

async function daemonFetch(path, options = {}) {
  await bootstrap();

  const headers = new Headers(options.headers || {});
  headers.set("Authorization", `Bearer ${daemonState.token}`);
  headers.set("Content-Type", "application/json");

  let response;
  try {
    response = await fetch(`${daemonState.baseUrl}${path}`, {
      method: options.method || "GET",
      headers,
      body: options.body ? JSON.stringify(options.body) : undefined,
      cache: "no-store",
    });
  } catch (error) {
    return retryDaemonFetch(path, options, error);
  }

  if (!response.ok) {
    const body = await response.text();
    if (response.status === 401 || response.status === 403) {
      return retryDaemonFetch(
        path,
        options,
        new Error(body || `daemon request failed with status ${response.status}`),
      );
    }
    throw new Error(
      body || `daemon request failed with status ${response.status}`,
    );
  }

  return response.json();
}

async function retryDaemonFetch(path, options, originalError) {
  if (options.__retried) {
    throw originalError;
  }

  daemonState.token = null;
  daemonState.baseUrl = "http://127.0.0.1:48555";
  daemonState.lastStatusAt = 0;
  await bootstrap();
  return daemonFetch(path, { ...options, __retried: true });
}

async function refreshStatus(force = false) {
  const ageMs = Date.now() - daemonState.lastStatusAt;
  if (!force && ageMs < STATUS_CACHE_TTL_MS) {
    return snapshot();
  }

  try {
    const status = await daemonFetch("/status");
    applyStatus(status);
  } catch (error) {
    console.warn("AI Guard status refresh failed", error);
  }

  return snapshot();
}

async function syncClaudePresence({ force = false } = {}) {
  const ageMs = Date.now() - daemonState.lastClaudePresenceAt;
  if (!force && ageMs < CLAUDE_PRESENCE_CACHE_TTL_MS) {
    return snapshot();
  }

  if (claudePresencePromise) {
    return claudePresencePromise;
  }

  claudePresencePromise = (async () => {
    const tabs = await chrome.tabs.query({});
    const claudeTabs = tabs.filter((tab) => isClaudeUrl(tab.pendingUrl || tab.url));
    const hasClaudeTabs = claudeTabs.length > 0;
    const pageUrl =
      claudeTabs.find((tab) => tab.active)?.pendingUrl ||
      claudeTabs.find((tab) => tab.active)?.url ||
      claudeTabs[0]?.pendingUrl ||
      claudeTabs[0]?.url ||
      "https://claude.ai/";

    daemonState.lastClaudePresenceAt = Date.now();

    if (!force && !hasClaudeTabs && daemonState.mode === "idle") {
      return snapshot();
    }

    try {
      const status = await daemonFetch("/extension/activity", {
        method: "POST",
        body: {
          page_url: pageUrl,
          tab_visible: hasClaudeTabs,
        },
      });
      applyStatus(status);
    } catch (error) {
      console.warn("AI Guard Claude presence sync failed", error);
    }

    return snapshot();
  })();

  try {
    return await claudePresencePromise;
  } finally {
    claudePresencePromise = null;
  }
}

function applyStatus(status) {
  if (!status) {
    return;
  }

  daemonState.mode = status.mode || daemonState.mode;
  daemonState.activeSources = Array.isArray(status.active_sources)
    ? status.active_sources
    : [];
  daemonState.blockedHosts = Array.isArray(status.blocked_hosts)
    ? status.blocked_hosts
    : daemonState.blockedHosts;
  daemonState.lastStatusAt = Date.now();
}

function snapshot() {
  return {
    mode: daemonState.mode,
    active_sources: daemonState.activeSources,
    blocked_hosts: daemonState.blockedHosts,
  };
}

async function evaluateTab(tabId, url) {
  if (!url || url.startsWith(chrome.runtime.getURL(""))) {
    return;
  }

  await syncClaudePresence();
  const status = await refreshStatus(isClaudeUrl(url));
  if (isClaudeUrl(url)) {
    return;
  }

  if (status.mode !== "active") {
    return;
  }

  if (!matchesBlockedHost(url)) {
    return;
  }

  await chrome.tabs.update(tabId, {
    url: blockedPageUrl(url),
  });
}

async function auditExistingTabs({ forcePresenceSync = false } = {}) {
  if (forcePresenceSync) {
    await syncClaudePresence({ force: true });
  }
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (tab.id && tab.url) {
      await evaluateTab(tab.id, tab.url);
    }
  }
}

function matchesBlockedHost(url) {
  const hostname = hostnameForUrl(url);
  if (!hostname) {
    return false;
  }

  return matchesHost(hostname, daemonState.blockedHosts);
}

function isClaudeUrl(url) {
  const hostname = hostnameForUrl(url);
  if (!hostname) {
    return false;
  }

  return matchesHost(hostname, CLAUDE_HOSTS);
}

function hostnameForUrl(url) {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch (_error) {
    return null;
  }
}

function matchesHost(hostname, candidates) {
  return candidates.some((candidate) => {
    const normalized = String(candidate || "").toLowerCase();
    return hostname === normalized || hostname.endsWith(`.${normalized}`);
  });
}

function blockedPageUrl(originalUrl) {
  const params = new URLSearchParams({ target: originalUrl });
  return chrome.runtime.getURL(`blocked.html?${params.toString()}`);
}
