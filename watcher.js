#!/usr/bin/env node
/**
 * sipgate Channel Watcher
 *
 * Connects to the sipgate Electron app via Chrome Remote Debugging Protocol
 * and enforces that "Hotline" is always the active channel.
 *
 * If sipgate is running WITHOUT the debug port (e.g. started via Dock),
 * it will automatically restart it with --remote-debugging-port=9222.
 */

const CDP = require('chrome-remote-interface');
const { execSync, exec } = require('child_process');

const DEBUG_PORT = 9222;
const RETRY_INTERVAL_MS = 5000;
const POLL_INTERVAL_MS = 1000;

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

  enforceHotline();

  // React immediately to DOM changes
  const observer = new MutationObserver(enforceHotline);
  observer.observe(document.body, {
    subtree: true,
    attributes: true,
    attributeFilter: ['class']
  });

  // Poll every 1s as safety net
  setInterval(enforceHotline, ${POLL_INTERVAL_MS});

  console.log('[Hotline-Watcher] Active.');
  return 'ok';
})();
`;

// ── Helpers ───────────────────────────────────────────────────────────────────

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function isSipgateRunning() {
  try {
    execSync('pgrep -x sipgate', { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function restartSipgateWithDebugPort() {
  console.log('[Hotline-Watcher] sipgate läuft ohne Debug-Port — starte neu...');
  try { execSync('pkill -x sipgate', { stdio: 'ignore' }); } catch {}
}

async function getSipgateTarget() {
  const http = require('http');
  return new Promise((resolve, reject) => {
    const req = http.get(`http://localhost:${DEBUG_PORT}/json`, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const targets = JSON.parse(data);
          const target = targets.find(t =>
            t.type === 'page' &&
            !t.url.startsWith('devtools://')
          );
          if (target) resolve(target);
          else reject(new Error('No page target found'));
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.setTimeout(3000, () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

// ── Main loop ─────────────────────────────────────────────────────────────────

let isConnected = false;
let restarting = false;

async function connectAndWatch() {
  let target;
  try {
    target = await getSipgateTarget();
  } catch {
    // Port 9222 not reachable — check if sipgate is running WITHOUT debug port
    if (!restarting && isSipgateRunning()) {
      restarting = true;
      restartSipgateWithDebugPort();
      await sleep(2000);
      exec('open -a sipgate --args --remote-debugging-port=9222');
      console.log('[Hotline-Watcher] sipgate neu gestartet mit Debug-Port. Warte...');
      await sleep(5000);
      restarting = false;
    } else if (!isConnected && !restarting) {
      process.stdout.write('.');
    }
    setTimeout(connectAndWatch, RETRY_INTERVAL_MS);
    return;
  }

  if (!isConnected) {
    console.log(`\n[Hotline-Watcher] Verbunden (${target.title || target.url})`);
    isConnected = true;
  }

  let client;
  try {
    client = await CDP({ port: DEBUG_PORT, target: target.id });
    const { Runtime, Page } = client;
    await Runtime.enable();
    await Page.enable();

    const result = await Runtime.evaluate({
      expression: INJECTED_WATCHER_SCRIPT,
      returnByValue: true,
    });

    const val = result?.result?.value;
    if (val === 'already_running') {
      console.log('[Hotline-Watcher] Skript läuft bereits.');
    } else {
      console.log('[Hotline-Watcher] Monitoring aktiv.');
    }

    Page.loadEventFired(async () => {
      console.log('[Hotline-Watcher] Seite neu geladen — re-inject...');
      await Runtime.evaluate({ expression: INJECTED_WATCHER_SCRIPT, returnByValue: true });
    });

    client.on('disconnect', () => {
      console.log('[Hotline-Watcher] Verbindung getrennt. Erneut versuchen...');
      isConnected = false;
      setTimeout(connectAndWatch, RETRY_INTERVAL_MS);
    });

  } catch (err) {
    console.error('[Hotline-Watcher] Fehler:', err.message);
    if (client) await client.close().catch(() => {});
    isConnected = false;
    setTimeout(connectAndWatch, RETRY_INTERVAL_MS);
  }
}

console.log('[Hotline-Watcher] Gestartet. Warte auf sipgate...');
connectAndWatch();
