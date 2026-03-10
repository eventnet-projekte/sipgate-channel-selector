# =============================================================================
# sipgate Hotline Watcher — Windows Installer (selbst-enthalten)
# =============================================================================
# Einmaliger Install-Befehl fuer Kollegen (PowerShell als Admin):
#
#   iwr -useb https://raw.githubusercontent.com/eventnet-projekte/sipgate-channel-selector/main/install.ps1 | iex
#
# Update: gleichen Befehl nochmal ausfuehren
# Deinstallieren: & "$env:LOCALAPPDATA\SipgateChannelSelector\uninstall.ps1"
# =============================================================================

$ErrorActionPreference = 'Stop'

$INSTALL_DIR  = "$env:LOCALAPPDATA\SipgateChannelSelector"
$TASK_NAME    = "SipgateHotlineWatcher"
$LOG_FILE     = "$env:TEMP\sipgate-hotline-watcher.log"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗"
Write-Host "║   sipgate Hotline Watcher — Installer        ║"
Write-Host "╚══════════════════════════════════════════════╝"
Write-Host ""

# ── 1. Node.js pruefen / installieren ────────────────────────────────────────
Write-Host "▶ Pruefe Node.js..."

$NODE_BIN = $null
$candidates = @(
    "C:\Program Files\nodejs\node.exe",
    "C:\Program Files (x86)\nodejs\node.exe",
    "$env:APPDATA\nvm\current\node.exe",
    "$INSTALL_DIR\node\node.exe"
)

foreach ($c in $candidates) {
    if (Test-Path $c) { $NODE_BIN = $c; break }
}

# Falls noch nicht gefunden: node im PATH suchen
if (-not $NODE_BIN) {
    try {
        $found = (Get-Command node -ErrorAction SilentlyContinue).Source
        if ($found) { $NODE_BIN = $found }
    } catch {}
}

if (-not $NODE_BIN) {
    Write-Host "  Node.js nicht gefunden — wird jetzt installiert (ca. 30 MB)..."

    $NODE_VERSION = "v20.19.0"
    $NODE_PKG     = "node-$NODE_VERSION-win-x64"
    $NODE_ZIP     = "$env:TEMP\$NODE_PKG.zip"
    $NODE_DIR     = "$INSTALL_DIR\node"

    New-Item -ItemType Directory -Force -Path $NODE_DIR | Out-Null

    Write-Host "  Downloade Node.js $NODE_VERSION..."
    Invoke-WebRequest -Uri "https://nodejs.org/dist/$NODE_VERSION/$NODE_PKG.zip" `
        -OutFile $NODE_ZIP -UseBasicParsing

    Write-Host "  Entpacke..."
    Expand-Archive -Path $NODE_ZIP -DestinationPath "$env:TEMP\nodeextract" -Force
    Copy-Item "$env:TEMP\nodeextract\$NODE_PKG\*" -Destination $NODE_DIR -Recurse -Force
    Remove-Item $NODE_ZIP -Force
    Remove-Item "$env:TEMP\nodeextract" -Recurse -Force

    $NODE_BIN = "$NODE_DIR\node.exe"
    $v = & $NODE_BIN --version
    Write-Host "  ✓ Node.js $v installiert"
} else {
    $v = & $NODE_BIN --version
    Write-Host "  ✓ Node.js gefunden: $v ($NODE_BIN)"
}

$NODE_DIR_BIN = Split-Path $NODE_BIN
$NPM_CLI      = "$NODE_DIR_BIN\node_modules\npm\bin\npm-cli.js"

# Fallback falls npm-cli.js relativ liegt
if (-not (Test-Path $NPM_CLI)) {
    $NPM_CLI = "$NODE_DIR_BIN\..\lib\node_modules\npm\bin\npm-cli.js"
}

# ── 2. Bestehenden Watcher stoppen ───────────────────────────────────────────
$existing = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host ""
    Write-Host "▶ Stoppe bestehenden Watcher (Update)..."
    Stop-ScheduledTask  -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
}

# ── 3. Dateien installieren ───────────────────────────────────────────────────
Write-Host ""
Write-Host "▶ Installiere Dateien nach: $INSTALL_DIR"
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

# ── watcher.js (eingebettet) ──────────────────────────────────────────────────
$WATCHER_CONTENT = @'
#!/usr/bin/env node
/**
 * sipgate Channel Watcher -- macOS + Windows
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
    if (document.title.startsWith('Hotline')) return;
    const hotline = document.querySelector('[aria-label="Hotline"]');
    if (!hotline) return;
    console.log('[Hotline-Watcher] Switching to Hotline (was: ' + document.title + ')');
    hotline.click();
  }

  enforceHotline();

  const observer = new MutationObserver(enforceHotline);
  observer.observe(document.body, {
    subtree: true, attributes: true, attributeFilter: ['class']
  });

  setInterval(enforceHotline, 1000);
  console.log('[Hotline-Watcher] Active.');
  return 'ok';
})();
`;

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

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
    if (IS_WINDOWS) execSync('taskkill /F /IM sipgate.exe', { stdio: 'ignore' });
    else            execSync('pkill -x sipgate',            { stdio: 'ignore' });
  } catch {}
}

function launchSipgate() {
  if (IS_WINDOWS) {
    const fs = require('fs');
    const paths = [
      `${process.env.LOCALAPPDATA}\\sipgate\\sipgate.exe`,
      `${process.env.PROGRAMFILES}\\sipgate\\sipgate.exe`,
      `${process.env['PROGRAMFILES(X86)']}\\sipgate\\sipgate.exe`,
    ];
    const exePath = paths.find(p => { try { fs.accessSync(p); return true; } catch { return false; } });
    if (exePath) exec(`"${exePath}" --remote-debugging-port=9222`);
    else         exec(`start "" sipgate --remote-debugging-port=9222`);
  } else {
    exec('open -a sipgate --args --remote-debugging-port=9222');
  }
}

async function getSipgateTarget() {
  const http = require('http');
  return new Promise((resolve, reject) => {
    const req = http.get(`http://localhost:9222/json`, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try {
          const t = JSON.parse(data).find(t => t.type === 'page' && !t.url.startsWith('devtools://'));
          if (t) resolve(t); else reject(new Error('No page target'));
        } catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.setTimeout(3000, () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

let isConnected = false, restarting = false;

async function connectAndWatch() {
  let target;
  try {
    target = await getSipgateTarget();
  } catch {
    if (!restarting && isSipgateRunning()) {
      restarting = true;
      console.log('[Hotline-Watcher] sipgate laeuft ohne Debug-Port -- starte neu...');
      killSipgate();
      await sleep(2000);
      launchSipgate();
      console.log('[Hotline-Watcher] sipgate neu gestartet. Warte...');
      await sleep(5000);
      restarting = false;
    } else if (!isConnected && !restarting) {
      process.stdout.write('.');
    }
    setTimeout(connectAndWatch, 5000);
    return;
  }

  if (!isConnected) {
    console.log(`\n[Hotline-Watcher] Verbunden (${target.title || target.url})`);
    isConnected = true;
  }

  let client;
  try {
    client = await CDP({ port: 9222, target: target.id });
    const { Runtime, Page } = client;
    await Runtime.enable(); await Page.enable();

    const r = await Runtime.evaluate({ expression: INJECTED_WATCHER_SCRIPT, returnByValue: true });
    console.log(r?.result?.value === 'already_running'
      ? '[Hotline-Watcher] Skript laeuft bereits.'
      : '[Hotline-Watcher] Monitoring aktiv.');

    Page.loadEventFired(async () => {
      await Runtime.evaluate({ expression: INJECTED_WATCHER_SCRIPT, returnByValue: true });
    });
    client.on('disconnect', () => {
      isConnected = false;
      setTimeout(connectAndWatch, 5000);
    });
  } catch (err) {
    console.error('[Hotline-Watcher] Fehler:', err.message);
    if (client) await client.close().catch(() => {});
    isConnected = false;
    setTimeout(connectAndWatch, 5000);
  }
}

console.log(`[Hotline-Watcher] Gestartet auf ${IS_WINDOWS ? 'Windows' : 'macOS'}. Warte auf sipgate...`);
connectAndWatch();
'@
Set-Content -Path "$INSTALL_DIR\watcher.js" -Value $WATCHER_CONTENT -Encoding UTF8

# ── package.json (eingebettet) ────────────────────────────────────────────────
@'
{
  "name": "sipgate-channel-selector",
  "version": "1.0.0",
  "main": "watcher.js",
  "dependencies": {
    "chrome-remote-interface": "^0.33.2"
  }
}
'@ | Set-Content -Path "$INSTALL_DIR\package.json" -Encoding UTF8

# ── 4. npm install ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "▶ Installiere Abhaengigkeiten..."
Set-Location $INSTALL_DIR
& $NODE_BIN $NPM_CLI install --omit=dev --silent
Write-Host "  ✓ Fertig"

# ── 5. start.ps1 generieren ──────────────────────────────────────────────────
@"
# Startet den Watcher
Start-Process -WindowStyle Hidden -FilePath "$NODE_BIN" -ArgumentList "$INSTALL_DIR\watcher.js" ``
    -RedirectStandardOutput "$LOG_FILE" -RedirectStandardError "$LOG_FILE"
"@ | Set-Content -Path "$INSTALL_DIR\start.ps1" -Encoding UTF8

# ── uninstall.ps1 (eingebettet) ───────────────────────────────────────────────
@"
`$TASK_NAME = '$TASK_NAME'
`$INSTALL_DIR = '$INSTALL_DIR'

Write-Host 'Stoppe Watcher...'
Stop-ScheduledTask -TaskName `$TASK_NAME -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName `$TASK_NAME -Confirm:`$false -ErrorAction SilentlyContinue

Write-Host 'Entferne Dateien...'
Remove-Item -Path `$INSTALL_DIR -Recurse -Force

Write-Host 'Starte sipgate normal neu...'
taskkill /F /IM sipgate.exe 2>`$null
Start-Sleep 1
Start-Process sipgate

Write-Host ''
Write-Host 'Deinstalliert.'
"@ | Set-Content -Path "$INSTALL_DIR\uninstall.ps1" -Encoding UTF8

# ── 6. Autostart via Task Scheduler ──────────────────────────────────────────
Write-Host ""
Write-Host "▶ Richte Autostart ein..."

$action  = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$INSTALL_DIR\start.ps1`""

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TASK_NAME `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force | Out-Null

Write-Host "  ✓ Autostart aktiviert (startet bei jedem Login automatisch)"

# ── 7. Sofort starten ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "▶ Starte Watcher..."
Start-ScheduledTask -TaskName $TASK_NAME

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗"
Write-Host "║   ✓ Installation abgeschlossen!              ║"
Write-Host "╚══════════════════════════════════════════════╝"
Write-Host ""
Write-Host "  Watcher laeuft im Hintergrund."
Write-Host "  sipgate wird automatisch auf 'Hotline' gehalten."
Write-Host ""
Write-Host "  Logs:           Get-Content $LOG_FILE -Wait"
Write-Host "  Deinstallieren: & '$INSTALL_DIR\uninstall.ps1'"
Write-Host ""
