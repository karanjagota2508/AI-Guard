const DEBOUNCE_MS = 300;
const WARNING_ID = "ai-guard-warning";
const PII_WARNING_BAR_ID = "ai-guard-pii-warning-bar";

let submitBypassUntil = 0;
let submitInFlight = false;
let inputTimer = null;
let inputSequence = 0;
let piiWarningActive = false;
let activeRedactedText = "";
let currentWarningKind = null;

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
  // Let the browser paste naturally. Once the paste completes,
  // the "input" event is automatically triggered and will call onInput()
  notifyActivity(true);
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
      removePiiWarningBar();
      highlightEditor(editor, false);
      piiWarningActive = false;
      activeRedactedText = "";
      return;
    }

    const response = await scanText(prompt, "debounce");
    if (scheduledSequence !== inputSequence) {
      return;
    }

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

  // If a PII warning is active, block submit and flash the warning bar!
  if (piiWarningActive) {
    flashWarningBar();
    return;
  }

  submitInFlight = true;
  inputSequence += 1;
  window.clearTimeout(inputTimer);
  notifyActivity(true);

  try {
    const response = await scanText(prompt, "submit");

    if (response.action !== "allow") {
      enforceDebouncedDecision(editor, prompt, response);
      if (piiWarningActive || currentWarningKind) {
        flashWarningBar();
      }
      return;
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
  if (button.id === "ai-guard-auto-anonymize") {
    return false;
  }

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

// Editor text reading and replacing Helpers
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
  const decisionKind = decisionKindFor(response);
  if (decisionKind === "clean") {
    removePiiWarningBar();
    highlightEditor(editor, false);
    piiWarningActive = false;
    activeRedactedText = "";
    return;
  }

  const liveText = readEditorText(editor);
  const normalizedLiveText = normalizePromptText(liveText);
  const normalizedScannedText = normalizePromptText(scannedText);
  if (!normalizedLiveText || normalizedLiveText !== normalizedScannedText) {
    return;
  }

  if (decisionKind === "scan_error") {
    piiWarningActive = false;
    activeRedactedText = "";
    highlightEditor(editor, false);
    showPiiWarningBar(
      editor,
      response.reason || "PII scanning is temporarily unavailable.",
      null,
      "system",
    );
    return;
  }

  if (response.action === "allow") {
    piiWarningActive = false;
    activeRedactedText = "";
    highlightEditor(editor, false);
    showPiiWarningBar(
      editor,
      `Sensitive information detected: ${response.detected_entity || "PII"}`,
      null,
      "notice",
    );
    return;
  }

  piiWarningActive = true;
  activeRedactedText = shouldOfferAutoAnonymize(response, scannedText)
    ? response.redacted_text
    : "";

  highlightEditor(editor, true);
  showPiiWarningBar(
    editor,
    `Sensitive information detected: ${response.detected_entity || "PII"}`,
    activeRedactedText
      ? () => {
          replaceEditorText(editor, activeRedactedText);
          removePiiWarningBar();
          highlightEditor(editor, false);
          piiWarningActive = false;
          activeRedactedText = "";
        }
      : null,
    "pii",
  );
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
  editor.focus();
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(editor);
  selection.removeAllRanges();
  selection.addRange(range);

  const inserted = document.execCommand("insertText", false, value);
  if (inserted) {
    return;
  }

  // Fallback if execCommand fails
  range.deleteContents();
  const node = document.createTextNode(value);
  range.insertNode(node);
  range.setStartAfter(node);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
}

async function scanText(text, reason) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(
      {
        type: "scan",
        text,
        reason,
      },
      (response) => {
        if (chrome.runtime.lastError) {
          resolve(createScanErrorResponse(`Ulti Guard is unavailable: ${chrome.runtime.lastError.message}`));
          return;
        }

        if (!response || !response.action) {
          resolve(createScanErrorResponse("Ulti Guard returned an empty scan response."));
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
    banner.style.boxShadow = "0 12px 30px rgba(0, 0, 0, 0.25)";
    banner.style.font = "600 13px/1.4 system-ui, sans-serif";
    banner.style.opacity = "0";
    banner.style.transform = "translateY(-20px)";
    banner.style.transition = "opacity 0.4s cubic-bezier(0.16, 1, 0.3, 1), transform 0.4s cubic-bezier(0.16, 1, 0.3, 1)";
    document.body.appendChild(banner);
  }

  banner.textContent = `Ulti Guard: ${message}`;
  
  // Force reflow
  banner.offsetHeight;

  banner.style.opacity = "1";
  banner.style.transform = "translateY(0)";
  
  window.clearTimeout(showWarning.timerId);
  showWarning.timerId = window.setTimeout(() => {
    const target = document.getElementById(WARNING_ID);
    if (target) {
      target.style.opacity = "0";
      target.style.transform = "translateY(-20px)";
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

// PII Warning UI Helpers mirror the flow, behavior and premium look of Ultimize
function createScanErrorResponse(message) {
  return {
    action: "block",
    decision_kind: "scan_error",
    redacted_text: "",
    reason: message,
    detected_entity: null,
  };
}

function shouldOfferAutoAnonymize(response, scannedText) {
  if (decisionKindFor(response) !== "pii_detected" || response.action !== "redact") {
    return false;
  }

  const replacement = normalizePromptText(response.redacted_text || "");
  return !!replacement && replacement !== normalizePromptText(scannedText);
}

function decisionKindFor(response) {
  if (response?.decision_kind) {
    return response.decision_kind;
  }

  if (response?.action === "allow" && !response?.detected_entity) {
    return "clean";
  }

  return "pii_detected";
}

function createPiiWarningBar(message, onAnonymize, kind = "pii") {
  let bar = document.getElementById(PII_WARNING_BAR_ID);
  if (bar) {
    bar.remove();
  }

  bar = document.createElement("div");
  bar.id = PII_WARNING_BAR_ID;
  bar.style.display = "flex";
  bar.style.alignItems = "center";
  bar.style.justifyContent = "space-between";
  bar.style.background = "#fff5f5";
  bar.style.border = "1px solid #feb2b2";
  bar.style.borderRadius = "8px";
  bar.style.padding = "8px 14px";
  bar.style.marginTop = "8px";
  bar.style.marginBottom = "8px";
  bar.style.fontFamily = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
  bar.style.boxSizing = "border-box";
  bar.style.width = "100%";
  bar.style.transition = "all 0.3s ease";

  const palette =
    kind === "pii"
      ? {
          background: "#fff5f5",
          border: "#feb2b2",
          text: "#c53030",
          icon: "#e53e3e",
          darkBackground: "#2d1a1a",
          darkBorder: "#742a2a",
          darkText: "#feb2b2",
        }
      : {
          background: "#fffaf0",
          border: "#f6ad55",
          text: "#9c4221",
          icon: "#dd6b20",
          darkBackground: "#2b2114",
          darkBorder: "#9c4221",
          darkText: "#fbd38d",
        };

  bar.style.background = palette.background;
  bar.style.border = `1px solid ${palette.border}`;

  // Check if dark mode is active to adjust colors
  const isDarkMode = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  if (isDarkMode) {
    bar.style.background = palette.darkBackground;
    bar.style.border = `1px solid ${palette.darkBorder}`;
  }

  // Left Content (Icon + Warning message)
  const leftContainer = document.createElement("div");
  leftContainer.style.display = "flex";
  leftContainer.style.alignItems = "center";
  leftContainer.style.gap = "8px";

  // Warning/Alert Icon SVG
  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("width", "16");
  icon.setAttribute("height", "16");
  icon.setAttribute("viewBox", "0 0 24 24");
  icon.setAttribute("fill", "none");
  icon.setAttribute("stroke", palette.icon);
  icon.setAttribute("stroke-width", "2");
  icon.setAttribute("stroke-linecap", "round");
  icon.setAttribute("stroke-linejoin", "round");
  
  const path1 = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path1.setAttribute("d", "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z");
  const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
  line.setAttribute("x1", "12");
  line.setAttribute("y1", "9");
  line.setAttribute("x2", "12");
  line.setAttribute("y2", "13");
  const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
  circle.setAttribute("cx", "12");
  circle.setAttribute("cy", "17");
  circle.setAttribute("r", "0.5");
  circle.setAttribute("fill", palette.icon);

  icon.appendChild(path1);
  icon.appendChild(line);
  icon.appendChild(circle);

  const textLabel = document.createElement("span");
  textLabel.textContent = message;
  textLabel.style.color = palette.text;
  textLabel.style.fontSize = "13px";
  textLabel.style.fontWeight = "500";
  if (isDarkMode) {
    textLabel.style.color = palette.darkText;
  }

  leftContainer.appendChild(icon);
  leftContainer.appendChild(textLabel);

  bar.appendChild(leftContainer);

  // Right Content (Auto-Anonymize button) - Only create/append if onAnonymize callback is provided
  if (onAnonymize) {
    const anonymizeBtn = document.createElement("button");
    anonymizeBtn.id = "ai-guard-auto-anonymize";
    anonymizeBtn.type = "button";
    anonymizeBtn.textContent = "Auto-Anonymize";
    anonymizeBtn.style.background = "#f1f5f9";
    anonymizeBtn.style.color = "#334155";
    anonymizeBtn.style.border = "1px solid #cbd5e1";
    anonymizeBtn.style.borderRadius = "6px";
    anonymizeBtn.style.padding = "6px 12px";
    anonymizeBtn.style.fontSize = "12px";
    anonymizeBtn.style.fontWeight = "600";
    anonymizeBtn.style.cursor = "pointer";
    anonymizeBtn.style.transition = "all 0.2s ease";

    anonymizeBtn.addEventListener("mouseover", () => {
      anonymizeBtn.style.background = "#cbd5e1";
    });
    anonymizeBtn.addEventListener("mouseout", () => {
      anonymizeBtn.style.background = "#f1f5f9";
    });

    anonymizeBtn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      onAnonymize();
    });

    bar.appendChild(anonymizeBtn);
  }

  return bar;
}

function showPiiWarningBar(editor, message, onAnonymize, kind = "pii") {
  let bar = document.getElementById(PII_WARNING_BAR_ID);
  if (bar) {
    bar.remove();
  }

  bar = createPiiWarningBar(message, onAnonymize, kind);
  currentWarningKind = kind;

  // Insert below the outer container that holds the Claude editor text input area
  const insertionPoint = editor.closest('.flex.flex-col') || editor;
  if (insertionPoint && insertionPoint.parentNode) {
    insertionPoint.parentNode.insertBefore(bar, insertionPoint.nextSibling);
  }
}

function removePiiWarningBar() {
  const bar = document.getElementById(PII_WARNING_BAR_ID);
  if (bar) {
    bar.remove();
  }
  currentWarningKind = null;
}

function highlightEditor(editor, highlight) {
  if (!editor) return;

  const borderContainer = editor.closest('.flex.flex-col') || editor;

  if (highlight) {
    if (!borderContainer.dataset.hasOriginalStyles) {
      borderContainer.dataset.originalBorder = borderContainer.style.border || "";
      borderContainer.dataset.originalBoxShadow = borderContainer.style.boxShadow || "";
      borderContainer.dataset.originalBorderColor = borderContainer.style.borderColor || "";
      borderContainer.dataset.hasOriginalStyles = "true";
    }

    borderContainer.style.borderColor = "#e53e3e";
    borderContainer.style.boxShadow = "0 0 0 2px rgba(229, 62, 62, 0.25)";
  } else {
    if (borderContainer.dataset.hasOriginalStyles === "true") {
      borderContainer.style.border = borderContainer.dataset.originalBorder;
      borderContainer.style.boxShadow = borderContainer.dataset.originalBoxShadow;
      borderContainer.style.borderColor = borderContainer.dataset.originalBorderColor;
    }
  }
}

function flashWarningBar() {
  const bar = document.getElementById(PII_WARNING_BAR_ID);
  if (!bar) return;

  bar.style.transform = "translateX(10px)";
  setTimeout(() => { bar.style.transform = "translateX(-10px)"; }, 80);
  setTimeout(() => { bar.style.transform = "translateX(5px)"; }, 160);
  setTimeout(() => { bar.style.transform = "translateX(-5px)"; }, 240);
  setTimeout(() => { bar.style.transform = "translateX(0)"; }, 320);

  const editor = findPrimaryEditor();
  if (editor && currentWarningKind === "pii" && piiWarningActive) {
    const borderContainer = editor.closest('.flex.flex-col') || editor;
    borderContainer.style.boxShadow = "0 0 0 4px rgba(229, 62, 62, 0.4)";
    setTimeout(() => {
      if (piiWarningActive) {
        borderContainer.style.boxShadow = "0 0 0 2px rgba(229, 62, 62, 0.25)";
      } else {
        borderContainer.style.boxShadow = "";
      }
    }, 500);
  }
}
