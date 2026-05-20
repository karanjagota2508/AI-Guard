const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");

const DEBOUNCE_MS = 300;
const WARNING_ID = "ai-guard-warning";
const BRIDGE_CONFIG_PATH = path.join(
  process.resourcesPath,
  "ai-guard-desktop-bridge.json",
);

let bridgeConfig = null;
let cachedScan = {
  text: "",
  response: null,
};
let submitBypassUntil = 0;
let submitInFlight = false;
let inputTimer = null;

bootstrapWhenReady();

function bootstrapWhenReady() {
  const start = () => {
    if (window.__aiGuardClaudeDesktopHook) {
      return;
    }

    if (!isSupportedTopLevelClaudeOrigin()) {
      return;
    }

    const loadedBridgeConfig = loadBridgeConfig();
    if (!loadedBridgeConfig) {
      return;
    }

    bridgeConfig = loadedBridgeConfig;
    window.__aiGuardClaudeDesktopHook = true;
    bootstrapClaudeObservers();
  };

  if (document.readyState === "loading") {
    window.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
}

function isSupportedTopLevelClaudeOrigin() {
  try {
    if (window.top !== window.self) {
      return false;
    }

    const url = new URL(window.location.href);
    const origin =
      url.origin === "null" ? `${url.protocol}//${url.host}` : url.origin;
    return (
      origin === "https://claude.ai" ||
      origin === "https://preview.claude.ai" ||
      origin === "https://claude.com" ||
      origin === "https://preview.claude.com" ||
      origin === "app://localhost" ||
      url.hostname === "localhost" ||
      origin.endsWith(".ant.dev")
    );
  } catch {
    return false;
  }
}

function loadBridgeConfig() {
  try {
    const raw = fs.readFileSync(BRIDGE_CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed.base_url || !parsed.token || !parsed.origin) {
      return null;
    }

    return parsed;
  } catch (error) {
    console.error(
      "AI Guard Agent: failed to load Claude Desktop bridge config",
      error,
    );
    return null;
  }
}

function bootstrapClaudeObservers() {
  document.addEventListener("paste", onPaste, true);
  document.addEventListener("input", onInput, true);
  document.addEventListener("keydown", onKeyDown, true);
  document.addEventListener("click", onClick, true);
}

async function onPaste(event) {
  const editor = resolveEditor(event.target);
  if (!editor) {
    return;
  }

  const pastedText = event.clipboardData?.getData("text/plain") || "";
  if (!pastedText.trim()) {
    return;
  }

  const selectionSnapshot = captureEditorSelection(editor);
  event.preventDefault();
  stopEvent(event);

  const response = await scanText(pastedText, "desktop_paste");
  cachedScan = { text: pastedText, response };

  if (response.action === "block") {
    showWarning(response.reason);
    return;
  }

  restoreEditorSelection(editor, selectionSnapshot);
  insertTextAtCursor(
    editor,
    response.action === "redact"
      ? response.redacted_text || pastedText
      : pastedText,
  );

  if (response.action === "redact") {
    showWarning(response.reason);
  }
}

function onInput(event) {
  const editor = resolveEditor(event.target);
  if (!editor) {
    return;
  }

  window.clearTimeout(inputTimer);
  inputTimer = window.setTimeout(async () => {
    const prompt = readEditorText(editor);
    if (!prompt.trim()) {
      return;
    }

    const response = await scanText(prompt, "desktop_debounce");
    cachedScan = { text: prompt, response };
    enforceDebouncedDecision(editor, prompt, response);
  }, DEBOUNCE_MS);
}

function onKeyDown(event) {
  if (Date.now() < submitBypassUntil) {
    return;
  }

  if (
    event.key !== "Enter" ||
    event.shiftKey ||
    event.ctrlKey ||
    event.altKey ||
    event.metaKey
  ) {
    return;
  }

  const editor = resolveEditor(event.target);
  if (!editor) {
    return;
  }

  event.preventDefault();
  stopEvent(event);
  handleSubmit(editor).catch((error) => {
    console.error(
      "AI Guard Agent: Claude Desktop submit interception failed",
      error,
    );
    showWarning("Claude Desktop prompt guard failed");
  });
}

function onClick(event) {
  const button =
    event.target instanceof Element ? event.target.closest("button") : null;
  if (!button || !isSendButton(button)) {
    return;
  }

  if (Date.now() < submitBypassUntil) {
    return;
  }

  const editor = findPrimaryEditor();
  if (!editor) {
    return;
  }

  event.preventDefault();
  stopEvent(event);
  handleSubmit(editor).catch((error) => {
    console.error(
      "AI Guard Agent: Claude Desktop click submit interception failed",
      error,
    );
    showWarning("Claude Desktop prompt guard failed");
  });
}

async function handleSubmit(editor) {
  if (submitInFlight) {
    return;
  }

  const prompt = readEditorText(editor);
  if (!prompt.trim()) {
    return;
  }

  submitInFlight = true;

  try {
    const response = await scanText(prompt, "desktop_submit");
    cachedScan = { text: prompt, response };

    if (response.action === "block") {
      showWarning(response.reason);
      return;
    }

    if (response.action === "redact") {
      replaceEditorText(editor, response.redacted_text || prompt);
      showWarning(response.reason);
      await delay(75);
    }

    triggerSubmit(editor);
  } finally {
    submitInFlight = false;
  }
}

function triggerSubmit(editor) {
  submitBypassUntil = Date.now() + 1500;
  const button = findSendButton();
  if (button) {
    button.click();
    return;
  }

  const form = editor.closest("form");
  if (form && typeof form.requestSubmit === "function") {
    form.requestSubmit();
  }
}

function resolveEditor(target) {
  if (
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLInputElement
  ) {
    return target;
  }

  if (target instanceof HTMLElement) {
    const editable = target.closest(
      'textarea, input[type="text"], [contenteditable="true"], [role="textbox"]',
    );
    if (editable instanceof HTMLElement) {
      return editable;
    }
  }

  return findPrimaryEditor();
}

function findPrimaryEditor() {
  const candidates = Array.from(
    document.querySelectorAll(
      'textarea, input[type="text"], [contenteditable="true"], [role="textbox"]',
    ),
  ).filter((element) => element instanceof HTMLElement && isVisible(element));

  candidates.sort((left, right) => scoreEditor(right) - scoreEditor(left));
  return candidates[0] || null;
}

function scoreEditor(element) {
  let score = 0;
  const label = `${element.getAttribute("aria-label") || ""} ${
    element.getAttribute("placeholder") || ""
  }`.toLowerCase();
  if (element.closest("main")) {
    score += 4;
  }
  if (
    label.includes("message") ||
    label.includes("prompt") ||
    label.includes("chat")
  ) {
    score += 4;
  }
  if (element.matches('[contenteditable="true"], [role="textbox"]')) {
    score += 2;
  }
  return score;
}

function isVisible(element) {
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function isSendButton(button) {
  const label = `${button.getAttribute("aria-label") || ""} ${
    button.getAttribute("title") || ""
  } ${button.textContent || ""}`.toLowerCase();
  const dataTestId = (button.getAttribute("data-testid") || "").toLowerCase();
  if (label.includes("send") || dataTestId.includes("send")) {
    return true;
  }

  return button.type === "submit" && !!button.closest("form");
}

function findSendButton() {
  const buttons = Array.from(document.querySelectorAll("button"));
  return (
    buttons.find(
      (button) =>
        button instanceof HTMLButtonElement &&
        isVisible(button) &&
        isSendButton(button),
    ) || null
  );
}

function readEditorText(editor) {
  if (
    editor instanceof HTMLTextAreaElement ||
    editor instanceof HTMLInputElement
  ) {
    return editor.value;
  }

  return editor.innerText || editor.textContent || "";
}

function replaceEditorText(editor, value) {
  if (
    editor instanceof HTMLTextAreaElement ||
    editor instanceof HTMLInputElement
  ) {
    editor.focus();
    editor.value = value;
    editor.selectionStart = value.length;
    editor.selectionEnd = value.length;
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    return;
  }

  editor.focus();
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(editor);
  selection.removeAllRanges();
  selection.addRange(range);

  replaceContentEditableSelection(editor, value);
  editor.dispatchEvent(new Event("input", { bubbles: true }));
}

function insertTextAtCursor(editor, value) {
  if (
    editor instanceof HTMLTextAreaElement ||
    editor instanceof HTMLInputElement
  ) {
    const start = editor.selectionStart ?? editor.value.length;
    const end = editor.selectionEnd ?? editor.value.length;
    const before = editor.value.slice(0, start);
    const after = editor.value.slice(end);
    editor.value = `${before}${value}${after}`;
    const cursor = before.length + value.length;
    editor.selectionStart = cursor;
    editor.selectionEnd = cursor;
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    return;
  }

  editor.focus();
  insertIntoContentEditableSelection(editor, value);
  editor.dispatchEvent(new Event("input", { bubbles: true }));
}

function enforceDebouncedDecision(editor, scannedText, response) {
  if (response.action === "allow") {
    return;
  }

  showWarning(response.reason);

  const liveText = readEditorText(editor);
  const normalizedLiveText = normalizePromptText(liveText);
  const normalizedScannedText = normalizePromptText(scannedText);
  if (!normalizedLiveText || normalizedLiveText !== normalizedScannedText) {
    return;
  }

  if (response.action !== "redact") {
    return;
  }

  const replacement = response.redacted_text || scannedText;
  if (!replacement || normalizePromptText(replacement) === normalizedLiveText) {
    return;
  }

  replaceEditorText(editor, replacement);
}

function normalizePromptText(value) {
  return String(value || "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/[\u200B-\u200D\uFEFF]/g, "")
    .trim();
}

function captureEditorSelection(editor) {
  if (
    editor instanceof HTMLTextAreaElement ||
    editor instanceof HTMLInputElement
  ) {
    return {
      type: "text",
      start: editor.selectionStart ?? editor.value.length,
      end: editor.selectionEnd ?? editor.value.length,
    };
  }

  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return null;
  }

  const range = selection.getRangeAt(0);
  if (!editor.contains(range.commonAncestorContainer)) {
    return null;
  }

  return {
    type: "contenteditable",
    range: range.cloneRange(),
  };
}

function restoreEditorSelection(editor, snapshot) {
  if (!snapshot) {
    editor.focus();
    return;
  }

  if (
    snapshot.type === "text" &&
    (editor instanceof HTMLTextAreaElement ||
      editor instanceof HTMLInputElement)
  ) {
    editor.focus();
    editor.selectionStart = snapshot.start;
    editor.selectionEnd = snapshot.end;
    return;
  }

  if (snapshot.type === "contenteditable" && snapshot.range) {
    editor.focus();
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(snapshot.range);
    return;
  }

  editor.focus();
}

function insertIntoContentEditableSelection(editor, value) {
  const inserted = document.execCommand("insertText", false, value);
  if (inserted) {
    return;
  }

  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) {
    editor.textContent = `${editor.textContent || ""}${value}`;
    return;
  }

  const range = selection.getRangeAt(0);
  range.deleteContents();
  const node = document.createTextNode(value);
  range.insertNode(node);
  range.setStartAfter(node);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
}

function replaceContentEditableSelection(editor, value) {
  const inserted = document.execCommand("insertText", false, value);
  if (inserted) {
    return;
  }

  editor.textContent = "";
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(editor);
  range.deleteContents();
  const node = document.createTextNode(value);
  range.insertNode(node);
  range.setStartAfter(node);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
}

async function scanText(text, reason) {
  if (cachedScan.text === text && cachedScan.response) {
    return cachedScan.response;
  }

  return desktopBridgeRequest("/scan", {
    method: "POST",
    body: {
      text,
    },
    reason,
  }).catch((error) => ({
    action: "block",
    redacted_text: "",
    reason: `Claude Desktop scan failed: ${error.message}`,
  }));
}

function desktopBridgeRequest(routePath, options) {
  if (!bridgeConfig) {
    return Promise.reject(new Error("missing Claude Desktop bridge config"));
  }

  const url = new URL(routePath, bridgeConfig.base_url);
  const payload = options.body ? JSON.stringify(options.body) : "";
  const client = url.protocol === "https:" ? https : http;

  return new Promise((resolve, reject) => {
    const request = client.request(
      url,
      {
        method: options.method || "GET",
        headers: {
          Authorization: `Bearer ${bridgeConfig.token}`,
          Origin: bridgeConfig.origin,
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(payload),
        },
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          if (response.statusCode < 200 || response.statusCode >= 300) {
            reject(new Error(`HTTP ${response.statusCode}: ${body}`));
            return;
          }

          try {
            resolve(body ? JSON.parse(body) : {});
          } catch (error) {
            reject(error);
          }
        });
      },
    );

    request.on("error", reject);
    request.setTimeout(3500, () =>
      request.destroy(new Error("desktop bridge timeout")),
    );

    if (payload) {
      request.write(payload);
    }

    request.end();
  });
}

function showWarning(message) {
  const text = message || "AI Guard Agent blocked this Claude Desktop prompt.";
  let toast = document.getElementById(WARNING_ID);
  if (!toast) {
    toast = document.createElement("div");
    toast.id = WARNING_ID;
    toast.style.position = "fixed";
    toast.style.top = "18px";
    toast.style.right = "18px";
    toast.style.zIndex = "2147483647";
    toast.style.maxWidth = "420px";
    toast.style.boxSizing = "border-box";
    toast.style.background = "#a11717";
    toast.style.color = "#ffffff";
    toast.style.padding = "16px 18px";
    toast.style.borderRadius = "16px";
    toast.style.boxShadow = "0 16px 32px rgba(0,0,0,0.24)";
    toast.style.font = "600 14px/1.45 sans-serif";
    toast.style.letterSpacing = "0.01em";
    toast.style.whiteSpace = "normal";
    toast.style.wordBreak = "break-word";
    toast.style.overflowWrap = "anywhere";
    document.documentElement.appendChild(toast);
  }

  toast.textContent = `AI Guard Agent: ${text}`;
  positionWarningToast(toast);
  window.clearTimeout(showWarning.timerId);
  showWarning.timerId = window.setTimeout(() => {
    toast.style.display = "none";
  }, 3500);
}

function positionWarningToast(toast) {
  const margin = 24;
  const viewportWidth = Math.max(
    document.documentElement.clientWidth || 0,
    window.innerWidth || 0,
  );
  const viewportHeight = Math.max(
    document.documentElement.clientHeight || 0,
    window.innerHeight || 0,
  );
  const maxWidth = Math.min(420, Math.max(260, viewportWidth - margin * 2));

  toast.style.maxWidth = `${maxWidth}px`;
  toast.style.width = "auto";
  toast.style.left = `${margin}px`;
  toast.style.top = `${margin}px`;
  toast.style.right = "auto";
  toast.style.display = "block";
  toast.style.visibility = "hidden";

  window.requestAnimationFrame(() => {
    const rect = toast.getBoundingClientRect();
    const width = Math.min(Math.ceil(rect.width || maxWidth), maxWidth);
    const height = Math.ceil(rect.height || 0);
    const x = Math.max(margin, viewportWidth - width - margin);
    const y = Math.max(margin, Math.min(margin, viewportHeight - height - margin));
    toast.style.left = `${x}px`;
    toast.style.top = `${y}px`;
    toast.style.visibility = "visible";
  });
}

function stopEvent(event) {
  event.stopPropagation();
  event.stopImmediatePropagation?.();
}

function delay(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}
