#!/usr/bin/env node
/**
 * sipgate Channel Watcher — macOS + Windows
 *
 * Enforces "Hotline" channel via Chrome DevTools Protocol (CDP).
 * If sipgate is running WITHOUT the debug port (e.g. started via Dock/Taskbar),
 * it automatically restarts it with --remote-debugging-port=9222.
 */

const CDP = require('chrome-remote-interface');
const { execSync, exec } = require('child_process');
const os = require('os');

const DEBUG_PORT = 9222;
const RETRY_INTERVAL_MS = 5000;
const POLL_INTERVAL_MS = 1000;
const IS_WINDOWS = os.platform() === 'win32';

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

// ── OS-spezifische Helpers ────────────────────────────────────────────────────

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function isSipgateRunning() {
  try {
    if (IS_WINDOWS) {
      const out = execSync('tasklist /FI "IMAGENAME eq sipgate.exe" /NH', { encoding: 'utf8' });
      return out.toLowerCase().includes('sipgate.exe');
    } else {
      execSync('pgrep -x sipgate', { stdio: 'ignore' });
      return true;
    }
  } catch { return false; }
}

function killSipgate() {
  try {
    if (IS_WINDOWS) {
      execSync('taskkill /F /IM sipgate.exe', { stdio: 'ignore' });
    } else {
      execSync('pkill -x sipgate', { stdio: 'ignore' });
    }
  } catch {}
}

function launchSipgate() {
  if (IS_WINDOWS) {
    // Typische Installationspfade auf Windows
    const paths = [
      `${process.env.LOCALAPPDATA}\\sipgate\\sipgate.exe`,
      `${process.env.PROGRAMFILES}\\sipgate\\sipgate.exe`,
      `${process.env['PROGRAMFILES(X86)']}\\sipgate\\sipgate.exe`,
    ];
    const exePath = paths.find(p => {
      try { require('fs').accessSync(p); return true; } catch { return false; }
    });
    if (exePath) {
      exec(`"${exePath}" --remote-debugging-port=${DEBUG_PORT}`);
    } else {
      // Fallback: über Shell starten
      exec(`start "" sipgate --remote-debugging-port=${DEBUG_PORT}`);
    }
  } else {
    exec(`open -a sipgate --args --remote-debugging-port=${DEBUG_PORT}`);
  }
}

// ── CDP Helpers ───────────────────────────────────────────────────────────────

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
            t.type === 'page' && !t.url.startsWith('devtools://')
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
    // Port 9222 nicht erreichbar — läuft sipgate ohne Debug-Port?
    if (!restarting && isSipgateRunning()) {
      restarting = true;
      console.log('[Hotline-Watcher] sipgate läuft ohne Debug-Port — starte neu...');
      killSipgate();
      await sleep(2000);
      launchSipgate();
      console.log('[Hotline-Watcher] sipgate neu gestartet. Warte...');
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
    console.log(val === 'already_running'
      ? '[Hotline-Watcher] Skript läuft bereits.'
      : '[Hotline-Watcher] Monitoring aktiv.');

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

console.log(`[Hotline-Watcher] Gestartet auf ${IS_WINDOWS ? 'Windows' : 'macOS'}. Warte auf sipgate...`);
connectAndWatch();
