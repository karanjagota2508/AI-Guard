import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

import puppeteer from 'puppeteer-core';

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (!current.startsWith('--')) {
      continue;
    }

    const key = current.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith('--')) {
      parsed[key] = true;
      continue;
    }

    parsed[key] = next;
    index += 1;
  }

  return parsed;
}

function requireArg(args, name) {
  const value = args[name];
  if (!value || value === true) {
    throw new Error(`Missing required argument --${name}`);
  }
  return value;
}

async function waitForExtensionServiceWorker(browser, extensionId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const workerTarget = browser
      .targets()
      .find(
        (target) =>
          target.type() === 'service_worker' &&
          target.url().startsWith(`chrome-extension://${extensionId}/`),
      );

    if (workerTarget) {
      return workerTarget;
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(
    `Timed out waiting for extension service worker ${extensionId}`,
  );
}

async function typePrompt(page, selector, value) {
  await page.waitForSelector(selector, { timeout: 15000 });
  await page.focus(selector);
  await page.keyboard.type(value);
}

async function assertRedaction(page, editorSelector, warningSelector) {
  try {
    await page.waitForFunction(
      (selector) => {
        const editor = document.querySelector(selector);
        if (!editor) {
          return false;
        }
        const text = editor.innerText || editor.textContent || '';
        return text.includes('<REDACTED>');
      },
      { timeout: 15000 },
      editorSelector,
    );

    await page.waitForFunction(
      (selector) => {
        const banner = document.querySelector(selector);
        return Boolean(banner && banner.textContent && banner.textContent.trim());
      },
      { timeout: 15000 },
      warningSelector,
    );
  } catch (error) {
    const diagnostics = await page.evaluate((editorSel, warningSel) => {
      const editor = document.querySelector(editorSel);
      const banner = document.querySelector(warningSel);
      return {
        editorText: editor ? editor.innerText || editor.textContent || '' : null,
        warningText: banner ? banner.textContent || '' : null,
        pageUrl: window.location.href,
      };
    }, editorSelector, warningSelector);

    throw new Error(
      `Redaction did not occur. URL=${diagnostics.pageUrl} editor=${JSON.stringify(diagnostics.editorText)} warning=${JSON.stringify(diagnostics.warningText)} cause=${error.message}`,
    );
  }
}

async function assertSubmittedRedaction(page) {
  await page.click('button[aria-label="Send"]');
  await page.waitForFunction(
    () => {
      const output = document.querySelector('#submitted-output');
      return Boolean(
        output && output.textContent && output.textContent.includes('<REDACTED>'),
      );
    },
    { timeout: 15000 },
  );
}

async function assertBlockedNavigation(browserContext, targetUrl, extensionId) {
  const page = await browserContext.newPage();
  await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForFunction(
    (id) => window.location.href.startsWith(`chrome-extension://${id}/blocked.html`),
    { timeout: 20000 },
    extensionId,
  );
  await page.close();
}

async function runNormalModeChecks(browser, baseUrl, extensionId) {
  const page = await browser.newPage();
  await page.goto(`${baseUrl}/__ulti_guard_test__/mock-claude`, {
    waitUntil: 'networkidle2',
    timeout: 45000,
  });

  const editorSelector = '[data-testid="mock-editor"]';
  const warningSelector = '#ai-guard-warning';
  await typePrompt(page, editorSelector, 'contact me at test@example.com');
  await assertRedaction(page, editorSelector, warningSelector);
  await assertSubmittedRedaction(page);
  await assertBlockedNavigation(browser.defaultBrowserContext(), 'https://chatgpt.com/', extensionId);
  await page.close();
}

async function runIncognitoChecks(browser, baseUrl, extensionId) {
  const incognitoContext = await browser.createBrowserContext();
  const page = await incognitoContext.newPage();
  await page.goto(`${baseUrl}/__ulti_guard_test__/mock-claude`, {
    waitUntil: 'networkidle2',
    timeout: 45000,
  });

  const editorSelector = '[data-testid="mock-editor"]';
  const warningSelector = '#ai-guard-warning';
  await typePrompt(page, editorSelector, 'backup email hidden@example.com');
  await assertRedaction(page, editorSelector, warningSelector);
  await assertBlockedNavigation(incognitoContext, 'https://chatgpt.com/', extensionId);
  await incognitoContext.close();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const browserPath = requireArg(args, 'browser-path');
  const extensionDir = requireArg(args, 'extension-dir');
  const extensionId = requireArg(args, 'extension-id');
  const baseUrl = requireArg(args, 'base-url');
  const profileDir =
    args['profile-dir'] ||
    fs.mkdtempSync(path.join(os.tmpdir(), 'ulti-guard-browser-smoke-'));

  const browser = await puppeteer.launch({
    executablePath: browserPath,
    headless: false,
    defaultViewport: { width: 1440, height: 960 },
    args: [
      `--user-data-dir=${profileDir}`,
      `--disable-extensions-except=${extensionDir}`,
      `--load-extension=${extensionDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-sync',
      '--disable-background-networking',
      '--new-window',
    ],
  });

  try {
    await waitForExtensionServiceWorker(browser, extensionId, 20000);
    await runNormalModeChecks(browser, baseUrl, extensionId);
    await runIncognitoChecks(browser, baseUrl, extensionId);
    console.log('Ulti Guard browser smoke test passed.');
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
