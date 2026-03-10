#!/usr/bin/env node
/**
 * sipgate Channel Watcher
 *
 * Connects to the sipgate Electron app via Chrome Remote Debugging Protocol
 * and enforces that "Hotline" is always the active channel.
 *
 * Usage:
 *   1. Start sipgate with debug port:
 *      open -a "sipgate" --args --remote-debugging-port=9222
 *   2. Run this watcher:
 *      node watcher.js
 */

const CDP = require('chrome-remote-interface');

const DEBUG_PORT = 9222;
const RETRY_INTERVAL_MS = 5000;   // How often to retry connecting if sipgate isn't ready
const POLL_INTERVAL_MS = 1000;    // Fallback poll interval inside the page

// This script is injected into the sipgate renderer process.
// It sets up a MutationObserver to immediately react to channel changes,
// with a periodic poll as a safety net.
//
// Confirmed selectors from DOM inspection (poc.js):
//   Button:      [aria-label="Hotline"]   (BUTTON element, role="link")
//   Active class: className contains "_active_"
const INJECTED_WATCHER_SCRIPT = `
(function() {
  if (window.__hotlineWatcherActive) return 'already_running';

  window.__hotlineWatcherActive = true;

  function enforceHotline() {
    // document.title is the most robust indicator: "Hotline - sipgate App"
    // It's a semantic property, unaffected by CSS refactoring or build hashes.
    if (document.title.startsWith('Hotline')) return;

    const hotline = document.querySelector('[aria-label="Hotline"]');
    if (!hotline) return; // App not fully loaded yet

    console.log('[Hotline-Watcher] Switching to Hotline (was: ' + document.title + ')');
    hotline.click();
  }

  // Initial enforcement
  enforceHotline();

  // MutationObserver: reacts immediately when the active class changes on any channel button
  const observer = new MutationObserver(enforceHotline);

  observer.observe(document.body, {
    subtree: true,
    attributes: true,
    attributeFilter: ['class']
  });

  // Periodic poll as safety net (every ${POLL_INTERVAL_MS}ms)
  setInterval(enforceHotline, ${POLL_INTERVAL_MS});

  console.log('[Hotline-Watcher] Active.');
  return 'ok';
})();
`;

let isConnected = false;

async function getSipgateTarget(retries = 0) {
  const http = require('http');
  return new Promise((resolve, reject) => {
    const req = http.get(`http://localhost:${DEBUG_PORT}/json`, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const targets = JSON.parse(data);
          // We want the main renderer window, not devtools or background pages
          const target = targets.find(t =>
            t.type === 'page' &&
            !t.url.startsWith('devtools://') &&
            !t.url.includes('background')
          );
          if (target) resolve(target);
          else reject(new Error('No suitable page target found'));
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(3000, () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

async function connectAndWatch() {
  let target;
  try {
    target = await getSipgateTarget();
  } catch (err) {
    if (!isConnected) {
      process.stdout.write('.');  // Show waiting indicator
    }
    setTimeout(connectAndWatch, RETRY_INTERVAL_MS);
    return;
  }

  if (!isConnected) {
    console.log(`\n[Hotline-Watcher] Connected to sipgate (${target.title || target.url})`);
    isConnected = true;
  }

  let client;
  try {
    client = await CDP({ port: DEBUG_PORT, target: target.id });
    const { Runtime } = client;
    await Runtime.enable();

    console.log('[Hotline-Watcher] Injecting channel enforcement script...');
    const result = await Runtime.evaluate({
      expression: INJECTED_WATCHER_SCRIPT,
      returnByValue: true,
    });

    const value = result?.result?.value;
    if (value === 'already_running') {
      console.log('[Hotline-Watcher] Script already running in this session.');
    } else if (value === 'ok') {
      console.log('[Hotline-Watcher] Script injected successfully. Monitoring...');
    } else {
      console.log('[Hotline-Watcher] Script result:', value);
    }

    // Listen for page navigations/reloads to re-inject
    const { Page } = client;
    await Page.enable();
    Page.loadEventFired(async () => {
      console.log('[Hotline-Watcher] Page reloaded, re-injecting...');
      await Runtime.evaluate({ expression: INJECTED_WATCHER_SCRIPT, returnByValue: true });
    });

    // Handle disconnect
    client.on('disconnect', () => {
      console.log('[Hotline-Watcher] Disconnected. Retrying...');
      isConnected = false;
      setTimeout(connectAndWatch, RETRY_INTERVAL_MS);
    });

  } catch (err) {
    console.error('[Hotline-Watcher] CDP error:', err.message);
    if (client) await client.close().catch(() => {});
    isConnected = false;
    setTimeout(connectAndWatch, RETRY_INTERVAL_MS);
  }
}

console.log(`[Hotline-Watcher] Starting... Waiting for sipgate on port ${DEBUG_PORT}`);
console.log('[Hotline-Watcher] Make sure sipgate was launched with --remote-debugging-port=9222');
console.log('[Hotline-Watcher] (see start.sh for automatic launch)');
console.log('');
connectAndWatch();
