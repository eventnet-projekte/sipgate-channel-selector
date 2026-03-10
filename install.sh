#!/bin/bash
# =============================================================================
# sipgate Hotline Watcher — Installer (selbst-enthalten)
# =============================================================================
# Einmaliger Install-Befehl für Kollegen:
#
#   curl -fsSL https://raw.githubusercontent.com/eventnet-projekte/sipgate-channel-selector/main/install.sh | bash
#
# Update: gleichen Befehl nochmal ausführen
# Deinstallieren: bash ~/.sipgate-channel-selector/uninstall.sh
# =============================================================================

set -e

INSTALL_DIR="$HOME/.sipgate-channel-selector"
PLIST_NAME="com.eventnet.sipgate-hotline-watcher"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   sipgate Hotline Watcher — Installer        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Node.js prüfen / installieren ─────────────────────────────────────────
echo "▶ Prüfe Node.js..."

NODE_BIN=""
for candidate in \
    "/usr/local/bin/node" \
    "/opt/homebrew/bin/node" \
    "$HOME/.sipgate-channel-selector/node/bin/node" \
    "$HOME/.nvm/versions/node/$(ls $HOME/.nvm/versions/node 2>/dev/null | tail -1)/bin/node"
do
    if [ -x "$candidate" ]; then
        NODE_BIN="$candidate"
        break
    fi
done

# Falls noch nicht gefunden: which node versuchen
if [ -z "$NODE_BIN" ] && which node &>/dev/null; then
    NODE_BIN="$(which node)"
fi

if [ -z "$NODE_BIN" ]; then
    echo "  Node.js nicht gefunden — wird jetzt installiert (ca. 30 MB)..."

    ARCH=$(uname -m)
    NODE_VERSION="v20.19.0"
    if [ "$ARCH" = "arm64" ]; then
        NODE_PKG="node-${NODE_VERSION}-darwin-arm64"
    else
        NODE_PKG="node-${NODE_VERSION}-darwin-x64"
    fi

    NODE_INSTALL_DIR="$INSTALL_DIR/node"
    mkdir -p "$NODE_INSTALL_DIR"
    curl -# -L "https://nodejs.org/dist/${NODE_VERSION}/${NODE_PKG}.tar.gz" \
        | tar -xz -C "$NODE_INSTALL_DIR" --strip-components=1

    NODE_BIN="$NODE_INSTALL_DIR/bin/node"
    echo "  ✓ Node.js $("$NODE_BIN" --version) installiert"
else
    echo "  ✓ Node.js gefunden: $("$NODE_BIN" --version) ($NODE_BIN)"
fi

NPM_BIN="$(dirname "$NODE_BIN")/npm"

# ── 2. Watcher-Dateien schreiben ──────────────────────────────────────────────
echo ""
echo "▶ Installiere Dateien nach: $INSTALL_DIR"

# Stoppe laufenden Watcher vor dem Update
if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
    echo ""
    echo "▶ Stoppe bestehenden Watcher (Update)..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

mkdir -p "$INSTALL_DIR"

# ── watcher.js (eingebettet) ──────────────────────────────────────────────────
cat > "$INSTALL_DIR/watcher.js" << 'WATCHER_EOF'
#!/usr/bin/env node
/**
 * sipgate Channel Watcher
 *
 * Enforces "Hotline" channel via Chrome DevTools Protocol (CDP).
 * If sipgate is running WITHOUT the debug port (e.g. started via Dock),
 * it automatically restarts it with --remote-debugging-port=9222.
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
  setInterval(enforceHotline, 1000);

  console.log('[Hotline-Watcher] Active.');
  return 'ok';
})();
`;

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function isSipgateRunning() {
  try {
    execSync('pgrep -x sipgate', { stdio: 'ignore' });
    return true;
  } catch { return false; }
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
      try { execSync('pkill -x sipgate', { stdio: 'ignore' }); } catch {}
      await sleep(2000);
      exec('open -a sipgate --args --remote-debugging-port=9222');
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

console.log('[Hotline-Watcher] Gestartet. Warte auf sipgate...');
connectAndWatch();
WATCHER_EOF

# ── package.json (eingebettet) ────────────────────────────────────────────────
cat > "$INSTALL_DIR/package.json" << 'PKG_EOF'
{
  "name": "sipgate-channel-selector",
  "version": "1.0.0",
  "main": "watcher.js",
  "dependencies": {
    "chrome-remote-interface": "^0.33.2"
  }
}
PKG_EOF

# ── uninstall.sh (eingebettet) ────────────────────────────────────────────────
cat > "$INSTALL_DIR/uninstall.sh" << 'UNINSTALL_EOF'
#!/bin/bash
PLIST_NAME="com.eventnet.sipgate-hotline-watcher"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
INSTALL_DIR="$HOME/.sipgate-channel-selector"

echo "▶ Stoppe Watcher..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
echo "▶ Entferne Autostart..."
rm -f "$PLIST_PATH"
echo "▶ Entferne Dateien..."
rm -rf "$INSTALL_DIR"
echo "▶ Starte sipgate normal neu..."
pkill -x sipgate 2>/dev/null || true
sleep 1
open -a "/Applications/sipgate.app"
echo ""
echo "✓ Deinstalliert."
UNINSTALL_EOF
chmod +x "$INSTALL_DIR/uninstall.sh"

# ── 3. npm install ────────────────────────────────────────────────────────────
echo ""
echo "▶ Installiere Abhängigkeiten..."
cd "$INSTALL_DIR"
# npm-cli.js direkt mit unserem Node aufrufen — umgeht PATH-Probleme
NPM_CLI="$(dirname "$NODE_BIN")/../lib/node_modules/npm/bin/npm-cli.js"
"$NODE_BIN" "$NPM_CLI" install --omit=dev --silent
echo "  ✓ Fertig"

# ── 4. start.sh generieren (Pfade werden hier zur Installationszeit eingesetzt) ──
cat > "$INSTALL_DIR/start.sh" << STARTSCRIPT_EOF
#!/bin/bash
# Startet den Watcher — der Watcher kümmert sich selbst darum,
# sipgate mit dem richtigen Debug-Port zu starten.
exec "$NODE_BIN" "$INSTALL_DIR/watcher.js"
STARTSCRIPT_EOF
chmod +x "$INSTALL_DIR/start.sh"

# ── 5. launchd plist ──────────────────────────────────────────────────────────
echo ""
echo "▶ Richte Autostart ein..."
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/start.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/sipgate-hotline-watcher.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sipgate-hotline-watcher.error.log</string>
</dict>
</plist>
PLIST_EOF

launchctl load "$PLIST_PATH"
echo "  ✓ Autostart aktiviert"

# ── 6. Sofort starten ─────────────────────────────────────────────────────────
echo ""
echo "▶ Starte Watcher..."
launchctl start "$PLIST_NAME" 2>/dev/null || true
sleep 2

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✓ Installation abgeschlossen!              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Watcher läuft im Hintergrund."
echo "  sipgate wird automatisch auf 'Hotline' gehalten."
echo ""
echo "  Logs:           tail -f /tmp/sipgate-hotline-watcher.log"
echo "  Deinstallieren: bash ~/.sipgate-channel-selector/uninstall.sh"
echo ""
