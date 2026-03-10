# sipgate Channel Selector

Hält die sipgate Desktop App dauerhaft auf dem Channel **„Hotline"** — automatisch, im Hintergrund, ohne Benutzereingriff. Funktioniert auf **macOS und Windows**.

## Wie es funktioniert

Der Watcher verbindet sich über das [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/) mit der sipgate Electron App und injiziert ein kleines Skript, das sofort reagiert, sobald jemand den Channel wechselt.

- **Kein Channel-Wechsel möglich** — der Watcher korrigiert es innerhalb einer Sekunde
- **Dock/Taskbar-Start wie gewohnt** — wenn sipgate ohne Debug-Port gestartet wird, erkennt der Watcher das automatisch und startet sipgate kurz neu
- **Autostart nach Reboot** — läuft als Hintergrunddienst (launchd auf macOS, Task Scheduler auf Windows), startet automatisch beim Login
- **Keine Accessibility-Berechtigungen nötig**

---

## Installation

### macOS

Terminal öffnen und ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/eventnet-projekte/sipgate-channel-selector/main/install.sh | bash
```

### Windows

PowerShell als Administrator öffnen und ausführen:

```powershell
iwr -useb https://raw.githubusercontent.com/eventnet-projekte/sipgate-channel-selector/main/install.ps1 | iex
```

---

## Update

Gleichen Befehl nochmal ausführen — der Installer erkennt eine bestehende Installation und aktualisiert sie automatisch.

## Deinstallation

**macOS:**
```bash
bash ~/.sipgate-channel-selector/uninstall.sh
```

**Windows:**
```powershell
& "$env:LOCALAPPDATA\SipgateChannelSelector\uninstall.ps1"
```

---

## Logs

**macOS:**
```bash
tail -f /tmp/sipgate-hotline-watcher.log
```

**Windows:**
```powershell
Get-Content "$env:TEMP\sipgate-hotline-watcher.log" -Wait
```

---

## Voraussetzungen

| | macOS | Windows |
|---|---|---|
| OS | macOS 11+ | Windows 10/11 |
| sipgate | `/Applications/sipgate.app` | `%LOCALAPPDATA%\sipgate\` |
| Node.js | wird automatisch installiert | wird automatisch installiert |

---

## Technischer Hintergrund

| Komponente | Beschreibung |
|---|---|
| `watcher.js` | Node.js Daemon, verbindet sich via CDP, injiziert MutationObserver — läuft auf macOS + Windows |
| `install.sh` | Selbst-enthaltener Installer für macOS |
| `install.ps1` | Selbst-enthaltener Installer für Windows |
| launchd / Task Scheduler | Autostart bei Login, automatischer Neustart bei Absturz |

**Robustheit bei App-Updates:** Die Erkennung basiert auf `document.title` (`"Hotline - sipgate App"`) und `aria-label="Hotline"` — beides semantische Eigenschaften, keine internen CSS-Klassen. Ändern sich diese bei einem sipgate-Update, reicht es, den Installer erneut auszuführen sobald eine neue Version verfügbar ist.
