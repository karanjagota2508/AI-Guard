const DEBOUNCE_MS = 300;
const WARNING_ID = "ai-guard-warning";

let cachedScan = {
  text: "",
  response: null,
};

let submitBypassUntil = 0;
let submitInFlight = false;
let inputTimer = null;
let inputSequence = 0;

bootstrapClaudeObservers();

function bootstrapClaudeObservers() {
  document.addEventListener("paste", onPaste, true);
  document.addEventListener("input", onInput, true);
  document.addEventListener("keydown", onKeyDown, true);
  document.addEventListener("click", onClick, true);
  document.addEventListener("visibilitychange", onVisibilityChange, true);
  window.addEventListener("focus", () => notifyActivity(true));
  window.addEventListener("beforeunload", () => notifyActivity(false));

  notifyActivity(document.visibilityState === "visible");
  window.setInterval(() => {
    notifyActivity(document.visibilityState === "visible");
  }, 3000);
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

  inputSequence += 1;
  window.clearTimeout(inputTimer);
  const selectionSnapshot = captureEditorSelection(editor);
  event.preventDefault();
  stopEvent(event);
  notifyActivity(true);

  const response = await scanText(pastedText, "paste");
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

  notifyActivity(true);
  const scheduledSequence = ++inputSequence;
  window.clearTimeout(inputTimer);
  inputTimer = window.setTimeout(async () => {
    if (scheduledSequence !== inputSequence) {
      return;
    }

    const prompt = readEditorText(editor);
    if (!prompt.trim()) {
      return;
    }

    const response = await scanText(prompt, "debounce");
    if (scheduledSequence !== inputSequence) {
      return;
    }

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
  handleSubmit(editor).catch(console.error);
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
  handleSubmit(editor).catch(console.error);
}

function onVisibilityChange() {
  notifyActivity(document.visibilityState === "visible");
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
  inputSequence += 1;
  window.clearTimeout(inputTimer);
  notifyActivity(true);

  try {
    const response = await scanText(prompt, "submit");
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
  const label =
    `${element.getAttribute("aria-label") || ""} ${element.getAttribute("placeholder") || ""}`.toLowerCase();
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
  const label =
    `${button.getAttribute("aria-label") || ""} ${button.getAttribute("title") || ""} ${button.textContent || ""}`.toLowerCase();
  const dataTestId = (button.getAttribute("data-testid") || "").toLowerCase();
  if (label.includes("send") || dataTestId.includes("send")) {
    return true;
  }

  if (button.type === "submit" && button.closest("form")) {
    return true;
  }

  return false;
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

  return new Promise((resolve) => {
    chrome.runtime.sendMessage(
      {
        type: "scan",
        text,
        reason,
      },
      (response) => {
        if (chrome.runtime.lastError) {
          resolve({
            action: "block",
            redacted_text: "",
            reason: chrome.runtime.lastError.message,
          });
          return;
        }

        resolve(response);
      },
    );
  });
}

function notifyActivity(tabVisible) {
  chrome.runtime.sendMessage(
    {
      type: "activity",
      pageUrl: window.location.href,
      tabVisible,
    },
    () => {
      void chrome.runtime.lastError;
    },
  );
}

function showWarning(message) {
  let banner = document.getElementById(WARNING_ID);
  if (!banner) {
    banner = document.createElement("div");
    banner.id = WARNING_ID;
    banner.style.position = "fixed";
    banner.style.top = "16px";
    banner.style.right = "16px";
    banner.style.zIndex = "2147483647";
    banner.style.maxWidth = "360px";
    banner.style.padding = "12px 16px";
    banner.style.borderRadius = "12px";
    banner.style.background = "#8f1212";
    banner.style.color = "#ffffff";
    banner.style.boxShadow = "0 12px 30px rgba(0, 0, 0, 0.2)";
    banner.style.font = "600 13px/1.4 system-ui, sans-serif";
    document.body.appendChild(banner);
  }

  banner.textContent = `AI Guard Agent: ${message}`;
  banner.style.opacity = "1";
  window.clearTimeout(showWarning.timerId);
  showWarning.timerId = window.setTimeout(() => {
    const target = document.getElementById(WARNING_ID);
    if (target) {
      target.style.opacity = "0";
    }
  }, 4500);
}

showWarning.timerId = 0;

function stopEvent(event) {
  if (typeof event.stopImmediatePropagation === "function") {
    event.stopImmediatePropagation();
  }
  event.stopPropagation();
}

function delay(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}
