import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import puppeteer from 'puppeteer-core';

const EDITOR_SELECTOR = '[data-testid="mock-editor"]';
const WARNING_BAR_SELECTOR = '#ai-guard-pii-warning-bar';
const SEND_BUTTON_SELECTOR = 'button[aria-label="Send"]';
const SUBMITTED_OUTPUT_SELECTOR = '#submitted-output';

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

async function clearPrompt(page, selector) {
  await page.waitForSelector(selector, { timeout: 15000 });
  await page.focus(selector);
  await page.keyboard.down('Control');
  await page.keyboard.press('A');
  await page.keyboard.up('Control');
  await page.keyboard.press('Backspace');
  await page.waitForFunction(
    (targetSelector) => {
      const editor = document.querySelector(targetSelector);
      const text = editor ? editor.innerText || editor.textContent || '' : '';
      return text.trim().length === 0;
    },
    { timeout: 10000 },
    selector,
  );
}

async function readEditorText(page, selector) {
  return page.evaluate((targetSelector) => {
    const editor = document.querySelector(targetSelector);
    return editor ? editor.innerText || editor.textContent || '' : '';
  }, selector);
}

async function warningSnapshot(page) {
  return page.evaluate((warningSelector, editorSelector) => {
    const warning = document.querySelector(warningSelector);
    const button = warning
      ? Array.from(warning.querySelectorAll('button')).find(
          (item) => item.textContent?.trim() === 'Auto-Anonymize',
        )
      : null;
    const editor = document.querySelector(editorSelector);
    return {
      warningText: warning ? warning.textContent || '' : null,
      hasAutoAnonymize: Boolean(button),
      editorText: editor ? editor.innerText || editor.textContent || '' : null,
      pageUrl: window.location.href,
    };
  }, WARNING_BAR_SELECTOR, EDITOR_SELECTOR);
}

async function waitForWarningBar(page, predicate, timeoutMs = 15000) {
  try {
    await page.waitForFunction(
      (warningSelector, expectedSource) => {
        const warning = document.querySelector(warningSelector);
        const text = warning ? warning.textContent || '' : '';
        if (!text.trim()) {
          return false;
        }

        if (expectedSource.type === 'includes') {
          return text.includes(expectedSource.value);
        }

        return new RegExp(expectedSource.value, expectedSource.flags).test(text);
      },
      { timeout: timeoutMs },
      WARNING_BAR_SELECTOR,
      predicate,
    );
  } catch (error) {
    const diagnostics = await warningSnapshot(page);
    throw new Error(
      `Expected warning bar did not appear. page=${diagnostics.pageUrl} warning=${JSON.stringify(diagnostics.warningText)} editor=${JSON.stringify(diagnostics.editorText)} cause=${error.message}`,
    );
  }
}

async function expectNoWarningBar(page, timeoutMs = 2000) {
  await new Promise((resolve) => setTimeout(resolve, timeoutMs));
  const diagnostics = await warningSnapshot(page);
  if (diagnostics.warningText?.trim()) {
    throw new Error(
      `Expected no warning bar but found ${JSON.stringify(diagnostics.warningText)} on ${diagnostics.pageUrl}`,
    );
  }
}

async function clickAutoAnonymize(page) {
  try {
    await page.waitForSelector('#ai-guard-auto-anonymize', { timeout: 15000 });
    await page.click('#ai-guard-auto-anonymize');
  } catch (error) {
    const diagnostics = await warningSnapshot(page);
    throw new Error(
      `Auto-Anonymize button was not available. warning=${JSON.stringify(diagnostics.warningText)} cause=${error.message}`,
    );
  }
}

async function waitForEditorText(page, predicate, timeoutMs = 15000) {
  await page.waitForFunction(
    (selector, expectedSource) => {
      const editor = document.querySelector(selector);
      const text = editor ? editor.innerText || editor.textContent || '' : '';
      if (expectedSource.type === 'includes') {
        return text.includes(expectedSource.value);
      }

      return new RegExp(expectedSource.value, expectedSource.flags).test(text);
    },
    { timeout: timeoutMs },
    EDITOR_SELECTOR,
    predicate,
  );
}

async function submitAndWaitForText(page, predicate, timeoutMs = 15000) {
  await page.click(SEND_BUTTON_SELECTOR);
  await page.waitForFunction(
    (selector, expectedSource) => {
      const output = document.querySelector(selector);
      const text = output ? output.textContent || '' : '';
      if (expectedSource.type === 'equals') {
        return text === expectedSource.value;
      }
      if (expectedSource.type === 'includes') {
        return text.includes(expectedSource.value);
      }

      return new RegExp(expectedSource.value, expectedSource.flags).test(text);
    },
    { timeout: timeoutMs },
    SUBMITTED_OUTPUT_SELECTOR,
    predicate,
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

function loadDefaultBlockedHosts() {
  const defaultsPath = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    '..',
    '..',
    'shared',
    'default-blocking.json',
  );

  const defaults = JSON.parse(fs.readFileSync(defaultsPath, 'utf8'));
  return Array.isArray(defaults.browser_hosts) ? defaults.browser_hosts : [];
}

function copyDirectoryRecursive(sourceDir, destinationDir) {
  fs.mkdirSync(destinationDir, { recursive: true });
  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const destinationPath = path.join(destinationDir, entry.name);
    if (entry.isDirectory()) {
      copyDirectoryRecursive(sourcePath, destinationPath);
      continue;
    }

    fs.copyFileSync(sourcePath, destinationPath);
  }
}

function prepareTestExtension(sourceDir, fixtureOrigin) {
  const patchedDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-guard-browser-extension-'));
  copyDirectoryRecursive(sourceDir, patchedDir);

  const manifestPath = path.join(patchedDir, 'manifest.json');
  const serviceWorkerPath = path.join(patchedDir, 'service-worker.js');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  manifest.host_permissions = Array.from(new Set([
    ...(manifest.host_permissions || []),
    `${fixtureOrigin}/*`,
  ]));
  if (Array.isArray(manifest.content_scripts)) {
    for (const contentScript of manifest.content_scripts) {
      contentScript.matches = Array.from(new Set([
        ...(contentScript.matches || []),
        `${fixtureOrigin}/*`,
      ]));
    }
  }
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  const workerSource = fs.readFileSync(serviceWorkerPath, 'utf8');
  const fixtureHost = new URL(fixtureOrigin).hostname;
  const patchedWorker = workerSource.replace(
    'const CLAUDE_HOSTS = ["claude.ai", "claude.com"];',
    `const CLAUDE_HOSTS = ["claude.ai", "claude.com", "${fixtureHost}"];`,
  );
  fs.writeFileSync(serviceWorkerPath, patchedWorker);

  return patchedDir;
}

function startFixtureServer(port) {
  const fixturePath = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    'fixtures',
    'mock-claude.html',
  );
  const html = fs.readFileSync(fixturePath, 'utf8');

  return new Promise((resolve, reject) => {
    const server = http.createServer((request, response) => {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end(html);
    });
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

function requestStatus(urlString) {
  const url = new URL(urlString);
  const client = url.protocol === 'https:' ? https : http;

  return new Promise((resolve, reject) => {
    const request = client.request(
      url,
      { method: 'GET' },
      (response) => {
        response.resume();
        response.on('end', () => resolve(response.statusCode || 0));
      },
    );

    request.on('error', reject);
    request.setTimeout(5000, () => request.destroy(new Error(`Timed out requesting ${urlString}`)));
    request.end();
  });
}

async function waitForDaemonReady(daemonBaseUrl, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const statusCode = await requestStatus(`${daemonBaseUrl}/readyz`);
      if (statusCode >= 200 && statusCode < 300) {
        return;
      }
    } catch {
    }

    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  throw new Error(`Timed out waiting for ${daemonBaseUrl}/readyz`);
}

async function openFixturePage(browser, baseUrl) {
  const page = await browser.newPage();
  await page.goto(baseUrl, {
    waitUntil: 'networkidle2',
    timeout: 45000,
  });
  return page;
}

async function runWarmupRecoveryScenario(browser, baseUrl, daemonBaseUrl) {
  const page = await openFixturePage(browser, baseUrl);
  try {
    await typePrompt(page, EDITOR_SELECTOR, 'Hi');
    await waitForWarningBar(
      page,
      { type: 'regex', value: 'temporarily unavailable|still starting up', flags: 'i' },
      20000,
    );

    const diagnostics = await warningSnapshot(page);
    if (diagnostics.hasAutoAnonymize) {
      throw new Error('Auto-Anonymize should not appear for scan-error warnings.');
    }

    await waitForDaemonReady(daemonBaseUrl, 180000);

    await clearPrompt(page, EDITOR_SELECTOR);
    await typePrompt(page, EDITOR_SELECTOR, 'Hi');
    await expectNoWarningBar(page, 1500);
    await submitAndWaitForText(page, { type: 'equals', value: 'Hi' });

    await page.reload({ waitUntil: 'networkidle2', timeout: 45000 });
    await typePrompt(page, EDITOR_SELECTOR, 'Hi');
    await expectNoWarningBar(page, 1500);
    await submitAndWaitForText(page, { type: 'equals', value: 'Hi' });
  } finally {
    await page.close();
  }
}

async function runRedactScenario(browser, baseUrl, extensionId, blockedHosts) {
  await assertBlockedNavigation(
    browser.defaultBrowserContext(),
    `https://${blockedHosts[0]}/`,
    extensionId,
  );

  const page = await openFixturePage(browser, baseUrl);
  try {
    await typePrompt(page, EDITOR_SELECTOR, 'contact me at test@example.com');
    await waitForWarningBar(page, {
      type: 'includes',
      value: 'Sensitive information detected',
    });

    const diagnostics = await warningSnapshot(page);
    if (!diagnostics.hasAutoAnonymize) {
      throw new Error(`Expected Auto-Anonymize to be available for redact mode, warning=${JSON.stringify(diagnostics.warningText)}`);
    }

    await page.click(SEND_BUTTON_SELECTOR);
    await new Promise((resolve) => setTimeout(resolve, 1000));
    const submittedText = await page.$eval(
      SUBMITTED_OUTPUT_SELECTOR,
      (element) => element.textContent || '',
    );
    if (submittedText.trim()) {
      throw new Error(`Sensitive prompt should not have been submitted in redact mode: ${JSON.stringify(submittedText)}`);
    }

    await assertBlockedNavigation(
      browser.defaultBrowserContext(),
      `https://${blockedHosts[blockedHosts.length - 1]}/`,
      extensionId,
    );
  } finally {
    await page.close();
  }
}

async function runMaskScenario(browser, baseUrl) {
  const page = await openFixturePage(browser, baseUrl);
  const originalPrompt = 'My bank account number is 323480298721';
  try {
    await typePrompt(page, EDITOR_SELECTOR, originalPrompt);
    await waitForWarningBar(page, {
      type: 'includes',
      value: 'Sensitive information detected',
    });
    await clickAutoAnonymize(page);
    try {
      await page.waitForFunction(
        (selector, originalText) => {
          const editor = document.querySelector(selector);
          const text = editor ? editor.innerText || editor.textContent || '' : '';
          return text.includes('*') && !text.includes('323480298721') && text !== originalText;
        },
        { timeout: 15000 },
        EDITOR_SELECTOR,
        originalPrompt,
      );
    } catch (error) {
      const diagnostics = await warningSnapshot(page);
      throw new Error(
        `Mask mode did not update the editor. warning=${JSON.stringify(diagnostics.warningText)} editor=${JSON.stringify(diagnostics.editorText)} auto=${diagnostics.hasAutoAnonymize} cause=${error.message}`,
      );
    }

    const maskedText = await readEditorText(page, EDITOR_SELECTOR);
    if (!maskedText.includes('*') || maskedText.includes('323480298721')) {
      throw new Error(`Mask mode did not replace the sensitive number: ${JSON.stringify(maskedText)}`);
    }

    await submitAndWaitForText(page, { type: 'equals', value: maskedText });
  } finally {
    await page.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const browserPath = requireArg(args, 'browser-path');
  const extensionDir = requireArg(args, 'extension-dir');
  const extensionId = requireArg(args, 'extension-id');
  const daemonBaseUrl = requireArg(args, 'daemon-base-url');
  const scenario = requireArg(args, 'scenario');
  const blockedHosts = loadDefaultBlockedHosts();
  if (blockedHosts.length === 0) {
    throw new Error('No default blocked hosts were loaded for the browser smoke test.');
  }

  const fixturePort = Number(args['fixture-port'] || 49080);
  const fixtureOrigin = `http://127.0.0.1:${fixturePort}`;
  const baseUrl = `${fixtureOrigin}/mock-claude`;
  const profileDir =
    args['profile-dir'] ||
    fs.mkdtempSync(path.join(os.tmpdir(), 'ai-guard-browser-smoke-'));
  const patchedExtensionDir = prepareTestExtension(extensionDir, fixtureOrigin);
  const fixtureServer = await startFixtureServer(fixturePort);

  try {
    const browser = await puppeteer.launch({
      executablePath: browserPath,
      headless: false,
      defaultViewport: { width: 1440, height: 960 },
      args: [
        `--user-data-dir=${profileDir}`,
        `--disable-extensions-except=${patchedExtensionDir}`,
        `--load-extension=${patchedExtensionDir}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-sync',
        '--disable-background-networking',
        '--new-window',
      ],
    });

    try {
      await waitForExtensionServiceWorker(browser, extensionId, 20000);

      if (scenario === 'warmup-recovery') {
        await runWarmupRecoveryScenario(browser, baseUrl, daemonBaseUrl);
      } else if (scenario === 'redact') {
        await runRedactScenario(browser, baseUrl, extensionId, blockedHosts);
      } else if (scenario === 'mask') {
        await runMaskScenario(browser, baseUrl);
      } else {
        throw new Error(`Unknown smoke-test scenario: ${scenario}`);
      }

      console.log(`Ulti Guard browser smoke test passed for scenario: ${scenario}`);
    } finally {
      await browser.close();
    }
  } finally {
    fixtureServer.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
